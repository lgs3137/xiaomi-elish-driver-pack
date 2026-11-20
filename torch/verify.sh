#!/bin/bash
# torch/verify.sh — 验证可选的 GNOME 手电筒组件（扩展 + torch CLI）
#
# 未安装时输出 SKIP 并返回 0（可选组件，check-all 不会因此失败）。
# 退出码：0 = OK/SKIP；1 = FAIL。
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
UUID=torch@elish
TORCH_BIN=/usr/local/bin/torch
FAIL=0
ok()   { echo "  OK    $*"; }
warn() { echo "  WARN  $*"; }
fail() { echo "  FAIL  $*"; FAIL=1; }
step() { echo; echo "==== $* ===="; }

U=${TORCH_USER:-${SUDO_USER:-}}
[ -n "$U" ] || U=$(id -un 2>/dev/null || echo '')
UHOME=$(getent passwd "$U" 2>/dev/null | cut -d: -f6)
DEST="${UHOME:-/nonexistent}/.local/share/gnome-shell/extensions/$UUID"
UIDN=$(id -u "$U" 2>/dev/null || echo '')
RUNDIR="/run/user/${UIDN:-0}"

as_user() {
    runuser -u "$U" -- env XDG_RUNTIME_DIR="$RUNDIR" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNDIR/bus" "$@"
}

step "torch（可选 GNOME 手电筒；默认不装）"

if [ ! -e "$DEST" ] && [ ! -e "$TORCH_BIN" ]; then
    echo "  SKIP  未安装 GNOME 手电筒（可选组件；--with-torch 或 sudo ./torch/install.sh）"
    exit 0
fi

if [ -z "$U" ] || [ -z "$UHOME" ]; then
    fail "无法确定安装目标用户（TORCH_USER/SUDO_USER 均不可用）"
else
    [ -d "$DEST" ] && ok "扩展目录: $DEST" || fail "缺少扩展目录: $DEST"
    [ -f "$DEST/metadata.json" ] && ok "扩展 metadata 存在" || fail "缺少 $DEST/metadata.json"
    [ -f "$DEST/extension.js" ] && ok "扩展主代码存在" || fail "缺少 $DEST/extension.js"
fi
[ -x "$TORCH_BIN" ] && ok "命令行: $TORCH_BIN" || fail "缺少 $TORCH_BIN"

if [ "$(id -u)" -ne 0 ]; then
    warn "非 root：跳过 dconf / 会话加载状态检查（用 sudo 运行更完整）"
elif [ ! -S "$RUNDIR/bus" ]; then
    warn "用户 $U 当前没有图形会话（$RUNDIR/bus 不存在），跳过 dconf/加载状态检查"
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
    if as_user "$TORCH_BIN" off >/dev/null 2>&1 && as_user "$TORCH_BIN" status >/dev/null 2>&1; then
        ok "logind 手电筒通道可用（torch off/status；验证时已把亮度置 0）"
    else
        warn "logind 通道自检失败（会话可能不是活动会话；登录后 torch on/off 测试）"
    fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "== torch 自检: OK $([ -e "$DEST" ] && echo '' || echo '(部分)')=="
    exit 0
else
    echo "== torch 自检: FAIL =="
    exit 1
fi
