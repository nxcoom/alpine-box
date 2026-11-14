#!/usr/bin/env python3
# ============================================================
#  wssh — SSH over WebSocket 客户端 (纯 Python 标准库)
#
#  配合 alpine-box 镜像内置的 wssh-server, 经平台 HTTPS 路由访问容器 SSH。
#
#  模式一 (推荐, 配合 ssh ProxyCommand, 无需本地端口):
#    ssh -o ProxyCommand="python3 wssh.py pipe --host <域名> --tls" \
#        -o StrictHostKeyChecking=accept-new root@<域名>
#
#  模式二 (本地端口转发):
#    python3 wssh.py tunnel --host <域名> --tls --local 2222
#    ssh -p 2222 root@127.0.0.1
#
#  选项:
#    --port       端口 (默认: --tls 时 443, 否则 80)
#    --path       WebSocket 路径 (默认 /ssh)
#    --no-verify  跳过 TLS 证书校验 (自签/内网场景)
# ============================================================
import argparse
import base64
import hashlib
import os
import socket
import ssl
import struct
import sys
import threading

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def log(msg):
    sys.stderr.write("[wssh] %s\n" % msg)
    sys.stderr.flush()


def recv_exact(sock, n):
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


def connect_ws(args):
    port = args.port or (443 if args.tls else 80)
    try:
        raw = socket.create_connection((args.host, port), timeout=20)
    except OSError as e:
        log("连接 %s:%s 失败: %s" % (args.host, port, e))
        sys.exit(1)
    if args.tls:
        ctx = ssl.create_default_context()
        if args.no_verify:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        try:
            raw = ctx.wrap_socket(raw, server_hostname=args.host)
        except ssl.SSLError as e:
            log("TLS 握手失败: %s" % e)
            sys.exit(1)
    key = base64.b64encode(os.urandom(16)).decode()
    req = (
        "GET %s HTTP/1.1\r\n" % args.path
        + "Host: %s:%d\r\n" % (args.host, port)
        + "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        + "Sec-WebSocket-Key: %s\r\n" % key
        + "Sec-WebSocket-Version: 13\r\n"
        + "Sec-WebSocket-Protocol: binary\r\n\r\n"
    )
    raw.sendall(req.encode())
    data = b""
    while b"\r\n\r\n" not in data:
        if len(data) > 16384:
            log("响应头过大")
            sys.exit(1)
        chunk = raw.recv(4096)
        if not chunk:
            log("连接被关闭, 未收到 WebSocket 升级响应")
            sys.exit(1)
        data += chunk
    head, _, _rest = data.partition(b"\r\n\r\n")
    status = head.split(b"\r\n")[0].decode("latin-1")
    if " 101 " not in status:
        log("WebSocket 升级失败: %s" % status.strip())
        sys.exit(1)
    expect = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    if expect.encode() not in head:
        log("Sec-WebSocket-Accept 校验失败")
        sys.exit(1)
    return raw


def send_frame(sock, opcode, payload=b""):
    """客户端帧必须掩码。"""
    b1 = 0x80 | opcode
    ln = len(payload)
    if ln < 126:
        hdr = struct.pack("!BB", b1, 0x80 | ln)
    elif ln < 65536:
        hdr = struct.pack("!BBH", b1, 0x80 | 126, ln)
    else:
        hdr = struct.pack("!BBQ", b1, 0x80 | 127, ln)
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    sock.sendall(hdr + mask + masked)


def read_message(sock):
    """读取一条完整消息; 返回 (opcode, payload) 或 None。"""
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
        mask = recv_exact(sock, 4) if masked else b""
        payload = recv_exact(sock, ln) if ln else b""
        if payload is None:
            return None
        if mask:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        if opcode == 8:
            return None
        if opcode == 9:  # ping → pong
            try:
                send_frame(sock, 10, payload)
            except OSError:
                return None
            continue
        if opcode in (1, 2):
            cur_op, buf = opcode, payload
        elif opcode == 0 and cur_op is not None:
            buf += payload
        else:
            continue
        if fin:
            return cur_op, buf


def ws_to_stdout(ws):
    while True:
        msg = read_message(ws)
        if msg is None:
            break
        sys.stdout.buffer.write(msg[1])
        sys.stdout.buffer.flush()


def pipe_mode(args):
    ws = connect_ws(args)
    t = threading.Thread(target=ws_to_stdout, args=(ws,), daemon=True)
    t.start()
    try:
        while True:
            # os.read: 管道上单次系统调用, 有多少读多少 (buffered read 会等满 n 字节)
            chunk = os.read(0, 65536)
            if not chunk:
                break
            send_frame(ws, 2, chunk)
    except OSError:
        pass
    finally:
        try:
            send_frame(ws, 8)
        except OSError:
            pass
        # 给服务端一点时间把剩余输出送回
        t.join(timeout=3)
        try:
            ws.close()
        except OSError:
            pass


def relay(local, args):
    ws = connect_ws(args)

    def ws_to_tcp():
        while True:
            msg = read_message(ws)
            if msg is None:
                break
            try:
                local.sendall(msg[1])
            except OSError:
                break
        try:
            local.shutdown(socket.SHUT_WR)
        except OSError:
            pass

    t = threading.Thread(target=ws_to_tcp, daemon=True)
    t.start()
    try:
        while True:
            chunk = local.recv(65536)
            if not chunk:
                break
            send_frame(ws, 2, chunk)
    except OSError:
        pass
    finally:
        try:
            send_frame(ws, 8)
        except OSError:
            pass
        t.join(timeout=2)
        try:
            local.close()
        except OSError:
            pass
        try:
            ws.close()
        except OSError:
            pass


def tunnel_mode(args):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", args.local))
    srv.listen(16)
    log("本地转发已就绪: ssh -p %d root@127.0.0.1" % args.local)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=relay, args=(conn, args), daemon=True).start()


def main():
    p = argparse.ArgumentParser(description="SSH over WebSocket 客户端 (alpine-box)")
    p.add_argument("mode", choices=["pipe", "tunnel"])
    p.add_argument("--host", required=True, help="服务器域名/IP")
    p.add_argument("--port", type=int, default=0, help="端口, 默认 tls?443:80")
    p.add_argument("--path", default="/ssh", help="WebSocket 路径, 默认 /ssh")
    p.add_argument("--tls", action="store_true", help="使用 TLS (wss)")
    p.add_argument("--no-verify", action="store_true", help="跳过证书校验")
    p.add_argument("--local", type=int, default=2222, help="tunnel 模式本地端口, 默认 2222")
    args = p.parse_args()
    if args.mode == "pipe":
        pipe_mode(args)
    else:
        tunnel_mode(args)


if __name__ == "__main__":
    main()
