#!/bin/sh
# ============================================================
#  alpine-box 容器入口
#  集成: sshx (SSH 服务) / tunc (Cloudflare Tunnel) / guan (服务管理)
#        + web_ssh (Go webSSH 面板) + wssh (SSH over HTTP 桥 + 状态页)
#
#  支持的环境变量:
#    SSH_ENABLED / SSH_PORT / SSH_PUBLIC_KEY / CF_TOKEN / SHOW_LOG / FILE_PATH  (同前)
#    PORT            平台 HTTP 路由端口 (默认 3000, web_ssh 面板占用; wssh 桥退到 8080)
#    ADMIN_USER       web_ssh 面板管理员 (默认 admin)
#    ADMIN_PASSWORD   web_ssh 面板密码 (默认 admin, 生产务必设置)
#    WSTUNNEL_*       wstunnel 服务端 (默认开启)
# ============================================================
set -u

DEFAULT_SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBbOngF8zJjVVvAlDWjZnGE83jXrt3aDviPCqIIE5Ju6'

SSH_ENABLED="${SSH_ENABLED:-true}"
SSH_PORT="${SSH_PORT:-22}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-$DEFAULT_SSH_PUBLIC_KEY}"
SHOW_LOG="${SHOW_LOG:-true}"
CF_TOKEN="${CF_TOKEN:-}"
FILE_PATH="${FILE_PATH:-/var/lib/alpine-box}"
PORT="${PORT:-3000}"   # 平台 HTTP 路由端口 (web_ssh 面板监听)
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"
# 平台 HTTP 路由: web_ssh 面板占 $PORT; wssh 桥/状态页在备用端口 8080
WSSH_BIND_PORT=8080
WSTUNNEL_ENABLED="${WSTUNNEL_ENABLED:-true}"
WSTUNNEL_PORT="${WSTUNNEL_PORT:-8090}"
WSTUNNEL_RESTRICT_TO="${WSTUNNEL_RESTRICT_TO:-127.0.0.1:2022}"

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { printf '%b\n' "${GREEN}[alpine-box]${NC} $*"; }
warn() { printf '%b\n' "${YELLOW}[alpine-box]${NC} $*"; }
err()  { printf '%b\n' "${RED}[alpine-box]${NC} $*"; }

to_bool() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|y|on) echo true ;;
    *) echo false ;;
  esac
}
SSH_ENABLED=$(to_bool "$SSH_ENABLED")
SHOW_LOG=$(to_bool "$SHOW_LOG")
WSTUNNEL_ENABLED=$(to_bool "$WSTUNNEL_ENABLED")
echo "$SSH_ENABLED" > /run/.alpine-box-ssh-enabled
echo "$WSTUNNEL_ENABLED" > /run/.alpine-box-wstunnel-enabled
echo true > /run/.alpine-box-webssh-enabled

# 平台 HTTP 路由端口 $PORT → web_ssh 面板; wssh 桥/状态页备用端口见 WSSH_BIND_PORT

# cloudflared 边缘连接参数透传 (例如出口仅 IPv6 可用时: TUNNEL_EDGE_IP_VERSION=6)
[ -n "${TUNNEL_EDGE_IP_VERSION:-}" ] && export TUNNEL_EDGE_IP_VERSION
[ -n "${TUNNEL_TRANSPORT_PROTOCOL:-}" ] && export TUNNEL_TRANSPORT_PROTOCOL

# ---------- OpenRC 容器内引导 ----------
mkdir -p /run/openrc
touch /run/openrc/softlevel

# ---------- 1. SSH (sshd + 主机密钥 + 公钥) ----------
# 主机密钥优先存到 FILE_PATH (平台持久卷) 以保持指纹稳定, 不可写则回退 /etc/ssh
HOSTKEY_DIR=""
if [ -n "$FILE_PATH" ]; then
  if mkdir -p "$FILE_PATH/host-keys" 2>/dev/null && [ -w "$FILE_PATH/host-keys" ]; then
    HOSTKEY_DIR="$FILE_PATH/host-keys"
  fi
fi
[ -n "$HOSTKEY_DIR" ] || HOSTKEY_DIR="/etc/ssh"

have_host_key() { ls "$HOSTKEY_DIR"/ssh_host_*_key >/dev/null 2>&1; }
gen_host_keys() {
  for t in rsa ecdsa ed25519; do
    [ -f "$HOSTKEY_DIR/ssh_host_${t}_key" ] || \
      ssh-keygen -q -t "$t" -N '' -f "$HOSTKEY_DIR/ssh_host_${t}_key" </dev/null 2>/dev/null || true
  done
}
if ! have_host_key; then
  log "生成 SSH 主机密钥: $HOSTKEY_DIR"
  gen_host_keys
