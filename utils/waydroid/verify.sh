#!/bin/bash
# utils/waydroid/verify.sh — 自检（未安装时 SKIP）
set -u
BIN=/usr/local/sbin/elish-waydroid-ime-watch
UNIT=/etc/systemd/system/elish-waydroid-ime.service
FAIL=0
ok()   { echo "  OK    $*"; }
warn() { echo "  WARN  $*"; }
fail() { echo "  FAIL  $*"; FAIL=1; }

echo
echo "==== utils/waydroid（Waydroid 软键盘跟随平板模式）===="

if [ ! -e "$BIN" ] && [ ! -e "$UNIT" ]; then
    echo "  SKIP  未安装（sudo ./utils/waydroid/install.sh）"
    exit 0
fi

[ -x "$BIN" ] && ok "watcher: $BIN" || fail "缺少 $BIN"
[ -e "$UNIT" ] && ok "systemd 单元: $UNIT" || fail "缺少 $UNIT"

if systemctl is-active --quiet elish-waydroid-ime.service 2>/dev/null; then
    ok "elish-waydroid-ime.service active"
else
    fail "服务未运行（journalctl -u elish-waydroid-ime -b）"
fi

if grep -q 'elish-tablet-mode' /proc/bus/input/devices 2>/dev/null; then
    ok "虚拟开关 elish-tablet-mode 存在"
else
    warn "未找到 elish-tablet-mode（先装 tablet-mode/ 组件）"
fi

if [ "$(id -u)" -eq 0 ]; then
    SW=$(python3 - <<'PY'
import fcntl,glob,os
for p in glob.glob('/dev/input/event*'):
    try:
        fd=os.open(p,os.O_RDONLY)
        n=fcntl.ioctl(fd,(2<<30)|(256<<16)|(0x45<<8)|0x06,b'\0'*256)
        os.close(fd)
    except OSError: continue
    if b'elish-tablet-mode' in n:
        fd=os.open(p,os.O_RDONLY); b=bytearray(8)
        fcntl.ioctl(fd,(2<<30)|(8<<16)|(0x45<<8)|0x1b,b,True); os.close(fd)
        print((int.from_bytes(b,'little')>>1)&1); break
PY
)
    IME=$(waydroid shell -- settings get secure show_ime_with_hard_keyboard 2>/dev/null | tr -d '\r')
    echo "  SW_TABLET_MODE=${SW:-?}  show_ime=${IME:-?}"
    if [ -n "${SW:-}" ] && [ -n "${IME:-}" ] && [ "$IME" = "$SW" ]; then
        ok "show_ime 与平板模式一致"
    else
        warn "show_ime 与平板模式不一致（切换一次或重启 Waydroid 会话）"
    fi
else
    warn "非 root：跳过 show_ime 检查"
fi

echo
[ "$FAIL" -eq 0 ] && echo "== utils/waydroid 自检: OK ==" || { echo "== utils/waydroid 自检: FAIL =="; exit 1; }
