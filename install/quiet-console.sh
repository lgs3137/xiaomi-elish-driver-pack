#!/bin/bash
# install/quiet-console.sh — 控制台静音（可选，默认不执行；可回滚）
#
# 做两件事：
#   1) /etc/sysctl.d/99-elish-quiet-console.conf：kernel.printk = 3 4 1 7
#      （注销时只留 crit/alert/emerg，journald 仍完整记录）
#   2) /boot/armbianEnv.txt 的 extraargs 追加 loglevel=3 vt.global_cursor_default=0，
#      并重建启动槽（kernel/update-boot-image.sh，自动备份/回读校验）
#
# 用法（root）：sudo ./install/quiet-console.sh [--rollback]
# 回滚：sudo ./install/quiet-console.sh --rollback
set -euo pipefail
TAG=quiet-console
. "$(dirname "$0")/lib/common.sh"
need_root
ACTION=${1:-}
SYSCTL=/etc/sysctl.d/99-elish-quiet-console.conf
ENVFILE=/boot/armbianEnv.txt
PKG_ROOT=$(cd "$(dirname "$0")/.." && pwd)

if [ "$ACTION" = "--rollback" ]; then
    step "回滚控制台静音"
    run rm -f "$SYSCTL"
    run sysctl --system >/dev/null 2>&1 || true
    if [ -f "$ENVFILE" ]; then
        run sed -i 's/^extraargs=.*/extraargs="splash quiet cma=256M"/' "$ENVFILE"
        grep '^extraargs=' "$ENVFILE" || true
    fi
    step "重建启动槽（去掉 loglevel=3）"
    run bash "$PKG_ROOT/kernel/update-boot-image.sh"
    log "已回滚，重启后恢复默认（会重新显示早期 error 行）"
    exit 0
fi

step "1) 写入 sysctl（立即生效）"
run install -D -m 0644 "$PKG_ROOT/install/quiet-console.conf" "$SYSCTL"
run sysctl --system >/dev/null 2>&1 || true
cat /proc/sys/kernel/printk

step "2) 追加 boot cmdline 并重建启动槽"
[ -f "$ENVFILE" ] || die "缺少 $ENVFILE"
if grep -q '^extraargs=' "$ENVFILE"; then
    run sed -i 's/^extraargs=.*/extraargs="splash quiet cma=256M loglevel=3 vt.global_cursor_default=0"/' "$ENVFILE"
else
    run sh -c "echo 'extraargs=\"splash quiet cma=256M loglevel=3 vt.global_cursor_default=0\"' >> '$ENVFILE'"
fi
grep '^extraargs=' "$ENVFILE" || true
run bash "$PKG_ROOT/kernel/update-boot-image.sh"

step "完成"
printf '%s\n' \
  "控制台静音已应用：" \
  "- sysctl: $SYSCTL（kernel.printk = 3 4 1 7）" \
  "- boot cmdline: loglevel=3 vt.global_cursor_default=0（重启后生效）" \
  "- 回滚: sudo ./install/quiet-console.sh --rollback"
