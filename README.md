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
| `FILE_PATH` | `/var/lib/alpine-box` | 数据目录，SSH 主机密钥持久化在其中 `host-keys/` |

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
