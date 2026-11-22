#!/bin/bash
# pogo/uninstall.sh —— 卸载 pogo 键盘唤醒自动复位组件
#
# 移除：/usr/local/sbin/elish-pogo-kb-reset
#       /usr/lib/systemd/system-sleep/69-elish-pogo-kb.sh
#       /etc/default/elish-pogo-kb
# 默认保留日志；--purge 同时删除 /var/log/elish-pogo-kb.log(.1)
# 并尝试释放 sysfs 中已导出的键盘 reset GPIO（不会改动引脚复用/内核状态）。
#
# 用法（root）：sudo ./pogo/uninstall.sh [--dry-run] [--yes] [--purge]
set -euo pipefail
TAG=pogo
. "$(dirname "$0")/../install/lib/common.sh"

DRY_RUN=${DRY_RUN:-0}
ASSUME_YES=${ASSUME_YES:-0}
PURGE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --yes) ASSUME_YES=1; shift ;;
        --purge) PURGE=1; shift ;;
        -h|--help) awk 'NR>1 { if ($0 ~ /^#/) { sub(/^# ?/, ""); print } else exit }' "$0"; exit 0 ;;
        *) die "未知参数: $1（-h 查看用法）" ;;
    esac
done
export DRY_RUN ASSUME_YES
need_root

HELPER=/usr/local/sbin/elish-pogo-kb-reset
HOOK=/usr/lib/systemd/system-sleep/69-elish-pogo-kb.sh
CONF=/etc/default/elish-pogo-kb
LOG=/var/log/elish-pogo-kb.log
CFG_GPIO=141
CFG_LABEL=f100000.pinctrl

if [ -r "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF"
    CFG_GPIO=${RST_GPIO:-$CFG_GPIO}
    CFG_LABEL=${TLMM_LABEL:-$CFG_LABEL}
fi
case "$CFG_GPIO" in ''|*[!0-9]*) CFG_GPIO=141 ;; esac

step "1) 停止并删除安装的文件"
run rm -f "$HOOK"
run rm -f "$HELPER"
run rm -f "$CONF"
run rm -f /run/elish-pogo-kb.lock

step "2) 释放已导出的键盘 reset GPIO（若有）"
BASE=""
for c in /sys/class/gpio/gpiochip*; do
    if [ "$(cat "$c/label" 2>/dev/null)" = "$CFG_LABEL" ]; then
        BASE=$(cat "$c/base" 2>/dev/null)
    fi
done
if [ -n "$BASE" ]; then
    N=$((BASE + CFG_GPIO))
    if [ -e "/sys/class/gpio/gpio$N" ]; then
        run sh -c "echo $N > /sys/class/gpio/unexport" || \
            warn "释放 gpio$N 失败（可忽略；重启后自然释放）"
        log "已释放 gpio$N（TLMM $CFG_GPIO）"
    else
        log "gpio$((BASE + CFG_GPIO)) 未导出，无需释放"
    fi
else
    warn "未找到 gpiochip label=$CFG_LABEL，跳过 GPIO 释放"
fi

step "3) 日志"
if [ "$PURGE" = 1 ]; then
    run rm -f "$LOG" "$LOG.1"
    log "已删除日志（--purge）"
else
    log "保留日志: $LOG（如需删除：sudo ./pogo/uninstall.sh --purge）"
fi

step "完成"
cat <<EOF
pogo 键盘唤醒自动复位组件已卸载。
- 已删除 $HELPER、$HOOK、$CONF
- 不再在唤醒后脉冲 GPIO；唤醒后若键盘再次假死，需物理拔插或手动复位：
  （本组件卸载后没有手动 CLI；可重新安装或临时用 gpio sysfs 脉冲 TLMM $CFG_GPIO）
- 建议重启一次，确保 GPIO/复用状态干净。
EOF
