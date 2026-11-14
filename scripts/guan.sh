#!/bin/sh
# ============================================================
#  guan v1.0.0 — 通用服务管理交互式菜单 (POSIX sh)
#  目标环境: supervisord / systemd / OpenRC / s6
# ------------------------------------------------------------
#  用法:
#    sh guan.sh                交互菜单(自动检测可用的 init 系统)
#    sh guan.sh supervisord    直接进入 supervisord 管理
#    sh guan.sh systemd        直接进入 systemd 管理
#    sh guan.sh openrc         直接进入 OpenRC 管理
#    sh guan.sh s6             直接进入 s6 管理
#    sh guan.sh install        注册 guan 命令(默认装到 /usr/local/bin)
#    sh guan.sh uninstall      卸载 guan 命令
#    sh guan.sh help           帮助
#
#  环境变量(可选):
#    GUAN_INSTALL_DIR   自定义安装目录(默认 /usr/local/bin)
#    SUPERVISOR_CONF    指定 supervisord 配置文件路径
#    S6_SERVICEDIR      指定 s6 服务目录(优先于自动检测)
# ============================================================

GUAN_VERSION="1.2.1"

# s6-overlay 兼容: 其工具位于 /command
[ -d /command ] && PATH="$PATH:/command"
export PATH

# ---------- 输出工具 ----------
if [ -t 1 ]; then
  C_R="\033[31m"; C_G="\033[32m"; C_Y="\033[33m"
  C_C="\033[36m"; C_B="\033[1m"; C_0="\033[0m"
else
  C_R=""; C_G=""; C_Y=""; C_C=""; C_B=""; C_0=""
fi

say()  { printf '%b\n' "$*"; }
ok()   { printf '%b\n' "${C_G}[OK]${C_0} $*"; }
warn() { printf '%b\n' "${C_Y}[!]${C_0} $*"; }
err()  { printf '%b\n' "${C_R}[X]${C_0} $*"; }
cls()  { [ -t 1 ] && printf '\033[H\033[2J'; return 0; }

# Ctrl+C: 在跟随日志(尾部 -f)时按 Ctrl+C 返回菜单，而不是退出脚本
trap ':' INT

ask() {
  printf '%b' "$1"
  read -r REPLY
  st=$?
  if [ "$st" -ne 0 ]; then
    printf '\n'
    [ "$st" -ge 128 ] 2>/dev/null && exit 0
    say "输入已结束(EOF)，退出 guan。"
    exit 0
  fi
}

pause() {
  printf '%b' "${C_C}── 按回车返回菜单 ──${C_0}"
  read -r _p || { printf '\n'; exit 0; }
  printf '\n'
}

confirm() {
  ask "$1 [y/N]: "
  case "$REPLY" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) warn "已取消"; return 1 ;;
  esac
}

mark() {
  if [ "$1" = "1" ]; then printf '%b' "${C_G}●${C_0}"; else printf '%b' "${C_R}○${C_0}"; fi
}

maybe_root_warn() {
  [ "$(id -u)" = "0" ] || warn "当前非 root，部分操作可能因权限失败"
}

# 尽量提权执行直接命令(仅用于 systemctl/rc-service/s6 等二进制)
as_root() {
  if [ "$(id -u)" = "0" ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1 && [ -t 0 ]; then
    warn "需要权限，尝试 sudo: $*"
    sudo "$@"
  else
    "$@"
  fi
}

# 服务/进程名合法性
valid_name() {
  case "$1" in
    ""|*[!A-Za-z0-9_.-]*) return 1 ;;
  esac
  return 0
}

# 把命令首 token 解析为绝对路径: "python3 a.py" -> "/usr/bin/python3 a.py"
resolve_cmd() {
  first=${1%% *}
  rest=""
  case "$1" in
    *" "*) rest=" ${1#* }" ;;
  esac
  case "$first" in
    /*) ;;
    *)
      if abs=$(command -v "$first" 2>/dev/null); then first="$abs"; fi
      ;;
  esac
  printf '%s%s' "$first" "$rest"
}

# ---------- 全局状态 ----------
TARGET=""
HAS_SYSTEMD=0; HAS_OPENRC=0; HAS_S6=0; HAS_SUPERV=0
S6_MODE=""; S6_DIR=""
SUP_CFG=""
SVC=""

# ---------- 环境检测 ----------
detect_s6_env() {
  S6_MODE=""; S6_DIR=""
  if [ -n "${S6_SERVICEDIR:-}" ] && [ -d "$S6_SERVICEDIR" ]; then
    S6_DIR="$S6_SERVICEDIR"
    case "$S6_SERVICEDIR" in
      */servicedirs) S6_MODE="rc" ;;
      *)             S6_MODE="scandir" ;;
    esac
    return 0
  fi
  if command -v s6-rc >/dev/null 2>&1 && command -v s6-rc-db >/dev/null 2>&1; then
    S6_MODE="rc"
    for d in /run/s6-rc /var/run/s6-rc; do
      if [ -d "$d/servicedirs" ]; then S6_DIR="$d/servicedirs"; return 0; fi
    done
    S6_DIR="/run/s6-rc/servicedirs"
    return 0
  fi
  S6_MODE="scandir"
  for d in /run/s6/services /run/service /etc/s6/services /etc/services.d /services; do
    if [ -d "$d" ]; then S6_DIR="$d"; return 0; fi
  done
  S6_DIR=""
  return 0
}

detect_sup_cfg() {
  SUP_CFG=""
  if [ -n "${SUPERVISOR_CONF:-}" ] && [ -f "$SUPERVISOR_CONF" ]; then
    SUP_CFG="$SUPERVISOR_CONF"; return 0
  fi
  for c in /etc/supervisor/supervisord.conf \
           /etc/supervisord.conf \
           /etc/supervisor/conf.d/supervisord.conf; do
    if [ -f "$c" ]; then SUP_CFG="$c"; return 0; fi
  done
  return 1
}

