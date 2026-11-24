#!/bin/bash
# utils/waydroid/install.sh — Waydroid 软键盘跟随 elish 平板模式
#
# 安装内容：
#   /usr/local/sbin/elish-waydroid-ime-watch      （Python watcher）
#   /etc/systemd/system/elish-waydroid-ime.service
# 行为：SW_TABLET_MODE=1 -> show_ime_with_hard_keyboard=1；=0 -> 0。
#       空闲只读 evdev，状态变化时才调用 waydroid shell。
#
# 用法（root）：sudo ./utils/waydroid/install.sh [--dry-run] [--yes]
# 卸载：sudo ./utils/waydroid/uninstall.sh
set -euo pipefail
TAG=utils-waydroid
. "$(dirname "$0")/../../install/lib/common.sh"

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

C=$(cd "$(dirname "$0")" && pwd)
WATCH=/usr/local/sbin/elish-waydroid-ime-watch
UNIT=/etc/systemd/system/elish-waydroid-ime.service

step "0) 环境检查"
have python3 || die "缺少 python3"
if have waydroid; then
    log "找到 waydroid: $(command -v waydroid)"
else
    warn "未找到 waydroid 命令（Waydroid 未安装？watcher 会等它出现）"
fi
if grep -q 'elish-tablet-mode' /proc/bus/input/devices 2>/dev/null; then
    log "找到 elish-tablet-mode 虚拟开关"
else
    warn "未找到 elish-tablet-mode 设备：请先安装 tablet-mode/ 组件"
fi

step "1) 安装 watcher"
run install -D -m 0755 "$C/elish-waydroid-ime-watch.py" "$WATCH"

step "2) 安装并启动 systemd 服务"
run install -D -m 0644 "$C/systemd/elish-waydroid-ime.service" "$UNIT"
run systemctl daemon-reload
run systemctl enable --now elish-waydroid-ime.service
if [ "$DRY_RUN" = 0 ]; then
    sleep 2
    if systemctl is-active --quiet elish-waydroid-ime.service; then
        log "elish-waydroid-ime.service active"
    else
        warn "服务未 active：journalctl -u elish-waydroid-ime -b"
    fi
fi

step "完成"
cat <<EOT
Waydroid 软键盘联动已安装。
- watcher: $WATCH
- 服务: elish-waydroid-ime.service
- 自检: ./utils/waydroid/verify.sh
- 卸载: sudo ./utils/waydroid/uninstall.sh
EOT
