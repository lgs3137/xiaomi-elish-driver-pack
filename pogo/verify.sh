#!/bin/bash
# pogo/verify.sh —— 验证 pogo 键盘唤醒自动复位组件（hook + 复位脚本 + 配置）
#
# 未安装时输出 SKIP 并返回 0（可选/默认组件，check-all 不会因此失败）。
# 退出码：0 = OK/SKIP；1 = FAIL。
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
HELPER=/usr/local/sbin/elish-pogo-kb-reset
HOOK=/usr/lib/systemd/system-sleep/69-elish-pogo-kb.sh
CONF=/etc/default/elish-pogo-kb
LOG=/var/log/elish-pogo-kb.log
FAIL=0
ok()   { echo "  OK    $*"; }
warn() { echo "  WARN  $*"; }
fail() { echo "  FAIL  $*"; FAIL=1; }
step() { echo; echo "==== $* ===="; }

step "pogo 键盘唤醒自动复位（用户态，默认安装）"

if [ ! -e "$HOOK" ] && [ ! -e "$HELPER" ]; then
    echo "  SKIP  未安装（sudo ./pogo/install.sh 或一键器 --with-pogo）"
    exit 0
fi

[ -x "$HELPER" ] && ok "复位脚本: $HELPER" || fail "缺少/不可执行: $HELPER"
[ -x "$HOOK" ]   && ok "sleep hook: $HOOK"   || fail "缺少/不可执行: $HOOK"
if [ -f "$CONF" ]; then
    ok "配置文件: $CONF"
    # shellcheck disable=SC1090
    ( . "$CONF" 2>/dev/null ) || fail "配置文件无法解析: $CONF"
else
    fail "缺少配置文件: $CONF"
fi

command -v systemd-run >/dev/null 2>&1 && ok "systemd-run 可用" || fail "缺少 systemd-run"
command -v flock >/dev/null 2>&1 && ok "flock 可用" || warn "缺少 flock（复位脚本将不做并发串行化）"
command -v lsusb >/dev/null 2>&1 && ok "lsusb 可用" || warn "缺少 lsusb（退回到 /sys 检测键盘）"

TLMM_LABEL=f100000.pinctrl
RST_GPIO=141
if [ -r "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF"
    TLMM_LABEL=${TLMM_LABEL:-f100000.pinctrl}
    RST_GPIO=${RST_GPIO:-141}
fi
BASE=""
for c in /sys/class/gpio/gpiochip*; do
    if [ "$(cat "$c/label" 2>/dev/null)" = "$TLMM_LABEL" ]; then
        BASE=$(cat "$c/base" 2>/dev/null)
    fi
done
if [ -n "$BASE" ]; then
    N=$((BASE + RST_GPIO))
    ok "TLMM gpiochip: $TLMM_LABEL base=$BASE → gpio$N（TLMM $RST_GPIO）"
    if [ -e "/sys/class/gpio/gpio$N" ]; then
        V=$(cat "/sys/class/gpio/gpio$N/value" 2>/dev/null || echo "?")
        D=$(cat "/sys/class/gpio/gpio$N/direction" 2>/dev/null || echo "?")
        [ "$V" = "1" ] && [ "$D" = "out" ] && ok "gpio$N 已导出且保持高电平（direction=out, value=1）" \
            || warn "gpio$N 已导出但状态异常（direction=$D value=$V；正常应为 out/1）"
    else
        warn "gpio$N 尚未导出（安装后至少一次 suspend/resume 后会出现；属正常）"
    fi
else
    fail "未找到 gpiochip label=$TLMM_LABEL"
fi

if command -v lsusb >/dev/null 2>&1 && lsusb -d 3206:3ffc >/dev/null 2>&1; then
    ok "pogo 键盘已枚举（3206:3ffc）"
else
    warn "当前未检测到 pogo 键盘（hook 会跳过；不影响外接/蓝牙键鼠）"
fi

if [ -f "$LOG" ]; then
    LAST=$(grep -a "pulsed" "$LOG" 2>/dev/null | tail -1)
    if [ -n "$LAST" ]; then
        ok "日志中已有复位记录: $LAST"
    else
        warn "日志尚无复位记录（安装后还没经历过 suspend/resume）"
    fi
    if grep -aq "ERROR" "$LOG" 2>/dev/null; then
        warn "日志中存在 ERROR 行，请检查: grep ERROR $LOG | tail"
    fi
else
    warn "日志文件不存在: $LOG（安装脚本本应创建）"
fi

if [ "$(id -u)" -eq 0 ] && command -v systemd-run >/dev/null 2>&1; then
    if systemd-run --collect --unit="elish-pogo-kb-verify-$$" --on-active=1s /bin/true >/dev/null 2>&1; then
        ok "systemd-run 定时器 smoke test 通过"
    else
        warn "systemd-run 定时器 smoke test 失败（检查 systemd 是否正常）"
    fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "== pogo 自检: OK =="
    exit 0
else
    echo "== pogo 自检: FAIL =="
    exit 1
fi