fi
if ! have_host_key; then
  warn "$HOSTKEY_DIR 不可写, 主机密钥回退到 /etc/ssh (容器重建后指纹会变化)"
  HOSTKEY_DIR="/etc/ssh"
  gen_host_keys
fi

# 端口解析: 数字或逗号分隔多端口; 全部非法回退 22
PORTS=$(printf '%s' "$SSH_PORT" | tr ',' '\n' | sed -n 's/^[[:space:]]*\([0-9]\{1,5\}\)[[:space:]]*$/\1/p' | sort -u)
[ -n "$PORTS" ] || { warn "SSH_PORT 无效 ($SSH_PORT), 回退为 22"; PORTS=22; }

mkdir -p /etc/ssh
{
  echo "# 由 alpine-box entrypoint 生成 (终端里运行 sshx 可交互修改)"
  printf 'Port %s\n' $PORTS
  for k in "$HOSTKEY_DIR"/ssh_host_*_key; do
    [ -f "$k" ] && echo "HostKey $k"
  done
  echo "PermitRootLogin yes"
  echo "PubkeyAuthentication yes"
  echo "PasswordAuthentication no"
  echo "KbdInteractiveAuthentication no"
  echo "UseDNS no"
  echo "AllowTcpForwarding yes"
  echo "ClientAliveInterval 30"
  echo "ClientAliveCountMax 6"
  echo "PidFile /run/sshd.pid"
  echo "Subsystem sftp internal-sftp"
} > /etc/ssh/sshd_config

mkdir -p /root/.ssh
chmod 700 /root/.ssh
: > /root/.ssh/authorized_keys
if [ -n "$SSH_PUBLIC_KEY" ]; then
  printf '%s\n' "$SSH_PUBLIC_KEY" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | while IFS= read -r k; do
        [ -n "$k" ] && printf '%s\n' "$k" >> /root/.ssh/authorized_keys
      done
  log "已写入公钥: $(grep -c . /root/.ssh/authorized_keys) 个"
fi
chmod 600 /root/.ssh/authorized_keys

# 部分容器平台 (Orkestr / rootless Podman / 收紧的 k8s) 丢弃
# CAP_SYS_CHROOT / CAP_SETGID / CAP_SETUID, OpenSSH 9.8+ 的 sshd-auth 在
# preauth 阶段 chroot/setgroups/setresuid 会 fatal, 表现为 sshd 在监听但任何
# 密钥都登录不了。注入特权分离兼容库降级这些失败 (capability 完整时不干预)。
# OpenRC 不透传调用方环境变量, 必须经 /etc/conf.d/sshd 注入 (见 [[alpine-box]] 历史坑)。
SSH_CONF_D=/etc/conf.d/sshd
mkdir -p /etc/conf.d
if [ -f /usr/local/lib/chroot-noop.so ]; then
  # 去掉旧注入 (容器重建/重复执行时保持幂等), 保留其它自定义配置
  grep -v 'LD_PRELOAD=.*chroot-noop' "$SSH_CONF_D" > "$SSH_CONF_D.tmp" 2>/dev/null \
    || : > "$SSH_CONF_D.tmp"
  mv "$SSH_CONF_D.tmp" "$SSH_CONF_D"
  printf "export LD_PRELOAD='/usr/local/lib/chroot-noop.so'\n" >> "$SSH_CONF_D"
  log "sshd 启用特权分离兼容层 (适配丢弃 capability 的容器平台)"
fi

if [ "$SSH_ENABLED" = "true" ]; then
  if sshd -t 2>/dev/null; then
    rc-update add sshd default 2>/dev/null || true
    if rc-service sshd start; then
      log "sshd 已启动, 监听端口: $(printf '%s ' $PORTS)"
    else
      err "sshd 启动失败, 请检查 /etc/ssh/sshd_config"
    fi
  else
    err "sshd 配置校验失败:"
    sshd -t || true
  fi
else
  log "SSH_ENABLED=false, 跳过 SSH 服务"
fi

# ---------- 2. tunc (Cloudflare Tunnel) ----------
# OpenRC 服务文件在构建时由 tunc.sh 生成, 这里安装到 /etc/init.d (始终安装, 有 Token 才启动)
if [ -f /usr/local/share/tunc.openrc-init ]; then
  cp /usr/local/share/tunc.openrc-init /etc/init.d/tunc
  chmod 755 /etc/init.d/tunc
  rc-update add tunc default 2>/dev/null || true
