#!/usr/bin/env python3
"""web_ssh 首次启动预置：生成专用密钥、加入 sshd authorized_keys、写入 local-box 会话。

设计要点：
- web_ssh 在启动时把 store.json 一次性读入内存，之后仅在写入时回写，因此必须在
  启动 webssh 之前调用本脚本预置好 store.json。
- 幂等：密钥和会话都存在时只确保公钥在 authorized_keys 里，不覆盖用户后来在
  UI 里做的修改（不重复写会话、不改 admin/groups/tunnels）。
- 只用 Python 标准库。密钥用 ssh-keygen（镜像已装 openssh）。

用法: webssh-provision <data_dir> <ssh_port> [authorized_keys_file]
"""
import json
import os
import subprocess
import sys
import tempfile
import uuid
from datetime import datetime, timezone


def now() -> str:
    # web_ssh 的 time.Time 用 RFC3339Nano；秒级 RFC3339 可被 Go 正常解析。
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def ensure_keypair(data_dir: str):
    """返回 (private_key_pem, public_key_line)。已有则复用。"""
    priv = os.path.join(data_dir, "id_ed25519")
    pub = priv + ".pub"
    if not (os.path.exists(priv) and os.path.exists(pub)):
        os.makedirs(data_dir, exist_ok=True)
        subprocess.run(
            ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", priv,
             "-C", "webssh-local-box"],
            check=True,
        )
    with open(priv, "r", encoding="utf-8") as f:
        pem = f.read()
    with open(pub, "r", encoding="utf-8") as f:
        pub_line = f.read().strip()
    return pem, pub_line


def ensure_authorized_key(pub_line: str, ak_path: str):
    os.makedirs(os.path.dirname(ak_path), exist_ok=True)
    existing = ""
    if os.path.exists(ak_path):
        with open(ak_path, "r", encoding="utf-8") as f:
            existing = f.read()
    key_body = " ".join(pub_line.split()[:2])  # 忽略注释，比较类型+base64
    for line in existing.splitlines():
        if " ".join(line.split()[:2]) == key_body:
            return
    with open(ak_path, "a", encoding="utf-8") as f:
        if existing and not existing.endswith("\n"):
            f.write("\n")
        f.write(pub_line + "\n")


def upsert_session(store_path: str, pem: str, ssh_port: int):
    data = {"groups": {}, "sessions": {}, "tunnels": {}, "admin": {}}
    if os.path.exists(store_path):
        try:
            with open(store_path, "r", encoding="utf-8") as f:
                loaded = json.load(f)
            if isinstance(loaded, dict):
                data.update(loaded)
        except (ValueError, OSError):
            pass  # 损坏或不可读时用空结构重建（保留其余字段的策略不变）
    sessions = data.setdefault("sessions", {})
    if not isinstance(sessions, dict):
        sessions = data["sessions"] = {}

    # 已存在名为 local-box 的会话则不覆盖（用户可能已改过）。
    for sid, s in sessions.items():
        if isinstance(s, dict) and s.get("name") == "local-box":
            return False, sid

    sid = uuid.uuid4().hex[:24]
    ts = now()
    sessions[sid] = {
        "id": sid,
        "name": "local-box",
        "host": "127.0.0.1",
        "port": ssh_port,
        "username": "root",
        "authType": "privateKey",
        "privateKey": pem,
        "term": "xterm-256color",
        "createdAt": ts,
        "updatedAt": ts,
        # keepAliveInterval 缺省 -> 应用用默认 30s
    }
    os.makedirs(os.path.dirname(store_path), exist_ok=True)
    # 原子写：tmp + rename（与 web_ssh store.go 一致）
    fd, tmp = tempfile.mkstemp(prefix="store.json.", dir=os.path.dirname(store_path))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, store_path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    return True, sid


def main():
    if len(sys.argv) < 3:
        print("usage: webssh-provision <data_dir> <ssh_port> [authorized_keys_file]",
              file=sys.stderr)
        sys.exit(2)
    data_dir = os.path.abspath(sys.argv[1])
    try:
        ssh_port = int(sys.argv[2])
    except ValueError:
        print("ssh_port must be an integer", file=sys.stderr)
        sys.exit(2)
    ak_path = sys.argv[3] if len(sys.argv) > 3 else "/root/.ssh/authorized_keys"

    pem, pub_line = ensure_keypair(data_dir)
    ensure_authorized_key(pub_line, ak_path)
    created, sid = upsert_session(os.path.join(data_dir, "store.json"), pem, ssh_port)
    print("webssh-provision: key=%s/id_ed25519 session=local-box(%s) %s"
          % (data_dir, sid, "created" if created else "exists"))


if __name__ == "__main__":
    main()
