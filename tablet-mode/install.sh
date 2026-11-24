#!/bin/bash
# tablet-mode/install.sh — 可选组件：平板模式（开/关/自动）+ GNOME 46 控制中心开关
#
# 安装内容：
#   /usr/local/bin/elish-tablet-mode-switch       （uinput 虚拟 SW_TABLET_MODE，root 服务）
#   /etc/systemd/system/elish-tablet-mode.service （开机启动，1 秒内响应配置变化）
#   ~<user>/.local/share/gnome-shell/extensions/tablet-mode@elish/
#                                                （GNOME 46 Quick Settings 开关）
#   /etc/elish-orientation.conf 调整为 root:<用户组> 0664（普通用户可写，切换不需 sudo）
#
# 用法（root）：sudo ./tablet-mode/install.sh [--dry-run] [--yes] [--user <用户名>]
# 卸载：sudo ./tablet-mode/uninstall.sh
set -euo pipefail
TAG=tablet-mode
. "$(dirname "$0")/../install/lib/common.sh"

DRY_RUN=${DRY_RUN:-0}
ASSUME_YES=${ASSUME_YES:-0}
TM_USER=${TM_USER:-}
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --yes) ASSUME_YES=1; shift ;;
        --user) TM_USER=${2:-}; shift 2 ;;
        -h|--help) awk 'NR>1 { if ($0 ~ /^#/) { sub(/^# ?/, ""); print } else exit }' "$0"; exit 0 ;;
        *) die "未知参数: $1（-h 查看用法）" ;;
    esac
done
export DRY_RUN ASSUME_YES
need_root

C="$PKG_ROOT/tablet-mode"
UUID=tablet-mode@elish
HELPER=/usr/local/bin/elish-tablet-mode-switch
UNIT=/etc/systemd/system/elish-tablet-mode.service
KDETECT=/usr/local/sbin/elish-keyboard-detect
KUNIT=/etc/systemd/system/elish-keyboard-detect.service
CONF=/etc/elish-orientation.conf
SRC="$PKG_ROOT/camera/elish-camera/tools/tablet_mode_switch.c"
U=${TM_USER:-${SUDO_USER:-}}
if [ -z "$U" ] || [ "$U" = root ]; then
    if [ "$DRY_RUN" = 1 ]; then
        U=$(id -un)
    else
        die "无法确定目标桌面用户：请用 sudo 运行（自动取 SUDO_USER），或 sudo TM_USER=<用户名> ./tablet-mode/install.sh"
    fi
fi
id "$U" >/dev/null 2>&1 || die "用户不存在: $U"
UIDN=$(id -u "$U")
GIDN=$(id -gn "$U")
UHOME=$(getent passwd "$U" | cut -d: -f6)
DEST="$UHOME/.local/share/gnome-shell/extensions/$UUID"
RUNDIR="/run/user/$UIDN"

as_user() {
    runuser -u "$U" -- env XDG_RUNTIME_DIR="$RUNDIR" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNDIR/bus" "$@"
}

step "0) 环境检查"
have gcc || die "缺少 gcc（sudo apt install build-essential）"
[ -f "$SRC" ] || die "缺少源码: $SRC（请从完整包运行）"
if have gnome-shell; then
    GNOME_VER=$(gnome-shell --version 2>/dev/null | awk '{print $3}')
    case "$GNOME_VER" in
        46.*|46) log "GNOME Shell $GNOME_VER（扩展声明 shell-version 46）" ;;
        *) warn "GNOME Shell $GNOME_VER：扩展只声明 46，可能不会加载（升级后需自行改 metadata）" ;;
    esac
fi
[ -n "$UHOME" ] && [ -d "$UHOME" ] || die "用户主目录不存在: $UHOME"
if [ -x /usr/local/bin/elish-camera-ctl ]; then
    log "找到 elish-camera-ctl（扩展用它写配置）"
else
    warn "未找到 /usr/local/bin/elish-camera-ctl：请先安装相机组件（sudo ./camera/install.sh），否则控制中心开关无法写配置"
fi

step "1) 配置文件 $CONF"
if [ "$DRY_RUN" = 1 ]; then
    log "DRY: 确保 $CONF 存在并设为 root:$GIDN 0664"
else
    if [ ! -f "$CONF" ]; then
        printf '# elish orientation settings (edit with: elish-camera-ctl orientation)\n# tablet_mode: on | off | auto\n#   on   = always tablet mode -> GNOME auto-rotate always enabled\n#   off  = never tablet mode  -> GNOME auto-rotate disabled\n#   auto = keyboard detect first (GPIO83, elish-keyboard-detect), else hall switch\n\n# rebuild_mode: idle | live | off\nrebuild_mode=idle\ntablet_mode=auto\n' > "$CONF"
        log "已创建 $CONF（tablet_mode=auto）"
    fi
    chown root:"$GIDN" "$CONF"
    chmod 0664 "$CONF"
    log "$CONF -> root:$GIDN 0664（$U 组可写）"
fi

