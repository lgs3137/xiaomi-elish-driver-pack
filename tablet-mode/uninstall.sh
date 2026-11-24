#!/bin/bash
# tablet-mode/uninstall.sh — 卸载平板模式组件（helper 服务 + GNOME 扩展 + dconf 启用项）
#
# 用法（root）：sudo ./tablet-mode/uninstall.sh [--dry-run] [--user <用户名>]
#
# 注意：GNOME 46 不能热卸载已加载的扩展；卸载后当前会话里的开关会在下次登录后消失。
set -euo pipefail
TAG=tablet-mode
. "$(dirname "$0")/../install/lib/common.sh"

DRY_RUN=${DRY_RUN:-0}
ASSUME_YES=${ASSUME_YES:-0}
TM_USER=${TM_USER:-}
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --yes) ASSUME_YES=1; shift ;;
        --user) TM_USER=${2:-}; shift 2 ;;
        -h|--help) awk 'NR>1 { if ($0 ~ /^#/) { sub(/^# ?/, ""); print } else exit }' "$0"; exit 0 ;;
        *) die "未知参数: $1（-h 查看用法）" ;;
    esac
done
export DRY_RUN ASSUME_YES
need_root

UUID=tablet-mode@elish
HELPER=/usr/local/bin/elish-tablet-mode-switch
UNIT=/etc/systemd/system/elish-tablet-mode.service
KDETECT=/usr/local/sbin/elish-keyboard-detect
KUNIT=/etc/systemd/system/elish-keyboard-detect.service
U=${TM_USER:-${SUDO_USER:-}}
if [ -z "$U" ] || [ "$U" = root ]; then
    if [ "$DRY_RUN" = 1 ]; then
        U=$(id -un)
    else
        die "无法确定目标桌面用户：请用 sudo 运行（自动取 SUDO_USER），或 sudo TM_USER=<用户名> ./tablet-mode/uninstall.sh"
    fi
fi
id "$U" >/dev/null 2>&1 || die "用户不存在: $U"
UIDN=$(id -u "$U")
UHOME=$(getent passwd "$U" | cut -d: -f6)
DEST="$UHOME/.local/share/gnome-shell/extensions/$UUID"
RUNDIR="/run/user/$UIDN"

as_user() {
    runuser -u "$U" -- env XDG_RUNTIME_DIR="$RUNDIR" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNDIR/bus" "$@"
}

step "1) 停止并移除 systemd 服务"
if [ -e "$KUNIT" ]; then
    run systemctl disable --now elish-keyboard-detect.service || true
    run rm -f "$KUNIT"
    run systemctl daemon-reload
else
    log "未安装 elish-keyboard-detect.service"
fi
if [ -e "$UNIT" ] || systemctl list-unit-files 2>/dev/null | grep -q '^elish-tablet-mode.service'; then
    run systemctl disable --now elish-tablet-mode.service || true
    run rm -f "$UNIT"
    run systemctl daemon-reload
else
    log "未安装 elish-tablet-mode.service"
fi

step "2) 移除 helper 与键盘检测脚本"
run rm -f "$HELPER" "$KDETECT"
run rm -f /run/elish-keyboard-present

step "3) 移除 GNOME 扩展"
if [ -e "$DEST" ]; then
    run rm -rf "$DEST"
else
    log "未安装扩展: $DEST"
fi

step "4) 从用户 dconf 中移除启用项"
if [ "$DRY_RUN" = 1 ]; then
    log "DRY: 从 $U 的 enabled-extensions 中移除 $UUID"
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
cur = [x for x in cur if x != uuid]
print(repr(cur))
PY
)
    as_user gsettings set org.gnome.shell enabled-extensions "$NEW" 2>/dev/null || \
        warn "dconf 写入失败；登录后执行：gnome-extensions disable $UUID"
else
    warn "用户 $U 当前没有图形会话，跳过 dconf（登录后执行：gnome-extensions disable $UUID）"
fi

step "完成"
cat <<EOF
平板模式组件已卸载。
- helper/服务已移除；虚拟 SW_TABLET_MODE 消失（mutter 回到只认保护套霍尔）。
- 扩展已移除（当前会话里的开关在下次登录后消失）。
- 保留 /etc/elish-orientation.conf；tablet_mode 配置不再被应用（auto 行为由内核霍尔原生提供）。
EOF
