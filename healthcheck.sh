#!/bin/sh
# alpine-box 容器健康检查
# SSH 未启用时跳过 sshd 检查; tunc 由 supervise-daemon 自行保活
enabled=$(cat /run/.alpine-box-ssh-enabled 2>/dev/null || echo true)
if [ "$enabled" = "true" ] && ! pgrep -f 'sshd.*[l]istener' >/dev/null 2>&1; then
  exit 1
fi
if [ -s /etc/tunc/token ] && ! pgrep -f 'local/lib/tunc/tunc' >/dev/null 2>&1; then
  exit 1
fi
pgrep -f 'wssh-server' >/dev/null 2>&1 || exit 1
if [ "$(cat /run/.alpine-box-webssh-enabled 2>/dev/null || echo true)" = "true" ] \
   && ! pgrep -f '/usr/local/bin/webssh' >/dev/null 2>&1; then
  exit 1
fi
if [ "$(cat /run/.alpine-box-wstunnel-enabled 2>/dev/null || echo true)" = "true" ] \
   && ! pgrep -f 'wstunnel server' >/dev/null 2>&1; then
  exit 1
fi
exit 0
