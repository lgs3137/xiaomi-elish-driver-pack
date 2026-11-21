#!/bin/bash
# pps-charger/install.sh — 受控 11V PPS 快充服务（可选，默认不装）
#
# 安装内容：
#   /usr/local/sbin/elish-pps-charger            （Python 服务）
#   /etc/systemd/system/elish-pps-charger.service
# 行为：PD PPS 充电器 + 电量 <90% 时请求 11V，按电池温度 4.5A/3.0A/2.0A 分档；
#       温度 >=41.5C 或电量 >=90% 退回 9V 固定档，拔线自动复位。
#
# 用法（root）：sudo ./pps-charger/install.sh [--dry-run] [--yes]
# 卸载：sudo ./pps-charger/uninstall.sh
set -euo pipefail
TAG=pps-charger
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

C="$PKG_ROOT/pps-charger"
BIN=/usr/local/sbin/elish-pps-charger
UNIT=/etc/systemd/system/elish-pps-charger.service

step "0) 环境检查"
have python3 || die "缺少 python3"
if ! ls /sys/class/power_supply/tcpm-source-psy-* >/dev/null 2>&1; then
    warn "当前没有 tcpm-source-psy（充电器没插？服务会等它出现）"
fi

step "1) 安装服务脚本"
run install -D -m 0755 "$C/elish-pps-charger" "$BIN"

step "2) 安装并启用 systemd 服务"
run install -D -m 0644 "$C/systemd/elish-pps-charger.service" "$UNIT"
run systemctl daemon-reload
# 实测：本机充电头 PPS 有 ~13s 看门狗，服务用 8s keep-alive 重发请求可稳定保持；
# 11V 下 50–56% 电量电池侧 ~20.5W（固定 9V 约 18.9W），温度上限 41.5C 回退。
run systemctl enable --now elish-pps-charger.service
if [ "$DRY_RUN" = 0 ]; then
    sleep 1
    systemctl --no-pager --lines=5 status elish-pps-charger.service || true
fi

step "完成"
cat <<EOF
受控 11V PPS 快充服务已安装并启用（开机自启）。
- 脚本: $BIN
- 服务: elish-pps-charger.service（enabled + active）
- 日志: journalctl -u elish-pps-charger -f
- 策略: 电量<90% 时 PPS 11V keep-alive（8s 刷新、每次刷新重设 ICL）；
        电流按温度分档 4.5A/3.375A/2.475A（上限 49.5W 输入）；
        温度 >=41.5C 或电量 >=90% 回退 9V 固定档，降到 <=38.5C 再试；拔线复位
- 实测: 50–56% 电量电池侧 ~20.5W（固定 9V 约 18.9W），温度约 40C
- 手动回退到 9V: sudo $BIN --revert
- 临时停用: sudo systemctl disable --now elish-pps-charger
- 卸载: sudo ./pps-charger/uninstall.sh
EOF