detect_all() {
  HAS_SYSTEMD=0; HAS_OPENRC=0; HAS_S6=0; HAS_SUPERV=0
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    HAS_SYSTEMD=1
  fi
  if command -v rc-service >/dev/null 2>&1 && command -v openrc >/dev/null 2>&1; then
    HAS_OPENRC=1
  fi
  if command -v s6-rc >/dev/null 2>&1 || command -v s6-svc >/dev/null 2>&1 \
     || command -v s6-svstat >/dev/null 2>&1; then
    HAS_S6=1
  fi
  if command -v supervisorctl >/dev/null 2>&1 || command -v supervisord >/dev/null 2>&1; then
    HAS_SUPERV=1
  fi
  detect_s6_env
  detect_sup_cfg
  if [ -z "$TARGET" ]; then
    if   [ "$HAS_SYSTEMD" = "1" ]; then TARGET="systemd"
    elif [ "$HAS_OPENRC"  = "1" ]; then TARGET="openrc"
    elif [ "$HAS_S6"      = "1" ]; then TARGET="s6"
    elif [ "$HAS_SUPERV"  = "1" ]; then TARGET="supervisord"
    fi
  fi
  return 0
}

# ---------- supervisord 封装 ----------
sup() {
  if [ -n "$SUP_CFG" ]; then
    supervisorctl -c "$SUP_CFG" "$@"
  else
    supervisorctl "$@"
  fi
}

sup_start_self() {
  if sup status >/dev/null 2>&1; then
    warn "supervisord 已在运行"; return 1
  fi
  cfg="$SUP_CFG"
  if [ -z "$cfg" ]; then
    ask "输入 supervisord 配置文件路径(回车取消): "
    cfg="$REPLY"
  fi
  [ -z "$cfg" ] && { warn "已取消"; return 1; }
  if [ ! -f "$cfg" ]; then
    err "配置文件不存在: $cfg"; return 1
  fi
  as_root supervisord -c "$cfg" && ok "supervisord 已启动" || err "启动失败，请查看上方报错"
}

# 收集 supervisord 主配置 + [include] 展开的全部配置文件
sup_all_conf() {
  [ -n "$SUP_CFG" ] && [ -f "$SUP_CFG" ] || return 0
  printf '%s\n' "$SUP_CFG"
  cfg_dir="$(dirname "$SUP_CFG")"
  grep -E '^[[:space:]]*files[[:space:]]*=' "$SUP_CFG" 2>/dev/null \
    | sed 's/^[^=]*=[[:space:]]*//' \
    | while IFS= read -r line; do
        for p in $line; do
          case "$p" in
            /*) ls -1 $p 2>/dev/null ;;
            *)  ls -1 "$cfg_dir"/$p 2>/dev/null ;;
          esac
        done
      done
  for extra in /etc/supervisor/conf.d/*.conf /etc/supervisord.d/*.conf /etc/supervisord.d/*.ini; do
    [ -f "$extra" ] && printf '%s\n' "$extra"
  done
  return 0
}

# 查看 [program:x] 的 autostart 值(未设置=默认 true)
sup_show_autostart() {
  if [ -z "$SUP_CFG" ]; then
    warn "未指定 supervisord 配置，请先用选项 15 指定"; return 1
  fi
  say " 进程自启配置 (autostart=true 表示 supervisord 启动时自动拉起):"
  for f in $(sup_all_conf); do
    [ -f "$f" ] && cat "$f"
  done | awk '
    function trim(s){gsub(/^[ \t]+/,"",s);gsub(/[ \t]+$/,"",s);return s}
    /^[ \t]*\[/ {
      cur=""
      if (index($0,"[program:")>0) {
        p=$0; sub(/.*\[program:/,"",p); sub(/\].*/,"",p)
        cur=p; seen[p]=1; auto[p]="(未设置, 默认 true)"
      }
    }
    /^[ \t]*autostart[ \t]*=/ {
      if (cur!="") { v=$0; sub(/^[^=]*=/,"",v); auto[cur]=trim(v) }
    }
    END {
      cnt=0
      for (p in seen) { cnt++; printf "   %-28s autostart=%s\n", p, auto[p] }
      if (cnt==0) print "   (未找到任何 [program:x] 配置段)"
    }'
  return 0
}

# 修改某 [program:x] 的 autostart 开关(带备份, 可选 reread+update 生效)
sup_set_autostart() {
  if [ -z "$SUP_CFG" ]; then
    warn "未指定 supervisord 配置，请先用选项 15 指定"; return 1
  fi
  pick_service supervisord "设置自启" || return 1
  f=""
  for c in $(sup_all_conf); do
    if [ -f "$c" ] && grep -Eq "^[[:space:]]*\[program:$SVC\]" "$c" 2>/dev/null; then
      f="$c"; break
    fi
  done
  if [ -z "$f" ]; then
    err "配置中未找到 [program:$SVC] 段(若它是 [group:x] 的成员，请对其 program 名操作)"
    return 1
  fi
  say " 定义文件: $f"
  cur=$(awk -v prog="$SVC" '
    /^[ \t]*\[/ { cur=""; if (index($0,"[program:"prog"]")>0) cur=prog }
    /^[ \t]*autostart[ \t]*=/ { if (cur==prog) { v=$0; sub(/^[^=]*=/,"",v); gsub(/[ \t]/,"",v); print v } }
  ' "$f")
  say " 当前 autostart = ${cur:-未设置(默认 true)}"
  ask " 设为? [1=开启自启 / 2=关闭自启 / 回车取消]: "
  case "$REPLY" in
    1) val="true" ;;
    2) val="false" ;;
    *) warn "已取消"; return 1 ;;
  esac
  bak="$f.bak.$(date +%Y%m%d%H%M%S)"
  cp "$f" "$bak" || { err "备份失败，放弃修改"; return 1; }
  awk -v prog="$SVC" -v val="$val" '
    /^[ \t]*\[/ {
      if (cur==prog && !done) { print "autostart=" val; done=1 }
      cur=""
      if (index($0,"[program:"prog"]")>0) cur=prog
    }
    /^[ \t]*autostart[ \t]*=/ {
      if (cur==prog) { print "autostart=" val; done=1; next }
    }
    { print }
    END { if (cur==prog && !done) print "autostart=" val }
  ' "$f" > "$f.tmp.$$" && mv "$f.tmp.$$" "$f" \
    && ok "已修改: [program:$SVC] autostart=$val  (备份: $bak)" \
    || { err "修改失败"; rm -f "$f.tmp.$$"; return 1; }
  confirm "立即 reread + update 使配置生效?" && { sup reread; sup update; }
  return 0
}

