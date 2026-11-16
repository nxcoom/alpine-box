/*
 * chroot-noop.so — 让 OpenSSH 的 preauth privsep chroot() 变成空操作。
 *
 * 背景: OpenSSH 9.8+ 把 sshd 拆成 sshd → sshd-session → sshd-auth。
 * sshd-auth 在认证前会 chroot(_PATH_PRIVSEP_CHROOT_DIR, 默认 /var/empty)
 * 并 drop 到 sshd 用户。该 chroot() 需要 CAP_SYS_CHROOT。
 * 一些容器平台 (如 Orkestr / rootless Podman / 收紧的 k8s) 默认丢弃该 capability,
 * 于是每次连接在 preauth 阶段即 fatal: chroot("/var/empty"): Operation not
 * permitted [preauth] —— sshd 明明在监听, 但任何公钥都认证不了。
 *
 * 这里把 chroot() 重定向为返回成功。sshd 不使用 ChrootDirectory (本镜像未配置),
 * 因此 preauth chroot 的唯一作用就是 privsep 沙箱; no-op 只影响 sshd 进程树
 * (经 /etc/conf.d/sshd 的 LD_PRELOAD 注入), 不影响其它服务。
 *
 * 编译需 musl-gcc / gcc, 产物必须是构建目标 musl 兼容的 .so。
 */
int chroot(const char *path) {
    (void)path;
    return 0;
}
