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
PORT="${PORT:-3000}"   # 平台 HTTP 路由端口 (deployzy 默认探测 3000)
EASYNODE_ENABLED="${EASYNODE_ENABLED:-true}"
EASYNODE_HTTP_PORT="${EASYNODE_HTTP_PORT:-8082}"
# 平台 HTTP 路由指向哪个 web 服务: wssh(默认, 状态页+SSH桥) 或 easynode(管理面板)
WEB_PANEL_ON_PORT="${WEB_PANEL_ON_PORT:-wssh}"

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
EASYNODE_ENABLED=$(to_bool "$EASYNODE_ENABLED")
echo "$SSH_ENABLED" > /run/.alpine-box-ssh-enabled
echo "$EASYNODE_ENABLED" > /run/.alpine-box-easynode-enabled

# 平台 HTTP 路由端口归属: wssh(默认) 或 easynode
WSSH_BIND_PORT="$PORT"
if [ "$WEB_PANEL_ON_PORT" = "easynode" ]; then
  EASYNODE_HTTP_PORT="$PORT"
  WSSH_BIND_PORT=8080
  log "平台路由端口 $PORT → EasyNode 面板 (wssh 桥/状态页改到 8080)"
fi
# init.d start_pre 从环境读取 (openrc-run 子进程只继承 export 的变量)
export EASYNODE_HTTP_PORT

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

# ---------- 2.5 EasyNode 管理面板 (webSSH/SFTP) ----------
if [ "$EASYNODE_ENABLED" = "true" ] && [ -f /opt/easynode/index.js ]; then
  # 数据库持久化: /opt/easynode/app/db → FILE_PATH/easynode (凭据/配置跨重建保留)
  if mkdir -p "$FILE_PATH/easynode" 2>/dev/null && [ -w "$FILE_PATH/easynode" ]; then
    rm -rf /opt/easynode/app/db
    ln -s "$FILE_PATH/easynode" /opt/easynode/app/db
    log "EasyNode 数据目录: $FILE_PATH/easynode"
  else
    warn "FILE_PATH 不可写, EasyNode 数据不持久化 (容器重建后面板账号会重置)"
  fi
  if [ -f /usr/local/share/easynode.openrc-init ]; then
    cp /usr/local/share/easynode.openrc-init /etc/init.d/easynode
    chmod 755 /etc/init.d/easynode
    rc-update add easynode default 2>/dev/null || true
  fi
  # OpenRC 不透传调用方环境变量, 端口经 conf.d 注入 (openrc-run 自动 source, init.d start_pre 引用)
  echo "export EASYNODE_HTTP_PORT='$EASYNODE_HTTP_PORT'" > /etc/conf.d/easynode
  if rc-service easynode start; then
    log "EasyNode 已启动: http://0.0.0.0:$EASYNODE_HTTP_PORT"
  else
    err "EasyNode 启动失败, 可通过 /var/log/easynode.log 查看"
  fi
else
  log "EASYNODE_ENABLED=false, 跳过 EasyNode"
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
    echo "easynode: $(pgrep -f 'index[.]js' >/dev/null 2>&1 && echo RUNNING || echo STOPPED)"
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
    echo "== easynode.log (tail 15, 含初始账号密码) =="
    tail -n 15 /var/log/easynode.log 2>/dev/null
    echo
    echo "== easynode-fallback.log =="
    tail -n 30 /var/log/easynode-fallback.log 2>/dev/null
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
  # 平台路由被 EasyNode 占用时, wssh 先绑定备用端口, 由自检逻辑决定最终归属
  if [ "$WEB_PANEL_ON_PORT" = "easynode" ]; then
    start_wssh "$WSSH_BIND_PORT"
    log "wssh 桥/状态页(备用)已启动: 端口 $WSSH_BIND_PORT"
  else
    start_wssh
    log "状态页 + SSH over WebSocket 桥已启动: 端口 $WSSH_BIND_PORT (WS 路径 /ssh → 本机 sshd:$FIRST_SSH_PORT)"
  fi
