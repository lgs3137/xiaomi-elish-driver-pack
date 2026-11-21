#!/bin/bash
# pps-charger/uninstall.sh — 卸载受控 11V PPS 快充服务
#
# 用法（root）：sudo ./pps-charger/uninstall.sh [--dry-run]
set -euo pipefail
TAG=pps-charger
. "$(dirname "$0")/../install/lib/common.sh"

DRY_RUN=${DRY_RUN:-0}
ASSUME_YES=${ASSUME_YES:-0}
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --yes) ASSUME_YES=1; shift ;;
        -h|--help) awk 'NR>1 { if ($0 ~ /^#/) { sub(/^# ?/, ""); print } else exit }' "$0"; exit 0 ;;
        *) die "未知参数: $1（-h 查看用法）" ;;
    esac
done
export DRY_RUN ASSUME_YES
need_root

BIN=/usr/local/sbin/elish-pps-charger
UNIT=/etc/systemd/system/elish-pps-charger.service

step "1) 停止服务并退回固定 9V"
if [ -x "$BIN" ]; then
    run "$BIN" --revert || true
fi
run systemctl disable --now elish-pps-charger.service 2>/dev/null || true

step "2) 移除脚本与 unit"
run rm -f "$BIN" "$UNIT"
run systemctl daemon-reload
run systemctl reset-failed elish-pps-charger.service 2>/dev/null || true

step "3) 移除控制中心扩展（如安装过）"
UUID=charge-meter@elish
U=$(id -un 2>/dev/null || true)
for home in /home/* /root; do
    DEST="$home/.local/share/gnome-shell/extensions/$UUID"
    [ -d "$DEST" ] && run rm -rf "$DEST" && log "移除 $DEST"
done
if [ -S /run/user/1000/bus ]; then
    CUR=$(env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus gsettings get org.gnome.shell enabled-extensions 2>/dev/null || echo "@as []")
    NEW=$(python3 - "$CUR" "$UUID" <<'PY'
import ast, sys
try: cur = ast.literal_eval(sys.argv[1])
except Exception: cur = []
cur = [x for x in cur if x != sys.argv[2]]
print(repr(cur))
PY
)
    env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus gsettings set org.gnome.shell enabled-extensions "$NEW" 2>/dev/null || true
fi

step "完成"
cat <<EOF
受控 11V PPS 快充服务已卸载；充电器已退回 9V 固定档。
（SMB5 的 6A 快充、bq2597x 并联泵与分段充电曲线不受影响。）
EOF
