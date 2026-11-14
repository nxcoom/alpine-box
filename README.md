# alpine-box

Alpine 系统镜像，集成三个运维工具，可直接部署到 [deployzy](https://deployzy.com/) 等容器平台作为远程管理机使用。

## 集成内容

| 命令 | 来源 | 功能 |
| --- | --- | --- |
| `sshx` | `scripts/ssh.sh` | SSH 一键配置：装/配 sshd、公钥管理、改密码、重装服务（交互菜单 + 命令行） |
| `tunc` | `scripts/tunc.sh` | Cloudflare Tunnel 管理（官方 cloudflared 二进制），启动/停止/Token/日志/更新 |
| `guan` | `scripts/guan.sh` | 服务管理交互菜单（本镜像内通过 OpenRC 管理 sshd / tunc） |

镜像内启动流程（`entrypoint.sh`）：

1. 容器内引导 OpenRC（`/run/openrc/softlevel`），sshd 与 tunc 均以标准 OpenRC 服务运行，`guan` 菜单可直接启停/重启；
2. 按环境变量生成 `sshd_config`、写入公钥、生成主机密钥（优先存放在 `FILE_PATH` 持久化，保持主机指纹稳定）；
3. `CF_TOKEN` 写入 `/etc/tunc/token` 并启动 Cloudflare Tunnel；
4. 看门狗每 30s 检查，服务被杀后自动拉起；`SHOW_LOG=true` 时容器 stdout 实时输出 tunc 与系统日志。

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `SSH_ENABLED` | `true` | 是否启动 SSH 服务（`true/false/1/0/yes/no`） |
| `SSH_PORT` | `22` | SSH 监听端口，支持逗号分隔多端口（如 `22,2022`） |
| `SSH_PUBLIC_KEY` | 内置默认公钥 | root 登录公钥，逗号/换行分隔多个 |
| `CF_TOKEN` | 空 | Cloudflare Tunnel Token，设置后自动启动 tunc |
| `SHOW_LOG` | `true` | 服务日志是否输出到容器 stdout（供平台日志查看） |
| `FILE_PATH` | `/var/lib/alpine-box` | 数据目录，SSH 主机密钥持久化在其中 `host-keys/`；EasyNode 数据库在 `easynode/` |
| `PORT` | `3000` | 平台 HTTP 路由端口（deployzy 平台默认探测 3000） |
| `EASYNODE_ENABLED` | `true` | 是否启动 EasyNode 面板 |
| `EASYNODE_HTTP_PORT` | `8082` | EasyNode HTTP 端口（`WEB_PANEL_ON_PORT=easynode` 时自动改绑 `PORT`） |
| `WEB_PANEL_ON_PORT` | `wssh` | 平台 HTTP 路由指向哪个 web 服务：`wssh`（状态页+SSH桥）或 `easynode`（管理面板） |
| `TUNNEL_TRANSPORT_PROTOCOL` | 空 | 透传给 cloudflared（如 `http2`，经 OpenRC conf.d 注入） |
| `TUNNEL_EDGE_IP_VERSION` | 空 | 透传给 cloudflared（如 `4`/`6`） |

## EasyNode 管理面板 (webSSH / SFTP)

集成 [chaos-zhu/easynode](https://github.com/chaos-zhu/easynode) 官方应用（`/opt/easynode`，OpenRC 服务 `easynode`，guan 可直接管理）：

- 访问：`http://<host>:8082`（或 `WEB_PANEL_ON_PORT=easynode` 时经平台路由 `https://<域名>` 访问）
- 初始账号密码：**首次启动时写入 `/var/log/easynode.log`**，也可在状态页 `easynode.log` 段落查看；登录后请立即修改
- 数据（账号/凭据/脚本库）持久化在 `FILE_PATH/easynode/`，容器重建不丢失
- 未集成 guacd（RDP 远程桌面不可用）；SSH/SFTP/脚本库/监控等核心功能不受影响
- 面板自动更新（watchtower）未集成，跟随镜像重建更新

## 状态页与 SSH over WebSocket 桥

容器内 3000 端口运行 `wssh-server`（纯 Python 标准库）：

- `http://<host>:3000/` — 状态页（服务状态 + 出站探测 + 日志尾部），平台 HTTP 路由远程检查用
- `ws(s)://<host>:3000/ssh` — WebSocket → 本机 sshd 的双向桥，可穿透 HTTPS 反代/CDN 访问容器 SSH

```
alpine-box status @ 2026-11-14T08:00:00Z
sshd : RUNNING
tunc : RUNNING
tunnel-token: SET
...
```

### 通过平台路由连接 SSH（无需隧道/端口开放）

从仓库 `tools/` 下载 `wssh.py`（纯标准库，客户端只需有 python3），然后：

```bash
# 方式一：ProxyCommand 一次性直连（推荐）
ssh -o ProxyCommand="python3 wssh.py pipe --host alpine-box.deployzy.app --tls" \
    -o StrictHostKeyChecking=accept-new root@alpine-box

# 方式二：本地端口转发
python3 wssh.py tunnel --host alpine-box.deployzy.app --tls --local 2222
ssh -p 2222 root@127.0.0.1
```

传输自动降级：优先尝试 WebSocket（延迟低）；平台反代/CDN 拦截 WS 升级时（如 deployzy 边缘返回 502），自动切换为 HTTP 长轮询（纯 request/response，可穿透任何 HTTP 反代，延迟约一个 RTT）。也可用 `--transport poll` 强制指定。

在正常网络（自有 VPS）上，仍然优先走 Cloudflare Tunnel：隧道 ingress 指向 `ssh://localhost:<SSH_PORT>`，用 `cloudflared access tcp` 直连即可。WS/轮询桥是隧道不可用（平台封锁 7844 等）时的通用兜底 —— 认证由 sshd 公钥完成，安全性等同暴露 22 端口。

> 注：deployzy 自带的 `deployzy tcp`（暴露 TCP 端口到 `deployzy.com:<10000-60000>`）需要 Pro 套餐，免费版会报 "tcp tunnels require a paid plan"。

## 部署到 deployzy

1. 项目类型选 **预构建镜像**：`ghcr.io/nxcoom/alpine-box:latest`（首次发布后需在 GitHub Packages 设置中把该镜像设为 public）。
2. 配置环境变量：

```
SSH_ENABLED=true
SSH_PORT=2022
SSH_PUBLIC_KEY=ssh-ed25519 AAAA... （你的公钥）
CF_TOKEN=eyJ... （Cloudflare Tunnel Token）
SHOW_LOG=true
FILE_PATH=/var/lib/alpine-box
```

3. 部署后平台日志可见：`sshd 已启动` / `tunc (Cloudflare Tunnel) 已启动`。

本地直接运行：

```bash
docker run -d --name alpine-box \
  -p 2022:2022 \
  -e SSH_PORT=2022 \
  -e SSH_PUBLIC_KEY="ssh-ed25519 AAAA..." \
  -e CF_TOKEN="eyJ..." \
  ghcr.io/nxcoom/alpine-box:latest
```

进入容器后可直接运行 `sshx` / `tunc` / `guan` 交互菜单：

```bash
ssh -p 2022 root@<host>
guan        # 服务管理菜单 (OpenRC)
tunc        # Tunnel 管理菜单
sshx        # SSH 配置菜单
```

## 构建

推送 `main` 分支或打 `v*` 标签后，GitHub Actions 自动构建 `linux/amd64` + `linux/arm64` 双架构镜像并发布到 GHCR（先跑冒烟测试：真实 SSH 登录验证 + 三个工具可用性检查）。

手动触发：Actions → build → Run workflow。

## 脚本来源

三个脚本为原版整合（与线上分发版本一致）：

- `https://sb.vir.kdns.fr/sh/ssh.sh` （v2.1）
- `https://tun.uvn.kdns.fr/tunc.sh`
- `https://tun.uvn.kdns.fr/guan.sh` （v1.2.1）
