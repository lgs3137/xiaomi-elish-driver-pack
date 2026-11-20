#!/bin/bash
# flash-led/uninstall.sh — 回滚“开机闪光灯误闪”修复
#
# 用法（root）： sudo ./flash-led/uninstall.sh [--dry-run]
#
# 回滚后 armbian-led-state.service 恢复执行 Armbian 原版 restore 脚本，
# 下次开机又会闪一下（这是原版行为）。
set -euo pipefail
TAG=flash-led
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

WRAPPER=/usr/local/lib/elish/elish-led-state-restore-flash-safe.sh
DROPIN_DIR=/etc/systemd/system/armbian-led-state.service.d
DROPIN=$DROPIN_DIR/50-elish-skip-flash.conf

step "1) 移除 systemd drop-in"
if [ -e "$DROPIN" ]; then
    run rm -f "$DROPIN"
    if [ "$DRY_RUN" = 0 ] && [ -d "$DROPIN_DIR" ] && [ -z "$(ls -A "$DROPIN_DIR" 2>/dev/null)" ]; then
        rmdir "$DROPIN_DIR" 2>/dev/null || true
    fi
else
    log "drop-in 不存在，跳过"
fi

step "2) 移除 wrapper"
run rm -f "$WRAPPER"
if [ "$DRY_RUN" = 0 ] && [ -d /usr/local/lib/elish ] && [ -z "$(ls -A /usr/local/lib/elish 2>/dev/null)" ]; then
    rmdir /usr/local/lib/elish 2>/dev/null || true
fi

step "3) 重载 systemd"
run systemctl daemon-reload

step "完成"
cat <<EOF
修复已回滚：armbian-led-state.service 恢复执行 Armbian 原版 restore 脚本。
- 原版行为会在开机 Plymouth 阶段使后摄闪光灯闪一下（已知 Armbian 上游行为）。
- 重新安装：sudo ./flash-led/install.sh
EOF
