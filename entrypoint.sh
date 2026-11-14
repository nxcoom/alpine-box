#!/bin/sh
# ============================================================
#  alpine-box 容器入口
#  集成: sshx (SSH 服务) / tunc (Cloudflare Tunnel) / guan (服务管理)
#
#  支持的环境变量 (deployzy 平台):
#    SSH_ENABLED     是否启用 SSH (默认 true)
#    SSH_PORT        SSH 监听端口 (默认 22, 支持逗号分隔多端口)
#    SSH_PUBLIC_KEY  root 公钥 (逗号/换行分隔, 未设置时使用内置默认公钥)
#    CF_TOKEN        Cloudflare Tunnel Token (设置后自动启动 tunc)
#    SHOW_LOG        是否将服务日志输出到容器 stdout (默认 true)
#    FILE_PATH       数据目录 (持久化 SSH 主机密钥, 默认 /var/lib/alpine-box)
# ============================================================
set -u

DEFAULT_SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBbOngF8zJjVVvAlDWjZnGE83jXrt3aDviPCqIIE5Ju6'

SSH_ENABLED="${SSH_ENABLED:-true}"
SSH_PORT="${SSH_PORT:-22}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-$DEFAULT_SSH_PUBLIC_KEY}"
SHOW_LOG="${SHOW_LOG:-true}"
CF_TOKEN="${CF_TOKEN:-}"
FILE_PATH="${FILE_PATH:-/var/lib/alpine-box}"
PORT="${PORT:-3000}"   # 状态页端口 (deployzy 平台默认探测 3000)

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
echo "$SSH_ENABLED" > /run/.alpine-box-ssh-enabled

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

# ---------- 3. 系统日志 (busybox syslogd, guan 菜单可查看) ----------
syslogd -O /var/log/messages -s 1024 2>/dev/null || true

# ---------- 3.5 状态页 (平台 HTTP 路由可见的服务状态, 便于远程检查) ----------
STATUS_DIR=/var/www/status
mkdir -p "$STATUS_DIR"
write_status() {
  {
    echo "alpine-box status @ $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "sshd : $(pgrep -f 'sshd.*[l]istener' >/dev/null 2>&1 && echo RUNNING || echo STOPPED)"
    echo "tunc : $(pgrep -x tunc >/dev/null 2>&1 && echo RUNNING || echo STOPPED)"
    echo "tunnel-token: $([ -s /etc/tunc/token ] && echo SET || echo NONE)"
    echo
    echo "== tunc.log (tail 20) =="
    tail -n 20 /var/log/tunc.log 2>/dev/null
    echo
    echo "== messages (tail 10) =="
    tail -n 10 /var/log/messages 2>/dev/null
  } > "$STATUS_DIR/index.html" 2>/dev/null
}
( while :; do write_status; sleep 10; done ) &
httpd -f -p "$PORT" -h "$STATUS_DIR" 2>/dev/null &
log "状态页已启动: 端口 $PORT (/var/www/status)"

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
       && ! pgrep -x tunc >/dev/null 2>&1; then
      rc-service tunc start >/dev/null 2>&1 \
        && printf '%b\n' "${YELLOW}[alpine-box]${NC} 看门狗: 已重新拉起 tunc" || true
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
