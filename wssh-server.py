#!/usr/bin/env python3
# ============================================================
#  wssh-server — 状态页静态服务 + WebSocket→TCP 桥 (SSH over WebSocket)
#  纯 Python 标准库, 无第三方依赖。
#
#  用法: wssh-server <监听端口> <静态目录> <桥接目标host> <桥接目标port>
#
#  路由:
#    /ssh  (WS Upgrade)  → 双向桥接到 <目标host:port> (通常是本机 sshd)
#    其他 GET/HEAD       → 静态文件 (默认 index.html), 即 alpine-box 状态页
#
#  配合客户端 tools/wssh.py, 可经平台 HTTPS 路由 (如 deployzy) 访问容器 SSH:
#    ssh -o ProxyCommand="python3 wssh.py pipe --host <域名> --tls" root@<域名>
# ============================================================
import base64
import hashlib
import os
import socket
import sys
import threading

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
WS_PATH = "/ssh"
MAX_HEADER = 16 * 1024
MAX_FRAME = 4 * 1024 * 1024

CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".txt": "text/plain; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "application/javascript",
    ".json": "application/json",
    ".png": "image/png",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
}


LOG_FILE = os.environ.get("WSSH_LOG", "")


def log(msg):
    line = "[wssh-server] %s\n" % msg
    sys.stderr.write(line)
    sys.stderr.flush()
    if LOG_FILE:
        try:
            with open(LOG_FILE, "a") as f:
                f.write("%s %s" % (__import__("time").strftime("%FT%TZ", __import__("time").gmtime()), line))
        except OSError:
            pass


def recv_exact(sock, n):
    """精确读取 n 字节; 对端关闭返回 None。"""
    buf = b""
    while len(buf) < n:
        try:
            chunk = sock.recv(n - len(buf))
        except (OSError, socket.timeout):
            return None
        if not chunk:
            return None
        buf += chunk
    return buf


def read_request(sock):
    """读取 HTTP 请求头, 返回 (method, path, headers dict)。"""
    data = b""
    while b"\r\n\r\n" not in data:
        if len(data) > MAX_HEADER:
            return None, None, None
        try:
            chunk = sock.recv(4096)
        except (OSError, socket.timeout):
            return None, None, None
        if not chunk:
            return None, None, None
        data += chunk
    head, _, _rest = data.partition(b"\r\n\r\n")
    lines = head.decode("latin-1").split("\r\n")
    parts = lines[0].split()
    if len(parts) < 2:
        return None, None, None
    headers = {}
    for line in lines[1:]:
        if ":" in line:
            k, _, v = line.partition(":")
            headers[k.strip().lower()] = v.strip()
    return parts[0], parts[1], headers


def send_simple(sock, code, text, ctype="text/plain; charset=utf-8"):
    body = text.encode()
    hdr = (
        "HTTP/1.1 %d %s\r\n" % (code, "OK" if code == 200 else "Error")
        + "Content-Type: %s\r\n" % ctype
        + "Content-Length: %d\r\nConnection: close\r\n\r\n" % len(body)
    )
    try:
        sock.sendall(hdr.encode() + body)
    except OSError:
        pass


def serve_static(sock, path, webdir):
    path = path.split("?", 1)[0].split("#", 1)[0]
    if path in ("/", ""):
        path = "/index.html"
    rel = path.lstrip("/")
    target = os.path.normpath(os.path.join(webdir, rel))
    if not target.startswith(os.path.abspath(webdir) + os.sep) and target != os.path.abspath(webdir):
        send_simple(sock, 403, "forbidden")
        return
    if not os.path.isfile(target):
        send_simple(sock, 404, "not found")
        return
    ext = os.path.splitext(target)[1].lower()
    ctype = CONTENT_TYPES.get(ext, "application/octet-stream")
    try:
        with open(target, "rb") as f:
            body = f.read()
    except OSError:
        send_simple(sock, 500, "read error")
        return
    try:
        sock.sendall(
            ("HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\n"
             "Cache-Control: no-store\r\nConnection: close\r\n\r\n" % (ctype, len(body))).encode()
            + body
        )
    except OSError:
        pass


def ws_send_frame(sock, opcode, payload=b""):
    """发送一帧 (服务端帧不掩码)。"""
    b1 = 0x80 | opcode
    ln = len(payload)
    if ln < 126:
        hdr = bytes([b1, ln])
    elif ln < 65536:
        hdr = bytes([b1, 126]) + ln.to_bytes(2, "big")
    else:
        hdr = bytes([b1, 127]) + ln.to_bytes(8, "big")
    sock.sendall(hdr + payload)