# ---------- supervisord: 新建进程向导 ----------
sup_gen_program() { # $1=名称 $2=命令(已解析) $3=工作目录 $4=用户
  printf '[program:%s]\n' "$1"
  printf 'command=%s\n' "$2"
  [ -n "$3" ] && printf 'directory=%s\n' "$3"
  [ -n "$4" ] && printf 'user=%s\n' "$4"
  printf 'autostart=true\n'
  printf 'autorestart=true\n'
  printf 'startsecs=3\n'
  printf 'stdout_logfile=/var/log/%s.log\n' "$1"
  printf 'stderr_logfile=/var/log/%s.err.log\n' "$1"
  return 0
}

sup_create_program() {
  if ! command -v supervisord >/dev/null 2>&1 && ! command -v supervisorctl >/dev/null 2>&1; then
    err "本机未安装 supervisor"; pause; return 1
  fi
  ask " 进程名(仅字母数字._-，回车取消): "
  [ -z "$REPLY" ] && { warn "已取消"; return 1; }
  valid_name "$REPLY" || { err "进程名含非法字符: $REPLY"; return 1; }
  name="$REPLY"
  ask " 启动命令(如 python3 /app/main.py，回车取消): "
  [ -z "$REPLY" ] && { warn "已取消"; return 1; }
  cmd="$(resolve_cmd "$REPLY")"
  ask " 工作目录(回车=不设置): "
  wd="$REPLY"
  ask " 运行用户(回车=默认 root): "
  usr="$REPLY"
  suggest=""
  if [ -d /etc/supervisor/conf.d ]; then
    suggest="/etc/supervisor/conf.d/guan-$name.conf"
  elif [ -d /etc/supervisord.d ]; then
    suggest="/etc/supervisord.d/guan-$name.ini"
  elif [ -n "$SUP_CFG" ]; then
    suggest="$SUP_CFG"
  fi
  say " 目标配置文件(建议独立文件，便于管理):"
  ask " 回车=默认 ${suggest:-无}: "
  target="$REPLY"
  [ -z "$target" ] && target="$suggest"
  if [ -z "$target" ]; then
    err "没有可用的目标文件"; return 1
  fi
  if [ -f "$target" ] && grep -Eq "^[[:space:]]*\[program:$name\]" "$target"; then
    err "目标文件已存在 [program:$name] 段"; return 1
  fi
  say ""
  say " 将追加到 $target :"
  sup_gen_program "$name" "$cmd" "$wd" "$usr" | sed 's/^/   | /'
  confirm "确认写入?" || { warn "已取消"; return 1; }
  mkdir -p "$(dirname "$target")" 2>/dev/null
  if [ -f "$target" ]; then
    cp "$target" "$target.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null
  fi
  { [ -s "$target" ] && printf '\n'; sup_gen_program "$name" "$cmd" "$wd" "$usr"; } >> "$target" \
    || { err "写入失败"; return 1; }
  ok "已写入: $target"
  say " 注: 若 reread 后看不到该进程，请确认主配置 [include] 了此文件所在目录"
  confirm "立即 reread + update 生效?" && { sup reread; sup update; }
  return 0
}

# ---------- 通用: 选择服务 ----------
pick_service() {
  case "$1" in
    supervisord)
      say " 当前进程列表:"
      sup status 2>&1 | sed 's/^/   /' | head -n 30
      ask " 输入要${2}的进程名，如 myapp 或 group:app (回车取消): " ;;
    systemd)
      say " 服务列表(部分):"
      systemctl list-units --type=service --all --no-pager --no-legend 2>/dev/null \
        | awk '{printf "   %-45s %s\n", $1, $4}' | head -n 30
      ask " 输入服务名，如 nginx 或 nginx.service (回车取消): " ;;
    openrc)
      say " 可用服务(部分, /etc/init.d):"
      ls -1 /etc/init.d 2>/dev/null | grep -E '^[A-Za-z0-9._-]+$' | sed 's/^/   /' | head -n 30
      ask " 输入要${2}的服务名 (回车取消): " ;;
    s6)
      need_s6_dir || return 1
      say " 服务列表:"
      s6_list 2>/dev/null | sed 's/^/   /' | head -n 30
      ask " 输入要${2}的服务名 (回车取消): " ;;
  esac
  if [ -z "$REPLY" ]; then
    warn "已取消"
    return 1
  fi
  SVC="$REPLY"
  return 0
}

# ---------- s6 操作 ----------
need_s6_dir() {
  if [ -z "$S6_DIR" ]; then
    warn "未设置 s6 服务目录，请先在 s6 菜单用选项 8/9 设置"
    return 1
  fi
  return 0
}

