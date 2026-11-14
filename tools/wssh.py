#!/usr/bin/env python3
# ============================================================
#  wssh — SSH over HTTP 客户端 (纯 Python 标准库)
#
#  配合 alpine-box 镜像内置的 wssh-server, 经平台 HTTPS 路由访问容器 SSH。
#  传输: websocket (优先) → 被反代/CDN 拦截时自动降级为 HTTP 长轮询。
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
#    --transport auto|ws|poll   传输方式 (默认 auto: 先 WS, 失败降级轮询)
#    --port                     端口 (默认: --tls 时 443, 否则 80)
#    --path                     WebSocket 路径 (默认 /ssh)
#    --no-verify                跳过 TLS 证书校验
#    --local                    tunnel 模式本地端口 (默认 2222)
# ============================================================
import argparse
import base64
import hashlib
import http.client
import os
import socket
import ssl
import struct
import sys
import threading

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
POLL_PREFIX = "/wssh-poll"
DEBUG = os.environ.get("WSSH_DEBUG", "")


def dbg(msg):
    if DEBUG:
        log("debug: %s" % msg)


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


# ============================================================
#  WebSocket 传输
# ============================================================
class WsFail(Exception):
    pass


def tls_context(args):
    ctx = ssl.create_default_context()
    if args.no_verify:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    return ctx


def connect_ws(args):
    port = args.port or (443 if args.tls else 80)
    try:
        raw = socket.create_connection((args.host, port), timeout=20)
    except OSError as e:
        raise WsFail("连接 %s:%s 失败: %s" % (args.host, port, e))
    if args.tls:
        try:
            raw = tls_context(args).wrap_socket(raw, server_hostname=args.host)
        except ssl.SSLError as e:
            raise WsFail("TLS 握手失败: %s" % e)
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
            raise WsFail("响应头过大")
        chunk = raw.recv(4096)
        if not chunk:
            raise WsFail("连接被关闭, 未收到 WebSocket 升级响应")
        data += chunk
    head = data.partition(b"\r\n\r\n")[0]
    status = head.split(b"\r\n")[0].decode("latin-1")
    if " 101 " not in status:
        raise WsFail("WebSocket 升级失败: %s" % status.strip())
    expect = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    if expect.encode() not in head:
        raise WsFail("Sec-WebSocket-Accept 校验失败")
    return raw


def send_frame(sock, opcode, payload=b""):
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
        if opcode == 9:
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


def ws_to_sink(ws, sink):
    """sink: write(bytes)。"""
    while True:
        msg = read_message(ws)
        if msg is None:
            break
        sink(msg[1])


# ============================================================
#  HTTP 长轮询传输 (穿透任何只支持普通 request/response 的反代/CDN)
# ============================================================
class PollTransport:
    def __init__(self, args):
        self.args = args
        self.port = args.port or (443 if args.tls else 80)
        self.conns = {"up": None, "down": None, "ctl": None}
        self.sid = None
        self._open()

    def _new_conn(self):
        if self.args.tls:
            return http.client.HTTPSConnection(
                self.args.host, self.port, timeout=40, context=tls_context(self.args))
        return http.client.HTTPConnection(self.args.host, self.port, timeout=40)

    def _req(self, key, method, path, body=None):
        last_err = None
        for _attempt in (0, 1):
            try:
                if self.conns[key] is None:
                    self.conns[key] = self._new_conn()
                c = self.conns[key]
                headers = {"Content-Type": "application/octet-stream"} if body is not None else {}
                dbg("%s %s (body=%d)" % (method, path, len(body or b"")))
                c.request(method, path, body=body, headers=headers)
                r = c.getresponse()
                data = r.read()
                dbg("  → %s len=%d" % (r.status, len(data)))
                return r, data
            except (http.client.HTTPException, OSError, ssl.SSLError) as e:
                dbg("  → 异常: %s" % e)
                last_err = e
                self.conns[key] = None  # 陈旧连接, 重建后重试一次
        raise OSError("HTTP 请求失败: %s" % last_err)

    def _open(self):
        r, _ = self._req("ctl", "POST", "%s/open" % POLL_PREFIX, b"")
        sid = r.getheader("X-Sid")
        if not sid:
            raise OSError("建立轮询会话失败: HTTP %s" % r.status)
        self.sid = sid
        log("轮询会话: %s" % sid)

    def up(self, data):
        self._req("up", "POST", "%s/%s/up" % (POLL_PREFIX, self.sid), data)

    def down(self, seq):
        """返回 (data, new_seq); 会话结束返回 (None, seq)。"""
        r, data = self._req("down", "GET", "%s/%s/down?seq=%d" % (POLL_PREFIX, self.sid, seq))
        if r.status != 200:
            return None, seq
        try:
            new_seq = int(r.getheader("X-Down-Seq", str(seq)))
        except (TypeError, ValueError):
            return None, seq
        return data, new_seq

    def close(self):
        try:
            self._req("ctl", "POST", "%s/%s/close" % (POLL_PREFIX, self.sid), b"")
        except OSError:
            pass
        for k in self.conns:
            try:
                if self.conns[k]:
                    self.conns[k].close()
            except OSError:
                pass


