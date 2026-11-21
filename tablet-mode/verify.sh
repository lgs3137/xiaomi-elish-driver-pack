#!/bin/bash
# tablet-mode/verify.sh — 验证可选的「平板模式」组件（helper 服务 + GNOME 扩展）
#
# 未安装时输出 SKIP 并返回 0（可选组件，check-all 不会因此失败）。
# 退出码：0 = OK/SKIP；1 = FAIL。
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
UUID=tablet-mode@elish
HELPER=/usr/local/bin/elish-tablet-mode-switch
UNIT=/etc/systemd/system/elish-tablet-mode.service
CONF=/etc/elish-orientation.conf
FAIL=0
ok()   { echo "  OK    $*"; }
warn() { echo "  WARN  $*"; }
fail() { echo "  FAIL  $*"; FAIL=1; }
step() { echo; echo "==== $* ===="; }

U=${TM_USER:-${SUDO_USER:-}}
[ -n "$U" ] || U=$(id -un 2>/dev/null || echo '')
UHOME=$(getent passwd "$U" 2>/dev/null | cut -d: -f6)
DEST="${UHOME:-/nonexistent}/.local/share/gnome-shell/extensions/$UUID"
UIDN=$(id -u "$U" 2>/dev/null || echo '')
RUNDIR="/run/user/${UIDN:-0}"

as_user() {
    runuser -u "$U" -- env XDG_RUNTIME_DIR="$RUNDIR" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNDIR/bus" "$@"
}

step "tablet-mode（可选：平板模式开关 + 控制中心扩展）"

if [ ! -e "$HELPER" ] && [ ! -e "$DEST" ]; then
    echo "  SKIP  未安装平板模式组件（可选；sudo ./tablet-mode/install.sh）"
    exit 0
fi

[ -x "$HELPER" ] && ok "uinput helper: $HELPER" || fail "缺少 $HELPER"
[ -e "$UNIT" ] && ok "systemd 单元: $UNIT" || fail "缺少 $UNIT"

if [ -e "$UNIT" ]; then
    if systemctl is-active --quiet elish-tablet-mode.service 2>/dev/null; then
        ok "elish-tablet-mode.service active"
    else
        fail "elish-tablet-mode.service 未运行（journalctl -u elish-tablet-mode -b）"
    fi
fi

if [ -f "$CONF" ]; then
    MODE=$(sed -n 's/^[[:space:]]*tablet_mode[[:space:]]*=[[:space:]]*//p' "$CONF" | tail -1 | tr -d '\r')
    ok "配置 tablet_mode=${MODE:-<未设置，默认 auto>}"
    if [ "$(id -u)" -eq 0 ] && [ -n "$U" ]; then
        if runuser -u "$U" -- test -w "$CONF" 2>/dev/null; then
            ok "配置对用户 $U 可写（控制中心开关无需 sudo）"
        else
            warn "配置对用户 $U 不可写：chgrp $(id -gn "$U") $CONF && chmod 0664 $CONF"
        fi
    fi
else
    warn "缺少 $CONF（默认 auto 行为由内核霍尔提供）"
fi

if [ -d "$DEST" ]; then
    ok "扩展目录: $DEST"
    [ -f "$DEST/metadata.json" ] && ok "扩展 metadata 存在" || fail "缺少 $DEST/metadata.json"
    [ -f "$DEST/extension.js" ] && ok "扩展主代码存在" || fail "缺少 $DEST/extension.js"
else
    warn "未安装 GNOME 扩展（helper 仍可用命令行：elish-camera-ctl orientation tablet on|off|auto）"
fi

if [ "$(id -u)" -ne 0 ]; then
    warn "非 root：跳过 dconf / 会话加载状态检查（用 sudo 运行更完整）"
elif [ ! -S "$RUNDIR/bus" ]; then
    warn "用户 $U 当前没有图形会话，跳过 dconf/加载状态检查"
else
    CUR=$(as_user gsettings get org.gnome.shell enabled-extensions 2>/dev/null || true)
    if printf '%s' "$CUR" | grep -q "$UUID"; then
        ok "已在 $U 的 enabled-extensions 中"
    else
        fail "未在 $U 的 enabled-extensions（登录桌面后执行：gnome-extensions enable $UUID）"
    fi
    if command -v gnome-extensions >/dev/null 2>&1; then
        INFO=$(as_user gnome-extensions info "$UUID" 2>&1 || true)
        if printf '%s' "$INFO" | grep -Eq '已启用: 是|Enabled: Yes|状态: ACTIVE|State: ACTIVE'; then
            ok "GNOME Shell 已加载扩展（ACTIVE）"
        else
            warn "GNOME Shell 尚未加载扩展（新装需注销/重新登录；当前会话旧 Shell 不会热加载）"
        fi
    fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "== tablet-mode 自检: OK =="
    exit 0
else
    echo "== tablet-mode 自检: FAIL =="
    exit 1
fi
