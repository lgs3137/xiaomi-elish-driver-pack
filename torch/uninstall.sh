#!/bin/bash
# torch/uninstall.sh — 卸载可选的 GNOME 手电筒组件（扩展 + torch CLI + dconf 启用项）
#
# 用法（root）：sudo ./torch/uninstall.sh [--dry-run]
#
# 注意：GNOME 46 不能热卸载已加载的扩展；卸载后当前会话里的图标会在下次登录后消失。
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

UUID=torch@elish
TORCH_BIN=/usr/local/bin/torch
U=${TORCH_USER:-${SUDO_USER:-}}
if [ -z "$U" ] || [ "$U" = root ]; then
    if [ "$DRY_RUN" = 1 ]; then
        U=$(id -un)
    else
        die "无法确定目标桌面用户：请用 sudo 运行（自动取 SUDO_USER），或 sudo TORCH_USER=<用户名> ./torch/uninstall.sh"
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

step "1) 移除 GNOME 扩展"
if [ -e "$DEST" ]; then
    run rm -rf "$DEST"
else
    log "扩展目录不存在，跳过: $DEST"
fi

step "2) 移除 torch 命令行"
run rm -f "$TORCH_BIN"

step "3) 从用户 dconf 的启用/禁用列表中移除 $UUID"
if [ "$DRY_RUN" = 1 ]; then
    log "DRY: 从 $U 的 enabled/disabled-extensions 中移除 $UUID"
elif [ -S "$RUNDIR/bus" ]; then
    for KEY in enabled-extensions disabled-extensions; do
        CUR=$(as_user gsettings get "org.gnome.shell $KEY" 2>/dev/null || true)
        [ -n "$CUR" ] || continue
        NEW=$(python3 - "$KEY" "$CUR" "$UUID" <<'PY'
import ast
import sys

key, raw, uuid = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    cur = ast.literal_eval(raw)
except Exception:
    cur = []
print(repr([x for x in cur if x != uuid]))
PY
)
        as_user gsettings set "org.gnome.shell $KEY" "$NEW" 2>/dev/null \
            && log "已更新 org.gnome.shell $KEY" \
            || warn "更新 org.gnome.shell $KEY 失败"
    done
else
    warn "用户 $U 当前没有图形会话：登录后执行 gnome-extensions disable $UUID（如还显示）"
fi

step "完成"
cat <<EOF
GNOME 手电筒组件已卸载。
- 当前会话中的「手电筒」开关会在下次登录/重启后消失（GNOME 46 不支持热卸载扩展）。
- 若只想保留命令行而不要 GNOME 扩展：可只删除 $DEST 并保留 $TORCH_BIN。
EOF
