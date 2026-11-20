#!/bin/bash
# flash-led/verify.sh — 验证“开机闪光灯误闪”修复是否安装正确
#
# 用法：
#   ./flash-led/verify.sh             # 静态检查 + 离线过滤自检（不需要 root）
#   sudo ./flash-led/verify.sh --live # 额外重启一次 LED 状态恢复服务并抓 udev 事件
#                                      #  （应为 0 条 white:flash 事件；会短暂执行 restore）
#
# 退出码：0 = OK/SKIP；1 = FAIL。
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
WRAPPER=/usr/local/lib/elish/elish-led-state-restore-flash-safe.sh
UNIT=/usr/lib/systemd/system/armbian-led-state.service
DROPIN=/etc/systemd/system/armbian-led-state.service.d/50-elish-skip-flash.conf
FAIL=0
ok()   { echo "  OK    $*"; }
warn() { echo "  WARN  $*"; }
fail() { echo "  FAIL  $*"; FAIL=1; }
step() { echo; echo "==== $* ===="; }

LIVE=0
[ "${1:-}" = "--live" ] && LIVE=1

step "flash-led（后摄闪光灯开机误闪修复）"

if [ ! -e "$UNIT" ]; then
    echo "  SKIP  未找到 armbian-led-state.service（非 Armbian 或该服务不存在）"
else
    [ -x "$WRAPPER" ] && ok "wrapper 已安装: $WRAPPER" || fail "缺少 wrapper: $WRAPPER"
    [ -f "$DROPIN" ] && ok "drop-in 已安装: $DROPIN" || fail "缺少 drop-in: $DROPIN"
    if [ -f "$DROPIN" ] && grep -q "^ExecStart=$WRAPPER$" "$DROPIN"; then
        ok "drop-in 指向 flash-safe wrapper"
    else
        fail "drop-in 未指向 $WRAPPER"
    fi
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl show armbian-led-state.service -p ExecStart 2>/dev/null | grep -q "$WRAPPER"; then
            ok "systemd 实际 ExecStart 已生效"
        else
            warn "systemd 实际 ExecStart 未见 wrapper（daemon-reload 未执行？）"
        fi
    fi
fi

# 离线过滤自检：不碰真实 LED，只验证“flash 类 stanza 被剔除、普通 stanza 保留”
if [ -x "$WRAPPER" ]; then
    TMPD=$(mktemp -d 2>/dev/null) || TMPD=""
    if [ -n "$TMPD" ]; then
        mkdir -p "$TMPD/leds/white:flash" "$TMPD/leds/input0::capslock"
        : >"$TMPD/leds/white:flash/flash_strobe"
        printf '[none] default-on\n' >"$TMPD/leds/white:flash/trigger"
        printf '[none] kbd-capslock\n' >"$TMPD/leds/input0::capslock/trigger"
        cat >"$TMPD/state.conf" <<EOF
[$TMPD/leds/white:flash]
trigger=none
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
            ok "离线过滤自检：flash 类 LED 已剔除，普通 LED 保留"
        else
            fail "离线过滤自检失败（wrapper 逻辑异常）"
        fi
        rm -rf "$TMPD"
    else
        warn "mktemp 失败，跳过离线过滤自检"
    fi
fi

if [ "$LIVE" = 1 ]; then
    if [ "$(id -u)" -ne 0 ]; then
        warn "--live 需要 root，跳过"
    elif ! command -v udevadm >/dev/null 2>&1; then
        warn "缺少 udevadm，跳过 --live"
    else
        TMPLOG=$(mktemp)
        udevadm monitor --udev --subsystem-match=leds >"$TMPLOG" 2>&1 &
        MON=$!
        sleep 0.4
        systemctl restart armbian-led-state.service >/dev/null 2>&1 || true
        sleep 1.0
        kill "$MON" 2>/dev/null || true
        wait "$MON" 2>/dev/null || true
        N=$(grep -c 'white:flash' "$TMPLOG" 2>/dev/null || true)
        if [ "${N:-0}" -eq 0 ]; then
            ok "--live：重启恢复服务后 0 条 white:flash 事件（不再写闪光灯）"
        else
            fail "--live：仍有 $N 条 white:flash 事件（修复未生效）"
        fi
        rm -f "$TMPLOG"
    fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "== flash-led 自检: OK =="
    exit 0
else
    echo "== flash-led 自检: FAIL =="
    exit 1
fi
