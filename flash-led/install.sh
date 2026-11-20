#!/bin/bash
# flash-led/install.sh — 后摄闪光灯“开机 logo 阶段闪一下”修复（默认组件）
#
# 根因（2026-11-20 诊断）：
#   Armbian 的 armbian-led-state.service 在开机很早（Plymouth 启动画面刚显示时）
#   执行 /usr/lib/armbian/armbian-led-state-restore.sh，按 /etc/armbian-leds.conf
#   恢复所有 LED 状态；该脚本对 trigger=none 的 workaround 是先写 "default-on"
#   再写 "none"。white:flash（PM8150L 后摄闪光灯/手电筒）也在状态文件里，写
#   default-on 时内核 LED 触发器把它设成 max_brightness（最大手电电流 200mA），
#   随后立即被 none 关掉 —— 即开机瞬间闪一下。
#
# 修复（不修改任何 Armbian 包文件；BSP/apt 升级不会还原）：
#   1) /usr/local/lib/elish/elish-led-state-restore-flash-safe.sh
#      过滤掉 flash 类 LED（带 flash_strobe 属性的）的 stanza，再调用原 restore
#      脚本（原脚本支持把状态文件作为 $1 传入）。
#   2) /etc/systemd/system/armbian-led-state.service.d/50-elish-skip-flash.conf
#      让 armbian-led-state.service 执行上面的 wrapper。
#
# 用法（root）：
#   sudo ./flash-led/install.sh [--dry-run] [--yes]
# 卸载：
#   sudo ./flash-led/uninstall.sh
# 验证：
#   sudo ./flash-led/verify.sh
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

C="$PKG_ROOT/flash-led"
UNIT=/usr/lib/systemd/system/armbian-led-state.service
WRAPPER=/usr/local/lib/elish/elish-led-state-restore-flash-safe.sh
DROPIN_DIR=/etc/systemd/system/armbian-led-state.service.d
DROPIN=$DROPIN_DIR/50-elish-skip-flash.conf
# 2026-11-20 手工修复曾用过“整份补丁副本”，安装时清掉，避免两套逻辑并存。
LEGACY=/usr/local/lib/elish/armbian-led-state-restore.sh

step "1) 安装状态恢复 wrapper"
run install -d -m 0755 /usr/local/lib/elish
run install -m 0755 "$C/elish-led-state-restore-flash-safe.sh" "$WRAPPER"
if [ -e "$LEGACY" ]; then
    log "移除旧版补丁副本: $LEGACY"
    run rm -f "$LEGACY"
fi

step "2) 安装 systemd drop-in"
if [ ! -e "$UNIT" ]; then
    warn "未找到 $UNIT（不是 Armbian？）——跳过 drop-in，后续验证会报 SKIP"
else
    run install -d -m 0755 "$DROPIN_DIR"
    if [ "$DRY_RUN" = 1 ]; then
        printf '    DRY: 写入 %s（ExecStart=%s）\n' "$DROPIN" "$WRAPPER"
    else
        cat >"$DROPIN" <<EOF
# elish: run the flash-safe wrapper of the Armbian LED state restore script so
# the camera flash LED (white:flash) is never state-restored (its trigger=none
# workaround briefly turns the torch on during boot — visible flash on Plymouth).
# Installed by xiaomi-elish-driver-pack flash-led/; remove this file to roll back.
[Service]
ExecStart=
ExecStart=$WRAPPER
EOF
    fi
fi

step "3) 重载 systemd"
run systemctl daemon-reload

step "4) 自检"
if [ "$DRY_RUN" = 1 ]; then
    log "DRY: 跳过离线过滤自检与实际服务检查"
else
    TMPD=$(mktemp -d)
    trap 'rm -rf "$TMPD"' EXIT
    mkdir -p "$TMPD/leds/white:flash" "$TMPD/leds/input0::capslock"
    : >"$TMPD/leds/white:flash/flash_strobe"
    printf '[none] default-on\n' >"$TMPD/leds/white:flash/trigger"
    printf '0\n' >"$TMPD/leds/white:flash/brightness"
    printf '[none] kbd-capslock\n' >"$TMPD/leds/input0::capslock/trigger"
    cat >"$TMPD/state.conf" <<EOF
[$TMPD/leds/white:flash]
trigger=none
flash_strobe=0
brightness=0

[$TMPD/leds/input0::capslock]
trigger=kbd-capslock
EOF
    cat >"$TMPD/capture.sh" <<EOF
#!/bin/sh
cp "\$1" "$TMPD/filtered.conf"
EOF
    chmod 0755 "$TMPD/capture.sh"
    if ELISH_LEDS_CONF="$TMPD/state.conf" ELISH_LEDS_RESTORE="$TMPD/capture.sh" \
           "$WRAPPER" >/dev/null 2>&1 \
       && ! grep -q 'white:flash' "$TMPD/filtered.conf" \
       && grep -q 'input0::capslock' "$TMPD/filtered.conf"; then
        log "OK  离线过滤自检：flash 类 LED 已剔除，普通 LED 保留"
    else
        die "离线过滤自检失败（wrapper 逻辑异常）"
    fi
    if [ -e "$UNIT" ]; then
        if systemctl show armbian-led-state.service -p ExecStart 2>/dev/null | grep -q "$WRAPPER"; then
            log "OK  armbian-led-state.service ExecStart 已指向 flash-safe wrapper"
        else
            warn "armbian-led-state.service ExecStart 未指向 wrapper（daemon-reload 后仍未生效？）"
        fi
    fi
fi

step "完成"
cat <<EOF
后摄闪光灯“开机闪一下”修复已安装（默认组件）。
- wrapper: $WRAPPER
- drop-in:  $DROPIN
- 下次开机生效（本次开机期间可 sudo ./flash-led/verify.sh 自检）。
- 回滚：sudo ./flash-led/uninstall.sh
EOF