def ws_read_message(sock):
    """读取完整一条消息, 处理分片/控制帧; 返回 (opcode, payload) 或 None。"""
    cur_op = None
    buf = b""
    while True:
        hdr = recv_exact(sock, 2)
        if hdr is None:
            return None
        b1, b2 = hdr
        fin = b1 & 0x80
        opcode = b1 & 0x0F
        masked = b2 & 0x80
        ln = b2 & 0x7F
        if ln == 126:
            ext = recv_exact(sock, 2)
            if ext is None:
                return None
            ln = int.from_bytes(ext, "big")
        elif ln == 127:
            ext = recv_exact(sock, 8)
            if ext is None:
                return None
            ln = int.from_bytes(ext, "big")
        if ln > MAX_FRAME:
            return None
        mask = recv_exact(sock, 4) if masked else None
        if mask is None and masked:
            return None
        payload = recv_exact(sock, ln) if ln else b""
        if payload is None:
            return None
        if mask:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        if opcode == 8:  # close
            try:
                ws_send_frame(sock, 8, payload[:2])
            except OSError:
                pass
            return None
        if opcode == 9:  # ping → pong
            try:
                ws_send_frame(sock, 10, payload)
            except OSError:
                pass
            continue
        if opcode in (1, 2):
            cur_op = opcode
            buf = payload
        elif opcode == 0 and cur_op is not None:
            buf += payload
        else:
            continue
        if fin:
            return cur_op, buf


def pump_ws_to_tcp(ws, tcp):
    try:
        while True:
            msg = ws_read_message(ws)
            if msg is None:
                break
            _op, data = msg
            if not data:
                continue
            tcp.sendall(data)
    except OSError:
        pass
    finally:
        try:
            ws.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            tcp.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass


def pump_tcp_to_ws(tcp, ws):
    try:
        while True:
            chunk = tcp.recv(65536)
            if not chunk:
                break
            ws_send_frame(ws, 2, chunk)  # binary, fin=1
    except OSError:
        pass
    finally:
        try:
            ws.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            tcp.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass


def handle_ws(sock, headers, thost, tport):
    key = headers.get("sec-websocket-key", "")
    if not key:
        send_simple(sock, 400, "missing key")
        return
    accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    proto = headers.get("sec-websocket-protocol", "")
    resp = (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        "Sec-WebSocket-Accept: %s\r\n" % accept
    )
    if "binary" in proto:
        resp += "Sec-WebSocket-Protocol: binary\r\n"
    resp += "\r\n"
    try:
        sock.sendall(resp.encode())
    except OSError:
        return
    try:
        tcp = socket.create_connection((thost, tport), timeout=10)
        log("已桥接到 %s:%s" % (thost, tport))
    except OSError as e:
        log("bridge target %s:%s 连接失败: %s" % (thost, tport, e))
        try:
            ws_send_frame(sock, 8, (1001).to_bytes(2, "big"))
        except OSError:
            pass
        return
    t = threading.Thread(target=pump_tcp_to_ws, args=(tcp, sock), daemon=True)
    t.start()
    pump_ws_to_tcp(sock, tcp)
    t.join(timeout=5)
    try:
        sock.close()
    except OSError:
        pass
    try:
        tcp.close()
    except OSError:
        pass


def handle_conn(sock, webdir, thost, tport):
    try:
        method, path, headers = read_request(sock)
    except Exception:
        return
    if method is None:
        try:
            sock.close()
        except OSError:
            pass
        return
    if "websocket" in headers.get("upgrade", "").lower():
        if path.split("?", 1)[0] != WS_PATH:
            log("WS 请求路径错误: %s" % path)
            send_simple(sock, 404, "websocket only at %s" % WS_PATH)
        else:
            log("WS 升级请求到达 (origin=%s)" % headers.get("origin", "-"))
            handle_ws(sock, headers, thost, tport)
        return
    if method in ("GET", "HEAD"):
        serve_static(sock, path, webdir)
    else:
        send_simple(sock, 405, "method not allowed")
    try:
        sock.close()
    except OSError:
        pass


def main():
    if len(sys.argv) != 5:
        sys.stderr.write("用法: wssh-server <监听端口> <静态目录> <桥接host> <桥接端口>\n")
        sys.exit(2)
    port, webdir, thost, tport = int(sys.argv[1]), sys.argv[2], sys.argv[3], int(sys.argv[4])
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", port))
    srv.listen(128)
    log("listening on 0.0.0.0:%d (static=%s, bridge=%s:%d)" % (port, webdir, thost, tport))
    while True:
        try:
            conn, _addr = srv.accept()
        except OSError:
            continue
        threading.Thread(
            target=handle_conn, args=(conn, webdir, thost, tport), daemon=True
        ).start()


if __name__ == "__main__":
    main()
