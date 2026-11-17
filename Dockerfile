# ============================================================
#  alpine-box-lite — Alpine 系统镜像 (轻量分支)
#  集成: sshx (SSH 一键配置) / tunc (Cloudflare Tunnel) / guan (服务管理菜单)
#        + web_ssh (Go 单文件 webSSH 面板) + wssh (SSH over HTTP 桥 + 状态页)
#  平台环境变量: SSH_ENABLED / SSH_PORT / SSH_PUBLIC_KEY / CF_TOKEN / SHOW_LOG
#                FILE_PATH / ADMIN_USER / ADMIN_PASSWORD
# ============================================================
# 轻量分支: 用 casualty01/web_ssh (Go 静态二进制, ~7MB) 替代 Node/EasyNode。
# 内存下降来自"不再运行 EasyNode 的 node 进程", 而非删除 node 二进制 (后者在磁盘上
# 不占运行时内存)。保留 node:22-alpine 基础镜像可沿用 main 分支已验证的 OpenRC 行为,
# 避免换 alpine 版本导致 rc-service/supervise-daemon 版本差异。
FROM node:22-alpine

LABEL org.opencontainers.image.title="alpine-box-lite" \
      org.opencontainers.image.description="Alpine 系统镜像: sshx + tunc + guan + web_ssh + wssh (轻量版)" \
      org.opencontainers.image.licenses="MIT"

ENV SSH_ENABLED=true \
    SSH_PORT=22 \
    SHOW_LOG=true \
    TZ=UTC

RUN apk add --no-cache bash curl wget openssh openrc ca-certificates tzdata python3 iputils tini

# 构建 sshd 特权分离兼容库: 部分容器平台 (Orkestr / rootless Podman / 收紧的 k8s)
# 丢弃 CAP_SYS_CHROOT / CAP_SETGID / CAP_SETUID, 导致 OpenSSH 9.8+ 的 sshd-auth
# 在 preauth 阶段 chroot/setgroups/setresuid 失败 —— sshd 在跑但任何密钥都登录不了。
# chroot-noop.so 将这些失败降级, 兼容受限平台 (capability 完整时行为不变)。
RUN apk add --no-cache --virtual .build-deps gcc musl-dev
COPY chroot-noop.c /chroot-noop.c
RUN gcc -shared -fPIC -Os -o /usr/local/lib/chroot-noop.so /chroot-noop.c -ldl \
 && apk del .build-deps \
 && rm -f /chroot-noop.c

# web_ssh: 直接取上游发布镜像的静态二进制与前端产物 (固定版本 1.3.4),
# 不使用它的 docker-entrypoint.sh (chown/su-exec 需要 CAP_CHOWN/SETUID/SETGID,
# Orkestr 丢弃这些 capability); 本镜像直接以 root 跑静态二进制 (无需 capability)。
COPY --from=casualty01/web_ssh:1.3.4 /app/webssh /usr/local/bin/webssh
COPY --from=casualty01/web_ssh:1.3.4 /app/web/ /opt/webssh/web/

# wstunnel 服务端 (v11.1.0, 与客户端协议版本一致; --restrict-to 限制隧道目标)
ARG TARGETARCH
RUN case "$TARGETARCH" in \
      amd64) WT_ARCH=amd64 ;; \
      arm64) WT_ARCH=arm64 ;; \
      *) WT_ARCH=amd64 ;; \
    esac \
 && curl -fsSL -o /tmp/wt.tar.gz "https://github.com/erebe/wstunnel/releases/download/v11.1.0/wstunnel_11.1.0_linux_${WT_ARCH}.tar.gz" \
 && tar xzf /tmp/wt.tar.gz -C /usr/local/bin wstunnel \
 && rm -f /tmp/wt.tar.gz && chmod 755 /usr/local/bin/wstunnel \
 && wstunnel --version

COPY scripts/ /opt/scripts/
COPY wssh-server.py /usr/local/bin/wssh-server
COPY webssh.openrc-init /usr/local/share/webssh.openrc-init
COPY webssh-provision.py /usr/local/bin/webssh-provision
COPY wstunnel.openrc-init /usr/local/share/wstunnel.openrc-init
COPY entrypoint.sh /entrypoint.sh
COPY healthcheck.sh /usr/local/bin/healthcheck

# 注册工具命令; tunc 采用测试根目录模式安装:
#   一次下载 cloudflared, 同时产出 OpenRC 服务文件 (/usr/local/share/tunc.openrc-init)
#   运行时 entrypoint 再装入 /etc/init.d/tunc (容器内 OpenRC 引导)
RUN chmod +x /entrypoint.sh /usr/local/bin/healthcheck /usr/local/bin/wssh-server /usr/local/bin/webssh-provision \
 && chmod 755 /usr/local/bin/webssh \
 && cp /opt/scripts/ssh.sh  /usr/local/bin/sshx && chmod 755 /usr/local/bin/sshx \
 && cp /opt/scripts/guan.sh /usr/local/bin/guan && chmod 755 /usr/local/bin/guan \
 && mkdir -p /usr/local/lib/tunc /etc/tunc /run/openrc /opt/webssh \
 && TUNC_INSTALL_ROOT=/tmp/troot TUNC_INIT=openrc sh /opt/scripts/tunc.sh --token build-placeholder --no-start \
 && cp /tmp/troot/usr/local/lib/tunc/tunc    /usr/local/lib/tunc/tunc \
 && cp /tmp/troot/usr/local/lib/tunc/VERSION /usr/local/lib/tunc/VERSION \
 && cp /tmp/troot/usr/local/bin/tunc         /usr/local/bin/tunc \
 && cp /tmp/troot/etc/init.d/tunc            /usr/local/share/tunc.openrc-init \
 && rm -rf /tmp/troot \
 && chmod 755 /usr/local/lib/tunc/tunc /usr/local/bin/tunc \
 && chmod 755 /usr/local/share/webssh.openrc-init /usr/local/share/wstunnel.openrc-init \
 && tunc version

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s CMD /usr/local/bin/healthcheck

# 3000: web_ssh 面板 (平台 HTTP 路由, 经 HTTPS 反代)
# 8080: wssh 状态页 + SSH over WebSocket/轮询桥 (备用/直连)
# 8090: wstunnel server (websocket 隧道, --restrict-to 127.0.0.1:2022)
EXPOSE 3000 8080 8090

# tini 作为 PID 1 回收僵尸进程: 容器里 entrypoint fork 的各后台服务 (sshd 会话、
# 看门狗、webssh 重启) 若父进程不 wait 会累积僵尸, 占满平台 pids 上限 (256)
# 后导致 fork: Resource temporarily unavailable (SSH 认证过了但 shell 起不来)。
ENTRYPOINT ["/sbin/tini", "-g", "--", "/entrypoint.sh"]
