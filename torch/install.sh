#!/bin/bash
# torch/install.sh — 可选组件：GNOME 46 控制中心「手电筒」开关 + torch 命令行
#
# 默认**不安装**（合并包与 turnkey 都默认跳过）；需要时显式启用：
#   sudo ./install.sh --with-torch ...          （turnkey）
#   sudo ./torch/install.sh                    （单独安装）
#
# 安装内容：
#   ~<user>/.local/share/gnome-shell/extensions/torch@elish/   （GNOME 46 Quick Settings 扩展）
#   /usr/local/bin/torch                                       （命令行；on/off/toggle/set/status）
#   在 <user> 的 dconf 中启用扩展（下次登录生效；GNOME 46 不能热加载新扩展）
#
# 原理：读 sysfs 显示状态；写亮度走 systemd-logind
#   Session.SetBrightness("leds", "white:flash", 0..255)
# 普通用户可用，不需要 root、不需要改 udev。
#
# 用法（root）：sudo ./torch/install.sh [--dry-run] [--yes] [--user <用户名>]
# 卸载：sudo ./torch/uninstall.sh
set -euo pipefail
TAG=torch
. "$(dirname "$0")/../install/lib/common.sh"

DRY_RUN=${DRY_RUN:-0}
ASSUME_YES=${ASSUME_YES:-0}
TORCH_USER=${TORCH_USER:-}
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --yes) ASSUME_YES=1; shift ;;
        --user) TORCH_USER=${2:-}; shift 2 ;;
        -h|--help) awk 'NR>1 { if ($0 ~ /^#/) { sub(/^# ?/, ""); print } else exit }' "$0"; exit 0 ;;
        *) die "未知参数: $1（-h 查看用法）" ;;
    esac
done
export DRY_RUN ASSUME_YES
need_root

C="$PKG_ROOT/torch"
UUID=torch@elish
TORCH_BIN=/usr/local/bin/torch
U=${TORCH_USER:-${SUDO_USER:-}}
if [ -z "$U" ] || [ "$U" = root ]; then
    if [ "$DRY_RUN" = 1 ]; then
        U=$(id -un)
    else
        die "无法确定目标桌面用户：请用 sudo 运行（自动取 SUDO_USER），或 sudo TORCH_USER=<用户名> ./torch/install.sh"
    fi
fi
id "$U" >/dev/null 2>&1 || die "用户不存在: $U"
UIDN=$(id -u "$U")
GIDN=$(id -gn "$U")
UHOME=$(getent passwd "$U" | cut -d: -f6)
DEST="$UHOME/.local/share/gnome-shell/extensions/$UUID"
RUNDIR="/run/user/$UIDN"

as_user() {
    runuser -u "$U" -- env XDG_RUNTIME_DIR="$RUNDIR" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNDIR/bus" "$@"
}

step "0) 环境检查"
if have gnome-shell; then
    GNOME_VER=$(gnome-shell --version 2>/dev/null | awk '{print $3}')
    case "$GNOME_VER" in
        46.*|46) log "GNOME Shell $GNOME_VER（扩展声明 shell-version 46）" ;;
        *) warn "GNOME Shell $GNOME_VER：扩展只声明 46，可能不会加载（升级后需自行改 metadata）" ;;
    esac
fi
[ -n "$UHOME" ] && [ -d "$UHOME" ] || die "用户主目录不存在: $UHOME"

step "1) 安装 GNOME 46 Quick Settings 扩展（用户 $U）"
if [ "$DRY_RUN" = 1 ]; then
    printf '    DRY: install -d %s\n' "$(dirname "$DEST")"
    printf '    DRY: cp -r %s %s\n' "$C/torch@elish" "$DEST"
    printf '    DRY: chown -R %s:%s %s\n' "$U" "$GIDN" "$DEST"
else
    install -d -m 0755 -o "$U" -g "$GIDN" "$(dirname "$DEST")"
    rm -rf "$DEST"
    cp -r "$C/torch@elish" "$DEST"
    chown -R "$U:$GIDN" "$DEST"
    find "$DEST" -type f -exec chmod 0644 {} +
    find "$DEST" -type d -exec chmod 0755 {} +
fi

step "2) 安装 torch 命令行"
run install -m 0755 "$C/torch" "$TORCH_BIN"

step "3) 在用户 dconf 中启用扩展（下次登录生效）"
if [ "$DRY_RUN" = 1 ]; then
    log "DRY: 在 $U 的 dconf 中把 $UUID 加入 org.gnome.shell enabled-extensions"
elif [ -S "$RUNDIR/bus" ]; then
    CUR=$(as_user gsettings get org.gnome.shell enabled-extensions 2>/dev/null || echo "@as []")
    NEW=$(python3 - "$CUR" "$UUID" <<'PY'
import ast
import sys

uuid = sys.argv[2]
try:
    cur = ast.literal_eval(sys.argv[1])
except Exception:
    cur = []
if uuid not in cur:
    cur.append(uuid)
print(repr(cur))
PY
)
    if as_user gsettings set org.gnome.shell enabled-extensions "$NEW" 2>/dev/null; then
        log "已在 $U 的 dconf 中启用 $UUID"
    else
        warn "dconf 写入失败；登录 $U 的桌面后执行：gnome-extensions enable $UUID"
    fi
else
    warn "用户 $U 当前没有图形会话（$RUNDIR/bus 不存在）：登录桌面后执行 gnome-extensions enable $UUID"
fi

step "4) 功能自检"
if [ "$DRY_RUN" = 1 ]; then
    log "DRY: 跳过 logind 自检"
elif [ -S "$RUNDIR/bus" ]; then
    if as_user "$TORCH_BIN" off >/dev/null 2>&1 && as_user "$TORCH_BIN" status >/dev/null 2>&1; then
        log "OK  logind 手电筒通道可用（torch off / status 正常）"
    else
        warn "logind 通道自检失败（会话可能不是活动会话；登录后可用 torch on/off 测试）"
    fi
fi

step "完成"
cat <<EOF
GNOME 手电筒（可选组件）已安装。
- 扩展: $DEST（用户 $U）
- 命令: $TORCH_BIN（torch / torch on / off / toggle / set 64 / status）
- GNOME 46 **不支持热加载新扩展**：注销/重新登录后，控制中心（右上角或 Super+S）
  里会出现「手电筒」开关；开启 5 分钟后自动关闭（可在扩展源码里改 AUTO_OFF_SECONDS）。
- 登录后仍看不到：gnome-extensions enable $UUID；
  journalctl --user -b | grep -iE 'torch|extension'
- 卸载：sudo ./torch/uninstall.sh
EOF