fi
# cloudflared 高级参数: OpenRC 不透传环境变量, 通过 conf.d 注入 (openrc-run 自动 source)
CONF_D_TUNC=/etc/conf.d/tunc
[ -n "${TUNNEL_TRANSPORT_PROTOCOL:-}" ] && echo "export TUNNEL_TRANSPORT_PROTOCOL='$TUNNEL_TRANSPORT_PROTOCOL'" >> "$CONF_D_TUNC"
[ -n "${TUNNEL_EDGE_IP_VERSION:-}" ] && echo "export TUNNEL_EDGE_IP_VERSION='$TUNNEL_EDGE_IP_VERSION'" >> "$CONF_D_TUNC"
# 限制 Go runtime 线程数: 容器 pids 上限低 (Orkestr 256), cloudflared 默认按宿主
# 机 CPU 核数起线程会撑爆 PID 表, 导致 SSH 会话 fork 失败。限制为 2 足够跑隧道。
echo 'export GOMAXPROCS=2' >> "$CONF_D_TUNC"
[ -f "$CONF_D_TUNC" ] && log "tunc conf.d: $(cat "$CONF_D_TUNC" | tr '\n' '; ')"
if [ -n "$CF_TOKEN" ]; then
  mkdir -p /etc/tunc
  printf '%s' "$CF_TOKEN" > /etc/tunc/token
  chmod 600 /etc/tunc/token
  if rc-service tunc start; then
    log "tunc (Cloudflare Tunnel) 已启动, 日志: /var/log/tunc.log"
  else
    err "tunc 启动失败, 可通过 tunc log / tunc status 查看"
  fi
else
  log "未设置 CF_TOKEN, 不启动 Cloudflare Tunnel (之后可用 tunc token <TOKEN> && tunc start)"
fi

# ---------- 2.5 web_ssh 面板 (casualty01/web_ssh, Go 静态二进制) ----------
# FILE_PATH 下持久化 webssh 数据 (store.json: 会话/隧道/管理员) 与预置密钥。
WEBSSH_DATA_DIR="$FILE_PATH/webssh"
mkdir -p "$WEBSSH_DATA_DIR" 2>/dev/null || WEBSSH_DATA_DIR=/var/lib/alpine-box/webssh
chmod 700 "$WEBSSH_DATA_DIR" 2>/dev/null || true

# 首次启动预置: 生成专用密钥 -> 加入 sshd authorized_keys -> 写 local-box 会话。
# 必须在启动 webssh 之前完成 (web_ssh 启动时把 store.json 读入内存)。
FIRST_SSH_PORT_EARLY=$(printf '%s' "$PORTS" | head -n 1)
python3 /usr/local/bin/webssh-provision "$WEBSSH_DATA_DIR" "$FIRST_SSH_PORT_EARLY" /root/.ssh/authorized_keys \
  && log "web_ssh 已预置本机会话 local-box (127.0.0.1:$FIRST_SSH_PORT_EARLY)" \
  || warn "webssh-provision 失败 (详见容器日志), 面板仍会启动但无预置会话"

if [ -x /usr/local/bin/webssh ] && [ -f /usr/local/share/webssh.openrc-init ]; then
  cp /usr/local/share/webssh.openrc-init /etc/init.d/webssh
  chmod 755 /etc/init.d/webssh
  rc-update add webssh default 2>/dev/null || true
  # OpenRC 不透传调用方环境变量, 配置经 conf.d 注入 (openrc-run 自动 source)
  {
    echo "export DATA_DIR='$WEBSSH_DATA_DIR'"
    echo "export WEB_DIR='/opt/webssh/web'"
    echo "export LISTEN_ADDR=':$PORT'"
    echo "export ADMIN_USER='$ADMIN_USER'"
    echo "export ADMIN_PASSWORD='$ADMIN_PASSWORD'"
    echo 'export GOMAXPROCS=2'   # 限制 Go 线程, 避免低 pids 上限被撑爆
  } > /etc/conf.d/webssh
  if rc-service webssh start; then
    log "web_ssh 面板已启动: http://0.0.0.0:$PORT (admin=$ADMIN_USER)"
  else
    err "web_ssh 启动失败, 可通过 /var/log/webssh.log 查看"
  fi
else
  warn "webssh 二进制/OpenRC 文件缺失, 跳过 web_ssh 面板"
fi