s6_list() {
  if [ "$S6_MODE" = "rc" ] && command -v s6-rc-db >/dev/null 2>&1; then
    s6-rc-db list all 2>/dev/null
  else
    ls -1 "$S6_DIR" 2>/dev/null
  fi
}

s6_status_all() {
  need_s6_dir || return 1
  if [ "$S6_MODE" = "rc" ]; then
    found=0
    for s in $(s6_list); do
      if [ -d "$S6_DIR/$s" ]; then
        s6-svstat "$S6_DIR/$s" 2>/dev/null
        found=1
      fi
    done
    [ "$found" = "0" ] && warn "没有可显示的服务(服务目录为空或 s6 未初始化)"
  else
    for d in "$S6_DIR"/*/; do
      [ -e "$d" ] || continue
      s6-svstat "$d" 2>/dev/null
    done
  fi
  return 0
}

s6_set_dir() {
  ask "输入 s6 服务目录(如 /run/s6/services 或 /run/s6-rc/servicedirs，回车取消): "
  [ -z "$REPLY" ] && { warn "已取消"; return 1; }
  if [ ! -d "$REPLY" ]; then
    err "目录不存在: $REPLY"; return 1
  fi
  S6_DIR="$REPLY"
  case "$REPLY" in
    */servicedirs) S6_MODE="rc" ;;
    *)             S6_MODE="scandir" ;;
  esac
  ok "已设置: 模式=$S6_MODE 目录=$S6_DIR"
  return 0
}

s6_up() {
  if [ "$S6_MODE" = "rc" ]; then
    as_root s6-rc -u change "$SVC"
  else
    as_root s6-svc -u "$S6_DIR/$SVC"
  fi
  sleep 1
  s6-svstat "$S6_DIR/$SVC" 2>/dev/null
}

s6_down() {
  if [ "$S6_MODE" = "rc" ]; then
    as_root s6-rc -d change "$SVC"
  else
    as_root s6-svc -d "$S6_DIR/$SVC"
  fi
  sleep 1
  s6-svstat "$S6_DIR/$SVC" 2>/dev/null
}

s6_restart() {
  if [ "$S6_MODE" = "rc" ]; then
    as_root s6-rc -d change "$SVC"
    sleep 1
    as_root s6-rc -u change "$SVC"
  else
    as_root s6-svc -r "$S6_DIR/$SVC"
  fi
  sleep 1
  s6-svstat "$S6_DIR/$SVC" 2>/dev/null
}

s6_view_log() {
  p="$S6_DIR/$SVC"
  logf=""
  for f in "$p/log/current" "$p/log/main/current" "$p/current"; do
    if [ -f "$f" ]; then logf="$f"; break; fi
  done
  if [ -n "$logf" ]; then
    say "日志文件: $logf"
    tail -n 40 "$logf"
  else
    warn "未找到 $p 下的日志文件(log/current)"
    say "该服务目录内容:"
    ls -la "$p" 2>/dev/null | head -n 20
  fi
}

# s6-overlay 的自启 bundle 目录
s6_overlay_contents_dir() {
  d="/etc/s6-overlay/s6-rc.d/user/contents.d"
  [ -d "$d" ] && { printf '%s' "$d"; return 0; }
  return 1
}

