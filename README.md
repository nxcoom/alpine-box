# alpine-box-lite

轻量 Alpine 系统镜像：把内存占用高的 Node/EasyNode 换成 [casualty01/web_ssh](https://github.com/casualty01/web_ssh)（Go 单静态二进制，~7MB），保留 sshx / tunc / guan / wstunnel / wssh。适合部署到 [Orkestr](https://orkestr.eu) 等容器平台作为远程管理机。

> 这是 `webssh-lite` 分支。原 `main` 分支仍是 EasyNode 版本；本分支为低内存版本。

## 集成内容

| 命令 / 服务 | 来源 | 功能 |
| --- | --- | --- |
| `sshx` | `scripts/ssh.sh` | SSH 一键配置：装/配 sshd、公钥管理、改密码、重装服务（交互菜单 + 命令行） |
| `tunc` | `scripts/tunc.sh` | Cloudflare Tunnel 管理（官方 cloudflared 二进制），启动/停止/Token/日志/更新 |
| `guan` | `scripts/guan.sh` | 服务管理交互菜单（OpenRC 管理 sshd / tunc / webssh / wstunnel） |
| web_ssh 面板 | `casualty01/web_ssh:1.3.4` | 浏览器 SSH 客户端（会话管理 / SFTP / 分屏 / 隧道），Go 静态二进制 |
| `wssh` | `wssh-server.py` | 状态页 + SSH over WebSocket/HTTP 桥（备用通道） |
| `wstunnel` | erebe/wstunnel v11.1.0 | websocket 隧道服务端（仅允许隧道到本机 sshd） |

基础镜像从 `node:22-alpine` 换成 `alpine:3.20`，去掉 Node.js 运行时与 EasyNode 的 NeDB 编排，显著降低内存占用。

镜像内启动流程（`entrypoint.sh`）：

1. 容器内引导 OpenRC，sshd 经 `/etc/conf.d/sshd` 注入 `chroot-noop.so`（兼容丢弃 capability 的平台）后启动；
2. `webssh-provision` 生成专用 ed25519 密钥、加入 sshd `authorized_keys`，预置一条 `local-box` 会话（连 `127.0.0.1:<SSH_PORT>`）；
3. web_ssh 面板监听 `$PORT`（默认 3000，平台 HTTP 路由），wssh 桥/状态页在 8080 备用；`CF_TOKEN` 启动时自动拉起 Cloudflare Tunnel；
4. 看门狗每 30s 检查服务并拉起；60s 内面板未就绪则 wssh 自动接管 `$PORT`；`SHOW_LOG=true` 时 stdout 输出日志。

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `SSH_ENABLED` | `true` | 是否启动 SSH 服务 |
| `SSH_PORT` | `22` | SSH 监听端口，支持逗号分隔多端口（如 `22,2022`） |
| `SSH_PUBLIC_KEY` | 内置默认公钥 | root 登录公钥，逗号/换行分隔多个 |
| `CF_TOKEN` | 空 | Cloudflare Tunnel Token，设置后自动启动 tunc |
| `SHOW_LOG` | `true` | 服务日志是否输出到容器 stdout |
| `FILE_PATH` | `/var/lib/alpine-box` | 数据目录：SSH 主机密钥在 `host-keys/`；web_ssh 数据（store.json + 预置密钥）在 `webssh/` |
| `PORT` | `3000` | 平台 HTTP 路由端口（web_ssh 面板监听） |
| `ADMIN_USER` | `admin` | web_ssh 面板管理员用户名 |
| `ADMIN_PASSWORD` | `admin` | web_ssh 面板密码（生产务必设置；仅首次生效，之后以面板内修改为准） |
| `WSTUNNEL_ENABLED` | `true` | 是否启动 wstunnel 服务端 |
| `WSTUNNEL_PORT` | `8090` | wstunnel WebSocket 监听端口 |
| `WSTUNNEL_RESTRICT_TO` | `127.0.0.1:2022` | 限制隧道目标（默认仅允许 SSH 到本机） |
| `TUNNEL_TRANSPORT_PROTOCOL` | 空 | 透传给 cloudflared（如 `http2`） |
| `TUNNEL_EDGE_IP_VERSION` | 空 | 透传给 cloudflared（如 `4`/`6`） |

## web_ssh 管理面板

- 访问：平台路由 `https://<域名>`（容器 `$PORT`，默认 3000）
- 登录：`ADMIN_USER` / `ADMIN_PASSWORD`
- **预置本机会话 `local-box`**：指向容器自身 sshd（`127.0.0.1:<SSH_PORT>`，用户 root），使用启动时生成的专用 ed25519 私钥，登录后即可一键连进本机 shell。密钥与会话在 `FILE_PATH/webssh/`，容器重建不丢失。
- 会话/分组/隧道/管理员凭据持久化在 `FILE_PATH/webssh/store.json`（原子写）。面板内修改的凭据优先于环境变量。
- WebSocket 终端走同源 `/ws/ssh`，经平台 HTTPS 反代时请确保转发 Upgrade 头（Orkestr 平台默认支持）。

> 注意：web_ssh 是浏览器 SSH **客户端**，连接的是你保存的 SSH 目标主机；`local-box` 是预置来管理本容器的。要连外部主机，在面板里添加会话即可（目标必须能从容器内网络到达）。

## 状态页与 SSH over WebSocket 桥

容器内 8080 端口运行 `wssh-server`（纯 Python 标准库）：

- `http://<host>:8080/` — 状态页（服务状态 + 出站探测 + 日志尾部），远程检查用
- `ws(s)://<host>:8080/ssh` — WebSocket → 本机 sshd 的双向桥
- `/wssh-poll/*` — HTTP 长轮询传输（反代拦截 WS 时自动降级）

```
alpine-box status @ 2026-11-17T08:00:00Z
sshd : RUNNING
tunc : RUNNING
webssh : RUNNING
...
```

从仓库 `tools/` 下载 `wssh.py`（纯标准库），作为 ProxyCommand 使用：

```bash
ssh -o ProxyCommand="python3 wssh.py pipe --host <host> --port 8080" \
    -o StrictHostKeyChecking=no root@127.0.0.1 'echo OK'
# 强制轮询传输：加 --transport poll
```

正常网络仍优先走 Cloudflare Tunnel（tunc）：隧道 ingress 指向 `ssh://localhost:<SSH_PORT>`，用 `cloudflared access tcp` 直连。

## wstunnel 隧道（供 wstunnel.exe 等客户端）

镜像内置 erebe/wstunnel **v11.1.0 服务端**（8090 端口，`--restrict-to 127.0.0.1:2022`）：

```bash
wstunnel.exe client wss://<host>:443 -L tcp://127.0.0.1:11080:127.0.0.1:2022
ssh -p 11080 root@127.0.0.1
```

- 客户端必须同为 v11.x；wss:// 经 HTTPS 反代，ws:// 明文会被 CDN 拒
- 服务端限制隧道目标为 `127.0.0.1:2022`，可改 `WSTUNNEL_RESTRICT_TO`（不建议放开）

## 部署到 Orkestr

项目从 GitHub 仓库构建（`repo_url=https://github.com/nxcoom/alpine-box`，`repo_branch=webssh-lite`）。环境变量示例：

```
SSH_ENABLED=true
SSH_PORT=2022
SSH_PUBLIC_KEY=ssh-ed25519 AAAA... （你的公钥）
CF_TOKEN=eyJ... （Cloudflare Tunnel Token）
SHOW_LOG=true
FILE_PATH=/var/lib/alpine-box
ADMIN_USER=admin
ADMIN_PASSWORD=<强密码>
```

部署后平台日志可见：`sshd 已启动` / `web_ssh 面板已启动` / `tunc (Cloudflare Tunnel) 已启动`。

## 构建

推送 `webssh-lite` 分支后，GitHub Actions 自动构建 `linux/amd64` + `linux/arm64` 双架构镜像并发布到 GHCR；先跑冒烟测试：真实 SSH 登录（三个 capability 全丢） + web_ssh 面板登录 + 预置会话 + 三个工具 + wstunnel。

## 故障排查

**sshd RUNNING 但登录报 `fatal: chroot("/var/empty"): Operation not permitted [preauth]` / `fatal: setgroups: ...`** — 平台丢弃 `CAP_SYS_CHROOT/SETGID/SETUID`，镜像已内置 `chroot-noop.so` 经 `/etc/conf.d/sshd` 注入；手动启动 sshd 时需自行 `LD_PRELOAD=/usr/local/lib/chroot-noop.so`。

**认证成功但 `fork: Resource temporarily unavailable`** — 容器 PID 打满；镜像用 `tini -g` 作 PID1 回收僵尸，并给 Go 服务（cloudflared/wstunnel/webssh）注入 `GOMAXPROCS=2`。可用平台 stats 的 `pids` 观察；仍打满可关 `WSTUNNEL_ENABLED=false`。

**面板 60s 未就绪** — 平台路由会自动交给 wssh 状态页/桥接管 `$PORT`；诊断见 `/var/log/webssh-fallback.log` 与 `/var/log/webssh.log`。

## 脚本来源

- `https://sb.vir.kdns.fr/sh/ssh.sh` （v2.1）
- `https://tun.uvn.kdns.fr/tunc.sh`
- `https://tun.uvn.kdns.fr/guan.sh` （v1.2.1）
- web_ssh: `https://github.com/casualty01/web_ssh` （固定 1.3.4）
