#!/bin/bash
# 69-elish-pogo-kb.sh —— 系统唤醒后自动复位 pogo 键盘（修复唤醒后键盘 HID 假死）
#
# 安装位置：/usr/lib/systemd/system-sleep/69-elish-pogo-kb.sh
# 配置：/etc/default/elish-pogo-kb（ENABLED / DELAY_SEC）
# 日志：/var/log/elish-pogo-kb.log
#
# 为什么用 systemd-run 延迟：
#   sleep hook 的 post 阶段仍可能在 USB/xHCI resume 过程中；历史上在 post 里 1 秒后直接操作
#   曾触发硬死机。这里只负责“排一个 3 秒后的 systemd 服务”，实际 GPIO 操作在
#   /usr/local/sbin/elish-pogo-kb-reset 里，等 resume 完成后再执行。
set -u

LOG=/var/log/elish-pogo-kb.log
CFG=/etc/default/elish-pogo-kb
ENABLED=1
DELAY_SEC=3

[ -r "$CFG" ] && . "$CFG"

[ "${1:-}" = "post" ] || exit 0
case "$ENABLED" in
    1|yes|true|on) ;;
    *) exit 0 ;;
esac
case "$DELAY_SEC" in ''|*[!0-9]*) DELAY_SEC=3 ;; esac
[ "$DELAY_SEC" -ge 1 ] || DELAY_SEC=1

kb_present() {
    local d
    if command -v lsusb >/dev/null 2>&1; then
        lsusb -d 3206:3ffc 2>/dev/null | grep -q .
        return
    fi
    for d in /sys/bus/usb/devices/*; do
        if [ "$(cat "$d/idVendor" 2>/dev/null)" = "3206" ] && \
           [ "$(cat "$d/idProduct" 2>/dev/null)" = "3ffc" ]; then
            return 0
        fi
    done
    return 1
}

# 没接 pogo 键盘就什么都不做（外接 USB/蓝牙键鼠不受影响）
kb_present || exit 0

command -v systemd-run >/dev/null 2>&1 || {
    echo "$(date -Is) ERROR: systemd-run not found; cannot schedule reset" >>"$LOG"
    exit 0
}
[ -x /usr/local/sbin/elish-pogo-kb-reset ] || {
    echo "$(date -Is) ERROR: /usr/local/sbin/elish-pogo-kb-reset missing" >>"$LOG"
    exit 0
}

unit="elish-pogo-kb-$(date +%s)-$$"
if ! systemd-run --collect --unit="$unit" --on-active="${DELAY_SEC}s" \
        --description="Reset pogo keyboard after resume" \
        /usr/local/sbin/elish-pogo-kb-reset >>"$LOG" 2>&1; then
    echo "$(date -Is) ERROR: systemd-run failed (unit=$unit)" >>"$LOG"
fi
exit 0
