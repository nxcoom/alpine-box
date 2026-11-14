# ============================================================
#  alpine-box — Alpine 系统镜像
#  集成: sshx (SSH 一键配置) / tunc (Cloudflare Tunnel) / guan (服务管理菜单)
#  平台环境变量: SSH_ENABLED / SSH_PORT / SSH_PUBLIC_KEY / CF_TOKEN / SHOW_LOG / FILE_PATH
# ============================================================
FROM alpine:3.22

LABEL org.opencontainers.image.title="alpine-box" \
      org.opencontainers.image.description="Alpine 系统镜像: sshx (SSH) + tunc (Cloudflare Tunnel) + guan (服务管理), 支持 deployzy 平台环境变量" \
      org.opencontainers.image.licenses="MIT"

ENV SSH_ENABLED=true \
    SSH_PORT=22 \
    SHOW_LOG=true \
    TZ=UTC

RUN apk add --no-cache bash curl wget openssh openrc ca-certificates tzdata

COPY scripts/ /opt/scripts/
COPY entrypoint.sh /entrypoint.sh
COPY healthcheck.sh /usr/local/bin/healthcheck

# 注册工具命令; tunc 采用测试根目录模式安装:
#   一次下载 cloudflared, 同时产出 OpenRC 服务文件 (/usr/local/share/tunc.openrc-init)
#   运行时 entrypoint 再装入 /etc/init.d/tunc (容器内 OpenRC 引导)
RUN chmod +x /entrypoint.sh /usr/local/bin/healthcheck \
 && cp /opt/scripts/ssh.sh  /usr/local/bin/sshx && chmod 755 /usr/local/bin/sshx \
 && cp /opt/scripts/guan.sh /usr/local/bin/guan && chmod 755 /usr/local/bin/guan \
 && mkdir -p /usr/local/lib/tunc /etc/tunc /run/openrc \
 && TUNC_INSTALL_ROOT=/tmp/troot TUNC_INIT=openrc sh /opt/scripts/tunc.sh --token build-placeholder --no-start \
 && cp /tmp/troot/usr/local/lib/tunc/tunc    /usr/local/lib/tunc/tunc \
 && cp /tmp/troot/usr/local/lib/tunc/VERSION /usr/local/lib/tunc/VERSION \
 && cp /tmp/troot/usr/local/bin/tunc         /usr/local/bin/tunc \
 && cp /tmp/troot/etc/init.d/tunc            /usr/local/share/tunc.openrc-init \
 && rm -rf /tmp/troot \
 && chmod 755 /usr/local/lib/tunc/tunc /usr/local/bin/tunc \
 && tunc version

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s CMD /usr/local/bin/healthcheck

# 3000: 状态页 (服务状态 + tunc/messages 日志尾部)
EXPOSE 3000

ENTRYPOINT ["/entrypoint.sh"]