# ---------- 2.6 wstunnel 服务端 (websocket 隧道, 供 wstunnel.exe 等客户端接入) ----------
if [ "$WSTUNNEL_ENABLED" = "true" ] && [ -x /usr/local/bin/wstunnel ] && [ -f /usr/local/share/wstunnel.openrc-init ]; then
  cp /usr/local/share/wstunnel.openrc-init /etc/init.d/wstunnel
  chmod 755 /etc/init.d/wstunnel
  rc-update add wstunnel default 2>/dev/null || true
  # OpenRC 不透传调用方环境变量, 参数经 conf.d 注入
  {
    echo "export WSTUNNEL_PORT='$WSTUNNEL_PORT'"
    echo "export WSTUNNEL_RESTRICT_TO='$WSTUNNEL_RESTRICT_TO'"
    echo 'export GOMAXPROCS=2'
  } > /etc/conf.d/wstunnel
  if rc-service wstunnel start; then
    log "wstunnel 服务端已启动: ws://0.0.0.0:$WSTUNNEL_PORT (仅允许隧道到 $WSTUNNEL_RESTRICT_TO)"
  else
    err "wstunnel 启动失败, 详见 /var/log/wstunnel.log"
  fi
else
  log "WSTUNNEL_ENABLED=false 或二进制缺失, 跳过 wstunnel"
fi

# ---------- 3. 系统日志 (busybox syslogd, guan 菜单可查看) ----------
syslogd -O /var/log/messages -s 1024 2>/dev/null || true