# 查看自启成员: s6-rc 看 bundle; overlay 看 contents.d; 扫描目录看 down 文件
s6_show_autostart() {
  need_s6_dir || return 1
  if [ "$S6_MODE" = "rc" ] && command -v s6-rc-db >/dev/null 2>&1; then
    say " 自启 bundle「${S6_BUNDLE:-default}」成员:"
    members=$(s6-rc-db list "${S6_BUNDLE:-default}" 2>/dev/null)
    if [ -n "$members" ]; then
      printf '%s\n' "$members" | sed 's/^/   /'
    else
      warn "读取为空(bundle 名可能不同，可用 s6-rc-db bundles 查看)"
    fi
    say " (不在列表中的服务不会开机自启; 修改需编辑源定义并重新编译)"
  elif cd_dir="$(s6_overlay_contents_dir)" && [ -n "$cd_dir" ]; then
    say " s6-overlay 自启成员 ($cd_dir, 含 oneshot):"
    ls -1 "$cd_dir" 2>/dev/null | sed 's/^/   /'
    say " (不在列表中的服务不会开机自启)"
  else
    say " 扫描目录模式: 含 down 文件的服务不自启，其余自启:"
    for d2 in "$S6_DIR"/*/; do
      [ -d "$d2" ] || continue
      if [ -f "${d2}down" ]; then
        say "   ✗ 不自启: $(basename "$d2")"
      else
        say "   ✓ 自启:   $(basename "$d2")"
      fi
    done
  fi
  return 0
}

# 设置开机自启: overlay 改 contents.d; 扫描目录改 down 文件; s6-rc 给出操作指引
s6_toggle_autostart() {
  need_s6_dir || return 1
  if [ "$S6_MODE" = "rc" ]; then
    say " s6-rc 模式的自启由 bundle 决定，涉及重新编译，脚本不自动修改，请按以下步骤:"
    say "   1) 编辑 bundle 源目录(通常 /etc/s6-rc/source/${S6_BUNDLE:-default}/): 建/删同名空文件"
    say "   2) 重新编译: s6-rc-compile /etc/s6-rc/compiled.new /etc/s6-rc/source"
    say "   3) 切换运行库: s6-rc-update /etc/s6-rc/compiled.new"
    return 0
  fi
  cd_dir="$(s6_overlay_contents_dir)"
  if [ -n "$cd_dir" ]; then
    pick_service s6 "设置自启" || return 1
    if [ -e "$cd_dir/$SVC" ]; then
      confirm "取消 $SVC 开机自启? (删除 $cd_dir/$SVC)" \
        && as_root rm -f "$cd_dir/$SVC" && ok "已取消自启，重启容器后生效"
    else
      as_root touch "$cd_dir/$SVC" && ok "已设为自启，重启容器后生效"
    fi
    return 0
  fi
  pick_service s6 "设置自启" || return 1
  if [ -f "$S6_DIR/$SVC/down" ]; then
    confirm "删除 down 文件恢复自启? ($SVC)" \
      && as_root rm -f "$S6_DIR/$SVC/down" && ok "已恢复自启"
  else
    confirm "创建 down 文件取消自启? ($SVC, 不影响当前运行)" \
      && as_root touch "$S6_DIR/$SVC/down" && ok "已取消自启"
  fi
  say " 注: 若扫描目录由镜像在每次启动时重建，需在镜像/源头修改才能持久。"
}

# ---------- OpenRC: 系统日志 ----------
find_syslog() {
  for f in /var/log/messages /var/log/syslog /var/log/daemon.log; do
    if [ -f "$f" ]; then printf '%s' "$f"; return 0; fi
  done
  return 1
}

# ---------- 界面 ----------
banner() {
  cls
  say "======================================================"
  say "  guan v$GUAN_VERSION · 通用服务管理菜单"
  say "======================================================"
  printf '  可用:  systemd '; mark "$HAS_SYSTEMD"
  printf '    OpenRC '; mark "$HAS_OPENRC"
  printf '    s6 '; mark "$HAS_S6"
  printf '    supervisord '; mark "$HAS_SUPERV"
  printf '\n'
  say "  当前目标: ${C_G}${TARGET:-<未选定>}${C_0}"
  say "------------------------------------------------------"
}

menu_supervisord() {
  if ! command -v supervisorctl >/dev/null 2>&1 \
     && ! command -v supervisord >/dev/null 2>&1; then
    err "本机未安装 supervisor (supervisorctl/supervisord)"; pause; return 0
  fi
  maybe_root_warn
  while :; do
    banner
    say " [supervisord 管理]   配置: ${C_C}${SUP_CFG:-未找到}${C_0}"
    say "  1) 查看全部进程状态      2) 启动进程           3) 停止进程"
    say "  4) 重启进程              5) 单个进程状态"
    say "  6) 日志-stdout(尾部)     7) 日志-stderr(尾部)  8) 实时跟随日志"
    say "  9) reread(重读配置)     10) update(应用配置变更)"
    say " 11) 重启全部进程         12) reload(重启守护进程)"
    say " 13) 关闭 supervisord     14) 启动 supervisord"
    say " 15) 指定配置文件路径     16) 查看自启配置(autostart)"
    say " 17) 设置进程自启开关     18) 新建进程(裸命令)"
    say "  0) 返回"
    say "------------------------------------------------------"
    ask " 请选择: "
    case "$REPLY" in
      1) sup status; pause ;;
      2) pick_service supervisord "启动" && sup start "$SVC"; pause ;;
      3) pick_service supervisord "停止" && sup stop "$SVC"; pause ;;
      4) pick_service supervisord "重启" && sup restart "$SVC"; pause ;;
      5) pick_service supervisord "查看状态" && sup status "$SVC"; pause ;;
      6) pick_service supervisord "查看日志" && sup tail "$SVC"; pause ;;
      7) pick_service supervisord "查看错误日志" && sup tail "$SVC" stderr; pause ;;
      8) pick_service supervisord "实时跟随日志" && { warn "按 Ctrl+C 返回菜单"; sup tail -f "$SVC"; } ;;
      9) sup reread; pause ;;
      10) sup update; pause ;;
      11) confirm "重启全部进程?" && sup restart all; pause ;;
      12) confirm "reload 将重启 supervisord 守护进程，继续?" && sup reload; pause ;;
      13) confirm "确认关闭 supervisord? 其管理的所有进程都会停止!" && sup shutdown; pause ;;
      14) sup_start_self; pause ;;
      15) ask "输入 supervisord 配置文件路径(回车取消): "
          if [ -n "$REPLY" ]; then
            if [ -f "$REPLY" ]; then SUP_CFG="$REPLY"; ok "已设置 SUP_CFG=$SUP_CFG"
            else err "文件不存在: $REPLY"; fi
          fi
          pause ;;
      16) sup_show_autostart; pause ;;
      17) sup_set_autostart; pause ;;
      18) sup_create_program; pause ;;
      0|q|Q) return 0 ;;
      *) warn "无效选项: $REPLY"; sleep 1 ;;
    esac
  done
}

menu_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    err "本机未安装 systemctl，无法使用该模块"; pause; return 0
  fi
  if [ ! -d /run/systemd/system ]; then
    warn "/run/systemd/system 不存在：systemd 可能不是当前 PID 1 (容器内常见)"
  fi
  maybe_root_warn
  while :; do
    banner
    say " [systemd 管理]"
    say "  1) 列出全部服务          2) 列出失败服务"
    say "  3) 启动服务              4) 停止服务            5) 重启服务"
    say "  6) 查看服务状态          7) 服务日志(近50行)    8) 实时跟随日志"
    say "  9) 设为开机自启         10) 取消开机自启       11) 查看自启项"
    say " 12) daemon-reload        13) 新建服务(裸命令)"
    say "  0) 返回"
    say "------------------------------------------------------"
    ask " 请选择: "
    case "$REPLY" in
      1) systemctl list-units --type=service --all --no-pager | head -n 80; pause ;;
      2) systemctl --failed --no-pager; pause ;;
      3) pick_service systemd "启动"   && as_root systemctl start "$SVC"; pause ;;
      4) pick_service systemd "停止"   && as_root systemctl stop "$SVC"; pause ;;
      5) pick_service systemd "重启"   && as_root systemctl restart "$SVC"; pause ;;
      6) pick_service systemd "查看状态" && { systemctl status "$SVC" --no-pager; printf '\n开机自启: '; systemctl is-enabled "$SVC" 2>/dev/null; say ""; }; pause ;;
      7) pick_service systemd "查看日志" && journalctl -u "$SVC" -n 50 --no-pager; pause ;;
      8) pick_service systemd "实时跟随日志" && { warn "按 Ctrl+C 返回菜单"; journalctl -u "$SVC" -f; } ;;
      9) pick_service systemd "设为自启" && as_root systemctl enable "$SVC"; pause ;;
      10) pick_service systemd "取消自启" && as_root systemctl disable "$SVC"; pause ;;
      11) systemctl list-unit-files --type=service --no-pager | head -n 60; pause ;;
      12) as_root systemctl daemon-reload && ok "已执行 daemon-reload"; pause ;;
      13) systemd_create_service; pause ;;
      0|q|Q) return 0 ;;
      *) warn "无效选项: $REPLY"; sleep 1 ;;
    esac
  done
}

# ---------- systemd: 新建服务向导 ----------
systemd_gen_unit() { # $1=名称 $2=命令(已解析) $3=工作目录 $4=用户
  wd="$3"; [ -z "$wd" ] && wd="/"
  usr="$4"; [ -z "$usr" ] && usr="root"
  cat <<EOF
[Unit]
Description=guan service: $1
After=network.target

[Service]
Type=simple
WorkingDirectory=$wd
ExecStart=$2
Restart=on-failure
RestartSec=3
User=$usr

[Install]
WantedBy=multi-user.target
EOF
}

systemd_create_service() {
  if ! command -v systemctl >/dev/null 2>&1; then
    err "本机未安装 systemctl"; pause; return 1
  fi
  unit_dir="${GUAN_SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
  ask " 服务名(仅字母数字._-，回车取消): "
  [ -z "$REPLY" ] && { warn "已取消"; return 1; }
  valid_name "$REPLY" || { err "服务名含非法字符: $REPLY"; return 1; }
  name="$REPLY"
  unit="$unit_dir/$name.service"
  if [ -e "$unit" ]; then
    confirm "$unit 已存在，覆盖? (自动备份)" || { warn "已取消"; return 1; }
    cp "$unit" "$unit.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null
  fi
  ask " 启动命令(如 python3 /opt/app/main.py，回车取消): "
  [ -z "$REPLY" ] && { warn "已取消"; return 1; }
  cmd="$(resolve_cmd "$REPLY")"
  ask " 工作目录(回车=使用 /): "
  wd="$REPLY"
  ask " 运行用户(回车=root): "
  usr="$REPLY"
  say ""
  say " 将写入 $unit :"
  systemd_gen_unit "$name" "$cmd" "$wd" "$usr" | sed 's/^/   | /'
  confirm "确认写入?" || { warn "已取消"; return 1; }
  mkdir -p "$unit_dir" 2>/dev/null
  systemd_gen_unit "$name" "$cmd" "$wd" "$usr" > "$unit.tmp.$$" \
    && mv "$unit.tmp.$$" "$unit" \
    || { err "写入失败"; rm -f "$unit.tmp.$$"; return 1; }
  ok "已写入: $unit"
  if as_root systemctl daemon-reload; then
    ok "已执行 daemon-reload"
  else
    warn "daemon-reload 失败(可能 systemd 未运行，上线后可用 guan 重试)"
  fi
  confirm "设为开机自启(enable)?" && as_root systemctl enable "$name.service"
  if confirm "立即启动(start)?"; then
    as_root systemctl start "$name.service" \
      && { say ""; as_root systemctl status "$name.service" --no-pager | head -n 8; }
  fi
  return 0
}

menu_openrc() {
  if ! command -v rc-service >/dev/null 2>&1; then
    err "本机未安装 OpenRC (rc-service)"; pause; return 0
  fi
  maybe_root_warn
  while :; do
    banner
    say " [OpenRC 管理]"
    say "  1) 查看全部服务状态      2) 启动服务        3) 停止服务"
    say "  4) 重启服务              5) 查看服务状态"
    say "  6) 加入开机自启(default) 7) 移出自启        8) 查看自启项"
    say "  9) 系统日志(尾部)       10) 实时跟随系统日志"
    say " 11) 新建服务(裸命令)     0) 返回"
    say "------------------------------------------------------"
    ask " 请选择: "
    case "$REPLY" in
      1) rc-status --all 2>&1 | head -n 100; pause ;;
      2) pick_service openrc "启动" && as_root rc-service "$SVC" start; pause ;;
      3) pick_service openrc "停止" && as_root rc-service "$SVC" stop; pause ;;
      4) pick_service openrc "重启" && as_root rc-service "$SVC" restart; pause ;;
      5) pick_service openrc "查看状态" && { rc-service "$SVC" status; printf '开机自启(default): '; rc-update show default 2>/dev/null | awk -v s="$SVC" '$1==s{f=1} END{exit !f}' && say "已加入" || say "未加入"; }; pause ;;
      6) pick_service openrc "加入自启" && as_root rc-update add "$SVC" default; pause ;;
      7) pick_service openrc "移出自启" && as_root rc-update del "$SVC" default; pause ;;
      8) rc-update show; pause ;;
      9) if f=$(find_syslog); then say "日志: $f"; tail -n 40 "$f"; else warn "未找到系统日志(/var/log/messages 等)"; fi; pause ;;
      10) if f=$(find_syslog); then warn "按 Ctrl+C 返回菜单"; tail -f "$f"; else warn "未找到系统日志(/var/log/messages 等)"; pause; fi ;;
      11) openrc_create_service; pause ;;
      0|q|Q) return 0 ;;
      *) warn "无效选项: $REPLY"; sleep 1 ;;
    esac
  done
}

# ---------- OpenRC: 新建服务向导 ----------
openrc_gen_script() { # $1=名称 $2=命令(已解析) $3=工作目录 $4=优先用supervise-daemon
  wd="$3"
  # OpenRC 要求 command= 仅为二进制路径，参数必须放 command_args=
  first=${2%% *}
  rest=""
  case "$2" in
    *" "*) rest="${2#* }" ;;
  esac
  if [ "$4" = "1" ] && command -v supervise-daemon >/dev/null 2>&1; then
    sup_line='supervisor=supervise-daemon'
  else
    sup_line='command_background="yes"'
  fi
  printf '#!/sbin/openrc-run\n\n'
  printf 'description="guan service: %s"\n' "$1"
  printf 'command="%s"\n' "$first"
  if [ -n "$rest" ]; then printf 'command_args="%s"\n' "$rest"; fi
  [ -n "$wd" ] && printf 'directory="%s"\n' "$wd"
  printf '%s\n' "$sup_line"
  printf 'pidfile="/run/${RC_SVCNAME}.pid"\n'
  printf '\ndepend() {\n\tafter net\n}\n'
  return 0
}

openrc_create_service() {
  if ! command -v rc-service >/dev/null 2>&1; then
    err "本机未安装 OpenRC"; pause; return 1
  fi
  init_dir="${GUAN_OPENRC_INITDIR:-/etc/init.d}"
  ask " 服务名(仅字母数字._-，回车取消): "
  [ -z "$REPLY" ] && { warn "已取消"; return 1; }
  valid_name "$REPLY" || { err "服务名含非法字符: $REPLY"; return 1; }
  name="$REPLY"
  script="$init_dir/$name"
  if [ -e "$script" ]; then
    confirm "$script 已存在，覆盖? (自动备份)" || { warn "已取消"; return 1; }
    cp "$script" "$script.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null
  fi
  ask " 启动命令(如 python3 /opt/app/main.py，回车取消): "
  [ -z "$REPLY" ] && { warn "已取消"; return 1; }
  cmd="$(resolve_cmd "$REPLY")"
  ask " 工作目录(回车=不设置): "
  wd="$REPLY"
  say ""
  say " 将写入 $script :"
  openrc_gen_script "$name" "$cmd" "$wd" 1 | sed 's/^/   | /'
  confirm "确认写入?" || { warn "已取消"; return 1; }
  mkdir -p "$init_dir" 2>/dev/null
  openrc_gen_script "$name" "$cmd" "$wd" 1 > "$script.tmp.$$" \
    && chmod 755 "$script.tmp.$$" \
    && mv "$script.tmp.$$" "$script" \
    || { err "写入失败"; rm -f "$script.tmp.$$"; return 1; }
  ok "已写入: $script"
  confirm "设为开机自启(rc-update add $name default)?" && as_root rc-update add "$name" default
  confirm "立即启动?" && as_root rc-service "$name" start
  return 0
}

menu_s6() {
  if ! command -v s6-svstat >/dev/null 2>&1 && ! command -v s6-rc >/dev/null 2>&1; then
    err "本机未安装 s6 工具集 (s6-rc / s6-svstat / s6-svc)"; pause; return 0
  fi
  maybe_root_warn
  while :; do
    banner
    s6_dir_note=""
    if [ -n "$S6_DIR" ] && [ ! -d "$S6_DIR" ]; then
      s6_dir_note=" ${C_R}(目录不存在!)${C_0}"
    fi
    say " [s6 管理]   模式: ${C_C}${S6_MODE:-?}${C_0}   目录: ${C_C}${S6_DIR:-未检测到}${C_0}$s6_dir_note"
    say "  1) 列出服务              2) 全部服务状态"
    say "  3) 启动服务              4) 停止服务        5) 重启服务"
    say "  6) 查看服务状态          7) 查看服务日志"
    say "  8) 手动设置服务目录      9) 重新自动检测"
    say " 10) 查看自启成员         11) 设置开机自启开关"
    say "  0) 返回"
    say "------------------------------------------------------"
    ask " 请选择: "
    case "$REPLY" in
      1) need_s6_dir && s6_list | head -n 60; pause ;;
      2) s6_status_all; pause ;;
      3) need_s6_dir && pick_service s6 "启动" && s6_up; pause ;;
      4) need_s6_dir && pick_service s6 "停止" && s6_down; pause ;;
      5) need_s6_dir && pick_service s6 "重启" && s6_restart; pause ;;
      6) need_s6_dir && pick_service s6 "查看状态" && s6-svstat "$S6_DIR/$SVC"; pause ;;
      7) need_s6_dir && pick_service s6 "查看日志" && s6_view_log; pause ;;
      8) s6_set_dir; pause ;;
      9) detect_s6_env; ok "模式=$S6_MODE 目录=${S6_DIR:-无}"; pause ;;
      10) s6_show_autostart; pause ;;
      11) s6_toggle_autostart; pause ;;
      0|q|Q) return 0 ;;
      *) warn "无效选项: $REPLY"; sleep 1 ;;
    esac
  done
}

main_menu() {
  while :; do
    banner
    say "  1) supervisord 管理      2) systemd 管理"
    say "  3) OpenRC 管理           4) s6 管理"
    say ""
    say "  5) 重新检测环境          6) 安装 guan 命令"
    say "  7) 卸载 guan 命令        0) 退出"
    say "------------------------------------------------------"
    say "  提示: 实时日志界面按 Ctrl+C 返回菜单"
    ask "  请选择: "
    case "$REPLY" in
      1) menu_supervisord ;;
      2) menu_systemd ;;
      3) menu_openrc ;;
      4) menu_s6 ;;
      5) TARGET=""; detect_all; ok "已重新检测"; sleep 1 ;;
      6) do_install; pause ;;
      7) do_uninstall; pause ;;
      0|q|Q|exit|quit) cls; say "再见。"; exit 0 ;;
      *) warn "无效选项: $REPLY"; sleep 1 ;;
    esac
  done
}

# ---------- 安装 / 卸载 ----------
do_install() {
  dir="${GUAN_INSTALL_DIR:-/usr/local/bin}"
  if ! mkdir -p "$dir" 2>/dev/null || [ ! -w "$dir" ]; then
    if [ "$(id -u)" = "0" ]; then
      err "无法写入 $dir (root 也失败)，请检查文件系统"; return 1
    fi
    dir="$HOME/.local/bin"
    mkdir -p "$dir" 2>/dev/null
    if [ ! -w "$dir" ]; then
      err "无法写入 $dir，安装失败"; return 1
    fi
    warn "无权限写 /usr/local/bin，改用: $dir"
  fi
  dest="$dir/guan"
  if [ -e "$dest" ] && cmp -s "$SELF" "$dest" 2>/dev/null; then
    ok "已是最新版本: $dest (终端输入 guan 即可进入)"
    return 0
  fi
  if cp "$SELF" "$dest" 2>/dev/null && chmod 755 "$dest" 2>/dev/null; then
    ok "安装成功: $dest"
    say ""
    say "  现在可以在任意目录输入 ${C_B}guan${C_0} 进入服务管理菜单"
    case ":$PATH:" in
      *":$dir:"*) ;;
      *) warn "$dir 不在 PATH 中: 请执行 export PATH=\"$dir:\$PATH\" (可写入 ~/.shrc、~/.bashrc 或 /etc/profile)" ;;
    esac
  else
    err "复制失败。可手动执行: cp \"$SELF\" \"$dest\" && chmod +x \"$dest\""
    return 1
  fi
}

do_uninstall() {
  removed=0
  for d in "${GUAN_INSTALL_DIR:-/usr/local/bin}" "$HOME/.local/bin"; do
    f="$d/guan"
    if [ -e "$f" ]; then
      rm -f "$f" && { ok "已删除 $f"; removed=1; }
    fi
  done
  [ "$removed" = "0" ] && warn "未发现已安装的 guan"
  return 0
}

usage() {
  cat <<'EOF'
guan — 服务管理交互菜单 (supervisord / systemd / OpenRC / s6)

用法:
  guan [子命令]
  sh guan.sh [子命令]

子命令:
  (无)            交互菜单，自动检测可用的 init 系统
  supervisord     直接进入 supervisord 管理
  systemd         直接进入 systemd 管理
  openrc          直接进入 OpenRC 管理
  s6              直接进入 s6 管理
  install         注册 guan 命令(默认 /usr/local/bin，无权限则 ~/.local/bin)
  uninstall       卸载 guan 命令
  help            显示本帮助

环境变量:
  GUAN_INSTALL_DIR   自定义安装目录
  SUPERVISOR_CONF    指定 supervisord 配置文件路径
  S6_SERVICEDIR      指定 s6 服务目录(优先于自动检测)
  S6_BUNDLE          s6-rc 自启 bundle 名(默认 default)
  GUAN_SYSTEMD_UNIT_DIR  自定义 systemd unit 目录(默认 /etc/systemd/system)
  GUAN_OPENRC_INITDIR    自定义 OpenRC init 脚本目录(默认 /etc/init.d)

说明:
  - 脚本可放在任意目录运行；在目标机器上执行一次
      sh /path/to/guan.sh install
    之后任意目录输入 guan 即可进入菜单。
  - 实时日志(跟随)界面按 Ctrl+C 返回菜单；菜单处按 Ctrl+C 退出。
EOF
}

# ---------- 入口 ----------
SELF="$0"
case "$SELF" in
  */*) ;;
  *) SELF="./$SELF" ;;