step "2) 编译并安装 uinput helper"
run mkdir -p "$C/build"
run gcc -O2 -Wall -Wextra -o "$C/build/elish-tablet-mode-switch" "$SRC"
run install -D -m 0755 "$C/build/elish-tablet-mode-switch" "$HELPER"

step "3) 安装并启动 systemd 服务"
run install -D -m 0644 "$C/systemd/elish-tablet-mode.service" "$UNIT"
run systemctl daemon-reload
run systemctl enable --now elish-tablet-mode.service
if [ "$DRY_RUN" = 0 ]; then
    if systemctl is-active --quiet elish-tablet-mode.service; then
        log "elish-tablet-mode.service active"
    else
        warn "服务未 active：journalctl -u elish-tablet-mode -b 查看（/dev/uinput 权限？）"
    fi
fi

step "3b) 安装键盘检测服务（GPIO83 → /run/elish-keyboard-present）"
have gpiomon || warn "缺少 gpiomon（apt install gpiod）：键盘检测服务将无法工作"
run install -D -m 0755 "$C/elish-keyboard-detect.py" "$KDETECT"
run install -D -m 0644 "$C/systemd/elish-keyboard-detect.service" "$KUNIT"
# 冷启动默认状态配置（已存在则不覆盖，保留用户选择）
if [ ! -e /etc/default/elish-keyboard-detect ]; then
    run install -D -m 0644 "$C/elish-keyboard-detect.conf" /etc/default/elish-keyboard-detect
fi
run systemctl daemon-reload
run systemctl enable --now elish-keyboard-detect.service
run systemctl restart elish-tablet-mode.service
if [ "$DRY_RUN" = 0 ]; then
    sleep 1
    if systemctl is-active --quiet elish-keyboard-detect.service; then
        log "elish-keyboard-detect.service active（键盘状态: $(cat /run/elish-keyboard-present 2>/dev/null || echo 未知)）"
    else
        warn "键盘检测服务未 active：journalctl -u elish-keyboard-detect -b"
    fi
fi

step "4) 安装 GNOME 46 Quick Settings 扩展（用户 $U）"
if [ "$DRY_RUN" = 1 ]; then
    printf '    DRY: install -d %s\n' "$(dirname "$DEST")"
    printf '    DRY: cp -r %s %s\n' "$C/tablet-mode@elish" "$DEST"
else
    install -d -m 0755 -o "$U" -g "$GIDN" "$(dirname "$DEST")"
    rm -rf "$DEST"
    cp -r "$C/tablet-mode@elish" "$DEST"
    chown -R "$U:$GIDN" "$DEST"
    find "$DEST" -type f -exec chmod 0644 {} +
    find "$DEST" -type d -exec chmod 0755 {} +
fi

step "5) 在用户 dconf 中启用扩展（下次登录生效）"
if [ "$DRY_RUN" = 1 ]; then
    log "DRY: 在 $U 的 dconf 中把 $UUID 加入 org.gnome.shell enabled-extensions"
elif [ -S "$RUNDIR/bus" ]; then
    CUR=$(as_user gsettings get org.gnome.shell enabled-extensions 2>/dev/null || echo "@as []")
    NEW=$(python3 - "$CUR" "$UUID" <<'PY'
import ast
import sys

uuid = sys.argv[2]
try:
    cur = ast.literal_eval(sys.argv[1])
except Exception:
    cur = []
if uuid not in cur:
    cur.append(uuid)
print(repr(cur))
PY
)
    if as_user gsettings set org.gnome.shell enabled-extensions "$NEW" 2>/dev/null; then
        log "已在 $U 的 dconf 中启用 $UUID"
    else
        warn "dconf 写入失败；登录 $U 的桌面后执行：gnome-extensions enable $UUID"
    fi
else
    warn "用户 $U 当前没有图形会话（$RUNDIR/bus 不存在）：登录桌面后执行 gnome-extensions enable $UUID"
fi

step "完成"
cat <<EOF
平板模式组件已安装。
- helper: $HELPER（服务 elish-tablet-mode.service）
- 键盘检测: $KDETECT（服务 elish-keyboard-detect.service，GPIO83 → /run/elish-keyboard-present）
- 配置: $CONF（tablet_mode = on|off|auto，$U 组可写；auto 优先按键盘拔插，其次霍尔）
- 扩展: $DEST（用户 $U）

用法：
  GNOME 46 **不支持热加载新扩展**：注销/重新登录后，控制中心（右上角 / Super+S）出现
  「平板模式」开关；点击在 自动 -> 开 -> 关 之间循环，标题显示当前模式：
    自动 = 跟随磁吸保护套霍尔（默认）
    开   = 总是平板模式（自动旋转开启，适合没有保护套的人）
    关   = 总是笔记本模式（自动旋转关闭）
  命令行等价：elish-camera-ctl orientation tablet auto|on|off
  当前状态：  elish-camera-ctl orientation

看不到开关：gnome-extensions enable $UUID；journalctl --user -b | grep -iE 'tablet-mode|extension'
卸载：sudo ./tablet-mode/uninstall.sh
EOF