# ============================================================
#  模式实现
# ============================================================
def pipe_ws(args):
    ws = connect_ws(args)
    t = threading.Thread(target=ws_to_sink, args=(ws, lambda b: (sys.stdout.buffer.write(b), sys.stdout.buffer.flush())), daemon=True)
    t.start()
    try:
        while True:
            chunk = os.read(0, 65536)  # 管道上单次系统调用, 有多少读多少
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
        t.join(timeout=3)
        try:
            ws.close()
        except OSError:
            pass


def pipe_poll(args):
    t = PollTransport(args)
    state = {"seq": 0, "dead": False}

    def down_loop():
        while not state["dead"]:
            try:
                data, seq = t.down(state["seq"])
            except OSError as e:
                log("下行中断: %s" % e)
                break
            if data is None:
                break
            state["seq"] = seq
            if data:
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()

    dl = threading.Thread(target=down_loop, daemon=True)
    dl.start()
    try:
        while True:
            chunk = os.read(0, 65536)
            if not chunk:
                break
            t.up(chunk)
    except OSError as e:
        log("上行中断: %s" % e)
    finally:
        t.close()
        dl.join(timeout=5)


def pipe(args):
    if args.transport == "poll":
        pipe_poll(args)
        return
    try:
        pipe_ws(args)
    except WsFail as e:
        if args.transport == "ws":
            log("%s" % e)
            sys.exit(1)
        log("%s — 自动降级为 HTTP 轮询传输" % e)
        pipe_poll(args)


def relay_ws(local, args):
    ws = connect_ws(args)

    def ws_to_tcp():
        ws_to_sink(ws, lambda b: local.sendall(b))
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
        _close_both(local, ws)


def relay_poll(local, args):
    t = PollTransport(args)
    state = {"seq": 0, "dead": False}

    def down_to_tcp():
        while not state["dead"]:
            try:
                data, seq = t.down(state["seq"])
            except OSError:
                break
            if data is None:
                break
            state["seq"] = seq
            if data:
                try:
                    local.sendall(data)
                except OSError:
                    break
        state["dead"] = True
        try:
            local.shutdown(socket.SHUT_WR)
        except OSError:
            pass

    dl = threading.Thread(target=down_to_tcp, daemon=True)
    dl.start()
    try:
        while True:
            chunk = local.recv(65536)
            if not chunk:
                break
            t.up(chunk)
    except OSError:
        pass
    finally:
        state["dead"] = True
        t.close()
        dl.join(timeout=2)
        try:
            local.close()
        except OSError:
            pass


def _close_both(a, b):
    for s in (a, b):
        try:
            s.close()
        except OSError:
            pass


def tunnel(args):
    transport = args.transport
    if transport == "auto":
        try:
            probe = connect_ws(args)
            try:
                probe.close()
            except OSError:
                pass
            transport = "ws"
        except WsFail as e:
            log("%s — 使用轮询传输" % e)
            transport = "poll"
    relay = relay_ws if transport == "ws" else relay_poll
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", args.local))
    srv.listen(16)
    log("本地转发已就绪: ssh -p %d root@127.0.0.1" % args.local)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=relay, args=(conn, args), daemon=True).start()


def main():
    p = argparse.ArgumentParser(description="SSH over HTTP 客户端 (alpine-box wssh)")
    p.add_argument("mode", choices=["pipe", "tunnel"])
    p.add_argument("--host", required=True, help="服务器域名/IP")
    p.add_argument("--port", type=int, default=0, help="端口, 默认 tls?443:80")
    p.add_argument("--path", default="/ssh", help="WebSocket 路径, 默认 /ssh")
    p.add_argument("--tls", action="store_true", help="使用 TLS (https/wss)")
    p.add_argument("--no-verify", action="store_true", help="跳过证书校验")
    p.add_argument("--transport", default="auto", choices=["auto", "ws", "poll"],
                   help="传输方式: auto(默认, WS 失败自动轮询) / ws / poll")
    p.add_argument("--local", type=int, default=2222, help="tunnel 模式本地端口, 默认 2222")
    args = p.parse_args()
    if args.mode == "pipe":
        pipe(args)
    else:
        tunnel(args)


if __name__ == "__main__":
    main()