# ---------- 3.5 状态页 (平台 HTTP 路由可见的服务状态, 便于远程检查) ----------
STATUS_DIR=/var/www/status
mkdir -p "$STATUS_DIR"
write_status() {
  {
    echo "alpine-box status @ $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "sshd : $(pgrep -f 'sshd.*[l]istener' >/dev/null 2>&1 && echo RUNNING || echo STOPPED)"
    echo "tunc : $(pgrep -f 'local/lib/tunc/tunc' >/dev/null 2>&1 && echo RUNNING || echo STOPPED)"
    echo "tunnel-token: $([ -s /etc/tunc/token ] && echo SET || echo NONE)"
    echo "webssh : $(pgrep -f '/usr/local/bin/webssh' >/dev/null 2>&1 && echo RUNNING || echo STOPPED)"
    echo "wstunnel: $(pgrep -f 'wstunnel server' >/dev/null 2>&1 && echo RUNNING || echo STOPPED)"
    echo
    echo "== 网络出站探测 =="
    for hp in region1.v2.argotunnel.com:7844 api.cloudflare.com:443 www.cloudflare.com:443 github.com:443; do
      h=${hp%:*}; p=${hp#*:}
      if timeout 4 bash -c "exec 3<>/dev/tcp/$h/$p" 2>/dev/null; then
        echo "TCP $hp : OK"
      else
        echo "TCP $hp : FAIL"
      fi
    done
    echo "proxy-env: HTTP_PROXY=${HTTP_PROXY:-无} HTTPS_PROXY=${HTTPS_PROXY:-无} ALL_PROXY=${ALL_PROXY:-无}"
    echo
    echo "== wssh.log (tail 15) =="
    tail -n 15 /var/log/wssh.log 2>/dev/null
    echo
    echo "== webssh.log (tail 15) =="
    tail -n 15 /var/log/webssh.log 2>/dev/null
    echo
    echo "== wstunnel.log (tail 10) =="
    tail -n 10 /var/log/wstunnel.log 2>/dev/null
    echo
    echo "== tunc.log (tail 40) =="
    tail -n 40 /var/log/tunc.log 2>/dev/null
    echo
    echo "== messages (tail 15) =="
    tail -n 15 /var/log/messages 2>/dev/null
  } > "$STATUS_DIR/index.html" 2>/dev/null
}
( while :; do write_status; sleep 10; done ) &

# ---------- 3.6 SSH over WebSocket 桥 (经平台 HTTPS 路由远程访问容器 SSH) ----------
# WS 路径 /ssh 双向桥接到本机 sshd; 配合客户端 tools/wssh.py:
#   ssh -o ProxyCommand="python3 wssh.py pipe --host <域名> --tls" root@<域名>
FIRST_SSH_PORT=$(printf '%s' "$PORTS" | head -n 1)
export WSSH_LOG=/var/log/wssh.log
: > "$WSSH_LOG" 2>/dev/null || true
start_wssh() {
  python3 /usr/local/bin/wssh-server "${1:-$WSSH_BIND_PORT}" "$STATUS_DIR" 127.0.0.1 "$FIRST_SSH_PORT" >/dev/null 2>&1 &
}
if command -v python3 >/dev/null 2>&1 && [ -x /usr/local/bin/wssh-server ]; then
  start_wssh "$WSSH_BIND_PORT"
  log "wssh 桥/状态页已启动: 端口 $WSSH_BIND_PORT (WS 路径 /ssh → 本机 sshd:$FIRST_SSH_PORT); 若面板 60s 未就绪会接管端口 $PORT"
else
  warn "python3/wssh-server 不可用, 状态页与 WS 桥不可用"
fi

# ---------- 3.7 平台路由自检: webssh 未就绪则让 wssh 接管 $PORT ----------
(
  n=0; up=""
  while [ $n -lt 30 ]; do  # 最多 ~60s
    if curl -s -o /dev/null -m 3 "http://127.0.0.1:$PORT/"; then up=true; break; fi
    sleep 2; n=$((n+1))
  done
  if [ "$up" = "true" ]; then
    printf '%b\n' "${GREEN}[alpine-box]${NC} web_ssh 自检通过, 面板在端口 $PORT"
  else
    {
      echo "== web_ssh 自检失败 @ $(date -u '+%FT%TZ') (端口 $PORT)"
      echo "-- netstat:"; netstat -tln 2>/dev/null | head -20
      echo "-- webssh 进程:"; pgrep -af webssh | head -5
      echo "-- webssh.log 尾部:"; tail -30 /var/log/webssh.log 2>/dev/null
    } >> /var/log/webssh-fallback.log 2>&1
    echo false > /run/.alpine-box-webssh-enabled
    rc-service webssh stop >/dev/null 2>&1 || true
    start_wssh "$PORT"
    printf '%b\n' "${YELLOW}[alpine-box]${NC} web_ssh 60s 未就绪, 状态页/SSH 桥已接管端口 $PORT (诊断: /var/log/webssh-fallback.log)"
  fi
) &

# ---------- 4. 看门狗: 每 30s 检查, 服务被杀后自动拉起 ----------
(
  while :; do
    sleep 30
    if [ "$(cat /run/.alpine-box-ssh-enabled 2>/dev/null)" = "true" ] \
       && ! pgrep -f 'sshd.*[l]istener' >/dev/null 2>&1; then
      rc-service sshd start >/dev/null 2>&1 \
        && printf '%b\n' "${YELLOW}[alpine-box]${NC} 看门狗: 已重新拉起 sshd" || true
    fi
    if [ -s /etc/tunc/token ] && [ -f /etc/init.d/tunc ] \
       && ! pgrep -f 'local/lib/tunc/tunc' >/dev/null 2>&1; then
      # supervise-daemon 可能仍在但子进程已死, 先 stop 清理状态再拉起
      rc-service tunc stop >/dev/null 2>&1
      rc-service tunc start >/dev/null 2>&1 \
        && printf '%b\n' "${YELLOW}[alpine-box]${NC} 看门狗: 已重新拉起 tunc" || true
    fi
    if ! pgrep -f 'wssh-server' >/dev/null 2>&1; then
      start_wssh 2>/dev/null \
        && printf '%b\n' "${YELLOW}[alpine-box]${NC} 看门狗: 已重新拉起 wssh-server" || true
    fi
    if [ "$(cat /run/.alpine-box-wstunnel-enabled 2>/dev/null)" = "true" ] \
       && [ -f /etc/init.d/wstunnel ] \
       && ! pgrep -f 'wstunnel server' >/dev/null 2>&1; then
      rc-service wstunnel start >/dev/null 2>&1 \
        && printf '%b\n' "${YELLOW}[alpine-box]${NC} 看门狗: 已重新拉起 wstunnel" || true
    fi
    if [ "$(cat /run/.alpine-box-webssh-enabled 2>/dev/null)" != "false" ] \
       && [ -f /etc/init.d/webssh ] \
       && ! pgrep -f '/usr/local/bin/webssh' >/dev/null 2>&1; then
      rc-service webssh stop >/dev/null 2>&1
      rc-service webssh start >/dev/null 2>&1 \
        && printf '%b\n' "${YELLOW}[alpine-box]${NC} 看门狗: 已重新拉起 web_ssh" || true
    fi
  done
) &

log "alpine-box 已就绪 | 工具: sshx (SSH 配置菜单) · tunc (Tunnel 管理) · guan (服务管理菜单)"

trap 'exit 0' TERM INT
if [ "$SHOW_LOG" = "true" ]; then
  touch /var/log/tunc.log /var/log/messages 2>/dev/null || true
  # 前台跟随日志, 供 docker logs / 平台日志查看
  exec tail -n 40 -f /var/log/tunc.log /var/log/messages 2>/dev/null
fi
while :; do sleep 3600; done
