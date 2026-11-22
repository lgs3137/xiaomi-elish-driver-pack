#!/bin/bash
# pogo/install.sh —— pogo 键盘唤醒自动复位（用户态，不改内核）
#
# 背景：s2idle 唤醒后 pogo 键盘（Xiaomi Pad Keyboard）可能 HID 假死；实测脉冲键盘 reset
#       GPIO（TLMM 141）可让它重新枚举并恢复。详见同目录 README.md。
#
# 安装内容：
#   /usr/local/sbin/elish-pogo-kb-reset               （复位脚本，root）
#   /usr/lib/systemd/system-sleep/69-elish-pogo-kb.sh （唤醒后 +3s 调度复位）
#   /etc/default/elish-pogo-kb                        （配置；已存在则不覆盖）
#   /var/log/elish-pogo-kb.log                        （日志；不存在时创建）
#
# 用法（root）：sudo ./pogo/install.sh [--dry-run] [--yes]
# 卸载：sudo ./pogo/uninstall.sh
set -euo pipefail
TAG=pogo
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

C="$PKG_ROOT/pogo"
HELPER=/usr/local/sbin/elish-pogo-kb-reset
HOOK=/usr/lib/systemd/system-sleep/69-elish-pogo-kb.sh
CONF=/etc/default/elish-pogo-kb
LOG=/var/log/elish-pogo-kb.log

step "0) 环境检查"
need_cmd systemd-run
need_cmd flock
have lsusb || warn "缺少 lsusb（usb-utils）；hook/复位脚本会退回到 /sys 检测键盘，功能不受影响"
[ -f "$C/elish-pogo-kb-reset" ] || die "缺少 $C/elish-pogo-kb-reset"
[ -f "$C/system-sleep/69-elish-pogo-kb.sh" ] || die "缺少 $C/system-sleep/69-elish-pogo-kb.sh"
[ -f "$C/elish-pogo-kb.conf" ] || die "缺少 $C/elish-pogo-kb.conf"

step "1) 安装复位脚本与 systemd sleep hook"
run install -d -m 0755 /usr/local/sbin
run install -m 0755 "$C/elish-pogo-kb-reset" "$HELPER"
run install -d -m 0755 /usr/lib/systemd/system-sleep
run install -m 0755 "$C/system-sleep/69-elish-pogo-kb.sh" "$HOOK"

step "2) 安装默认配置（已存在则不覆盖）"
if [ -e "$CONF" ]; then
    log "已存在，保留现有配置: $CONF"
else
    run install -d -m 0755 /etc/default
    run install -m 0644 "$C/elish-pogo-kb.conf" "$CONF"
fi

step "3) 准备日志文件"
if [ "$DRY_RUN" = 1 ]; then
    printf '    DRY: touch %s (0644)\n' "$LOG"
elif [ ! -e "$LOG" ]; then
    install -m 0644 /dev/null "$LOG"
    log "已创建 $LOG"
else
    log "日志已存在: $LOG"
fi

step "4) 自检"
if [ "$DRY_RUN" = 1 ]; then
    log "DRY: 跳过 pogo/verify.sh"
else
    bash "$C/verify.sh" || warn "自检有 WARN/FAIL；如键盘当前未接，WARN 属正常"
fi

step "完成"
cat <<EOF
pogo 键盘唤醒自动复位（用户态）已安装。
- 复位脚本: $HELPER
- sleep hook: $HOOK（post 阶段 systemd-run --on-active=3s 调用复位）
- 配置:     $CONF（ENABLED / DELAY_SEC / RST_GPIO / PULSE_MS；已存在则不覆盖）
- 日志:     $LOG（>512 KiB 自动轮转 1 份）

行为：每次系统唤醒后约 3 秒，若检测到 pogo 键盘（3206:3ffc），脉冲 TLMM 141
约 150ms，键盘会静默重新枚举（设备号 +1），之后按键正常。

验证：
  sudo systemctl suspend        # 或合盖/按电源键睡眠；用电源键/RTC 唤醒
  # 唤醒后等 5 秒，键盘应可用；日志 tail -f $LOG
  sudo ./pogo/verify.sh
  sudo ./install/check-all.sh

停用而不卸载：把 $CONF 里 ENABLED 改成 0（下次唤醒生效）。
卸载：sudo ./pogo/uninstall.sh
EOF
