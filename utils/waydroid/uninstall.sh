#!/bin/bash
# utils/waydroid/uninstall.sh — 卸载 Waydroid 软键盘联动
#
# 用法（root）：sudo ./utils/waydroid/uninstall.sh [--dry-run]
set -euo pipefail
TAG=utils-waydroid
. "$(dirname "$0")/../../install/lib/common.sh"

DRY_RUN=${DRY_RUN:-0}
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) awk 'NR>1 { if ($0 ~ /^#/) { sub(/^# ?/, ""); print } else exit }' "$0"; exit 0 ;;
        *) die "未知参数: $1（-h 查看用法）" ;;
    esac
done
export DRY_RUN
need_root

WATCH=/usr/local/sbin/elish-waydroid-ime-watch
UNIT=/etc/systemd/system/elish-waydroid-ime.service

step "1) 停止并移除服务"
if [ -e "$UNIT" ]; then
    run systemctl disable --now elish-waydroid-ime.service || true
    run rm -f "$UNIT"
    run systemctl daemon-reload
else
    log "未安装 elish-waydroid-ime.service"
fi

step "2) 移除 watcher"
run rm -f "$WATCH"

step "完成"
echo "Waydroid 软键盘联动已卸载（Android 的 show_ime 设置保持当前值）。"
