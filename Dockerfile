# ============================================================
#  alpine-box — Alpine 系统镜像
#  集成: sshx (SSH 一键配置) / tunc (Cloudflare Tunnel) / guan (服务管理菜单)
#        + EasyNode (webSSH/SFTP 管理面板) + wssh (SSH over HTTP 桥 + 状态页)
#  平台环境变量: SSH_ENABLED / SSH_PORT / SSH_PUBLIC_KEY / CF_TOKEN / SHOW_LOG / FILE_PATH
# ============================================================
# 基础镜像用 node:22-alpine: EasyNode 的 node_modules 由 node22 构建,
# ABI 必须与运行时一致; 两者同为 Alpine 系。
FROM node:22-alpine

LABEL org.opencontainers.image.title="alpine-box" \
      org.opencontainers.image.description="Alpine 系统镜像: sshx (SSH) + tunc (Cloudflare Tunnel) + guan (服务管理) + EasyNode (webSSH 面板) + wssh (SSH over HTTP 桥)" \
      org.opencontainers.image.licenses="MIT"

ENV SSH_ENABLED=true \
    SSH_PORT=22 \
    SHOW_LOG=true \
    TZ=UTC

RUN apk add --no-cache bash curl wget openssh openrc ca-certificates tzdata python3 iputils

# EasyNode: 直接取官方镜像产物 (双架构 amd64/arm64), 应用在 /opt/easynode
COPY --from=chaoszhu/easynode:latest /easynode /opt/easynode

COPY scripts/ /opt/scripts/
COPY wssh-server.py /usr/local/bin/wssh-server
# 凭据脚本必须放在 /opt/easynode 内: ESM 裸导入按脚本位置解析 nedb
COPY easynode-scripts/set-creds.mjs /opt/easynode/scripts/alpine-set-creds.mjs
COPY easynode.openrc-init /usr/local/share/easynode.openrc-init
COPY entrypoint.sh /entrypoint.sh
COPY healthcheck.sh /usr/local/bin/healthcheck

# 注册工具命令; tunc 采用测试根目录模式安装:
#   一次下载 cloudflared, 同时产出 OpenRC 服务文件 (/usr/local/share/tunc.openrc-init)
#   运行时 entrypoint 再装入 /etc/init.d/tunc (容器内 OpenRC 引导)
RUN chmod +x /entrypoint.sh /usr/local/bin/healthcheck /usr/local/bin/wssh-server \
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
 && chmod 755 /usr/local/share/easynode.openrc-init \
 && tunc version

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s CMD /usr/local/bin/healthcheck

# 3000: 状态页 + SSH over WebSocket/轮询桥 (wssh, 经平台 HTTPS 路由访问容器 SSH)
# 8082: EasyNode 面板 (webSSH/SFTP)
EXPOSE 3000 8082

ENTRYPOINT ["/entrypoint.sh"]
