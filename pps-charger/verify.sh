#!/bin/bash
# pps-charger/verify.sh — 验证受控 11V PPS 快充服务
#
# 未安装时输出 SKIP 并返回 0（可选组件）。
set -u
BIN=/usr/local/sbin/elish-pps-charger
UNIT=/etc/systemd/system/elish-pps-charger.service
FAIL=0
ok()   { echo "  OK    $*"; }
warn() { echo "  WARN  $*"; }
fail() { echo "  FAIL  $*"; FAIL=1; }

echo
echo "==== pps-charger（可选：受控 11V PPS 快充）===="

if [ ! -e "$BIN" ] && [ ! -e "$UNIT" ]; then
    echo "  SKIP  未安装（可选组件；sudo ./pps-charger/install.sh）"
    exit 0
fi

[ -x "$BIN" ] && ok "服务脚本: $BIN" || fail "缺少 $BIN"
[ -e "$UNIT" ] && ok "systemd 单元: $UNIT" || fail "缺少 $UNIT"

if [ -e "$UNIT" ]; then
    if systemctl is-active --quiet elish-pps-charger.service 2>/dev/null; then
        ok "elish-pps-charger.service active"
    else
        fail "服务未运行（journalctl -u elish-pps-charger -b）"
    fi
fi

if command -v python3 >/dev/null 2>&1 && [ -x "$BIN" ]; then
    # 内存里编译，避免非 root 时 py_compile 往 /usr/local/sbin 写 __pycache__ 而误报
    if python3 -c 'import sys; compile(open(sys.argv[1], "rb").read(), sys.argv[1], "exec")' "$BIN" 2>/dev/null; then
        ok "Python 语法检查通过"
    else
        fail "Python 语法错误"
    fi
fi

if ls /sys/class/power_supply/tcpm-source-psy-* >/dev/null 2>&1; then
    PSY=$(ls -d /sys/class/power_supply/tcpm-source-psy-* | head -1)
    TYPE=$(cat "$PSY/usb_type" 2>/dev/null)
    ONLINE=$(cat "$PSY/online" 2>/dev/null)
    ok "PD: online=$ONLINE usb_type=$TYPE"
    case "$TYPE" in
        *PD_PPS*) ok "充电器支持 PPS（11V 快充可用）" ;;
        *) warn "当前充电器不含 PPS（只走 9V 固定档）" ;;
    esac
    [ "$ONLINE" = "2" ] && ok "当前处于 PPS 11V 模式" || true
else
    warn "没有 tcpm-source-psy（未插充电器）"
fi

if [ "$(id -u)" -ne 0 ]; then
    warn "非 root：跳过 journal 检查（用 sudo 运行更完整）"
fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "== pps-charger 自检: OK =="
    exit 0
else
    echo "== pps-charger 自检: FAIL =="
    exit 1
fi