esac
_res="$(readlink -f "$SELF" 2>/dev/null)"
[ -n "$_res" ] && SELF="$_res"

main() {
  arg="${1:-}"
  case "$arg" in
    install)   do_install; exit $? ;;
    uninstall) do_uninstall; exit $? ;;
    help|-h|--help) usage; exit 0 ;;
    version|--version|-V) say "guan v$GUAN_VERSION"; exit 0 ;;
    supervisord|supervisor) TARGET="supervisord" ;;
    systemd|systemctl)      TARGET="systemd" ;;
    openrc|rc)              TARGET="openrc" ;;
    s6)                     TARGET="s6" ;;
    "") ;;
    *) usage; err "未知参数: $arg"; exit 1 ;;
  esac
  detect_all
  maybe_root_warn
  if [ -n "$arg" ]; then
    case "$TARGET" in
      supervisord) menu_supervisord ;;
      systemd)     menu_systemd ;;
      openrc)      menu_openrc ;;
      s6)          menu_s6 ;;
    esac
    exit 0
  fi
  # 只检测到一个可用后端时，直接进入对应子菜单
  count=$((HAS_SYSTEMD + HAS_OPENRC + HAS_S6 + HAS_SUPERV))
  if [ "$count" = "1" ]; then
    case "$TARGET" in
      supervisord) menu_supervisord ;;
      systemd)     menu_systemd ;;
      openrc)      menu_openrc ;;
      s6)          menu_s6 ;;
    esac
  fi
  main_menu
}

[ -z "${GUAN_NOEXEC:-}" ] && main "$@"