else
  warn "python3/wssh-server 不可用, 状态页与 WS 桥不可用"
fi

# ---------- 3.7 EasyNode 编排: 凭据设置 (停服窗口写 NeDB) + 平台路由自检 ----------
# NeDB 不能与运行中的应用并发写 (上游 reset-password.js 同样要求先停服):
# 等应用首次启动生成 key.db → 停服 → 写入环境变量凭据 → 重启 → 自检/回退
if [ "$EASYNODE_ENABLED" = "true" ]; then
  (
    # 1. 等待应用生成 key.db
    n=0
    while [ $n -lt 45 ] && ! [ -s /opt/easynode/app/db/key.db ]; do sleep 2; n=$((n+1)); done
    # 2. 环境变量凭据: 停服 → 写入 → 重启 (重部署后凭据稳定, 不依赖日志里的随机密码)
    if [ -s /opt/easynode/app/db/key.db ] && [ -n "${EASYNODE_ADMIN_USER:-}" ] && [ -n "${EASYNODE_ADMIN_PASSWORD:-}" ]; then
      rc-service easynode stop >/dev/null 2>&1
      ok=""
      m=0
      while [ $m -lt 3 ]; do
        if ( cd /opt/easynode && node /opt/easynode/scripts/alpine-set-creds.mjs >>/var/log/easynode.log 2>&1 ); then
          ok=true; break
        fi
        sleep 3; m=$((m+1))
      done
      rc-service easynode start >/dev/null 2>&1
      if [ "$ok" = "true" ]; then
        log "EasyNode 管理员账号已按环境变量设置: $EASYNODE_ADMIN_USER"
      else
        warn "EasyNode 凭据设置脚本失败, 详情见 /var/log/easynode.log"
      fi
    elif [ ! -s /opt/easynode/app/db/key.db ]; then
      warn "EasyNode key.db 90s 未生成, 凭据沿用应用随机生成 (见 /var/log/easynode.log)"
    fi
    # 3. 平台路由自检: easynode 模式下面板必须应答, 90s 未就绪则回退 wssh
    #    (等待期间 wssh 绝不能占用 $PORT, 否则 node 就绪后会 EADDRINUSE 崩溃循环)
    if [ "$WEB_PANEL_ON_PORT" = "easynode" ]; then
      n=0; up=""
      while [ $n -lt 45 ]; do
        if curl -s -o /dev/null -m 3 "http://127.0.0.1:$PORT/"; then up=true; break; fi
        sleep 2; n=$((n+1))
      done
      if [ "$up" = "true" ]; then
        printf '%b\n' "${GREEN}[alpine-box]${NC} easynode 自检通过, 面板在端口 $PORT"
      else
        {
          echo "== easynode 自检失败 @ $(date -u '+%FT%TZ') (端口 $PORT)"
          echo "-- netstat:"; netstat -tln 2>/dev/null | head -20
          echo "-- node 进程:"; pgrep -af node | head -5
          echo "-- easynode.log 尾部:"; tail -30 /var/log/easynode.log 2>/dev/null
        } >> /var/log/easynode-fallback.log 2>&1
        echo false > /run/.alpine-box-easynode-enabled
        rc-service easynode stop >/dev/null 2>&1 || true
        start_wssh "$PORT"
        printf '%b\n' "${YELLOW}[alpine-box]${NC} easynode 90s 未就绪, 状态页/SSH 桥已接管端口 $PORT (诊断: /var/log/easynode-fallback.log)"
      fi
    fi
  ) &
fi

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
    if [ "$(cat /run/.alpine-box-easynode-enabled 2>/dev/null)" = "true" ] \
       && [ -f /etc/init.d/easynode ] \
       && ! pgrep -f 'index[.]js' >/dev/null 2>&1; then
      rc-service easynode stop >/dev/null 2>&1
      rc-service easynode start >/dev/null 2>&1 \
        && printf '%b\n' "${YELLOW}[alpine-box]${NC} 看门狗: 已重新拉起 easynode" || true
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
