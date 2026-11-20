#!/bin/bash
# install-dtb.sh — 安装包内单一联合 DTB（已合并 Hi556），可选重建 Linux 启动槽
#
# 用法（root）：
#   sudo ./kernel/install-dtb.sh                 # 只装 rootfs/boot 下的 DTB，不写启动槽
#   sudo ./kernel/install-dtb.sh --write-boot    # 另重建并写 armbianEnv 指定的 Linux 槽
#   sudo ./kernel/install-dtb.sh --dry-run       # 只打印
#   sudo ./kernel/install-dtb.sh --slot boot_b   # 断言槽位（与 armbianEnv 不一致则报错）
#
# 说明：
# - 包内 kernel/dtb/sm8250-xiaomi-elish-csot.dtb 是唯一模型级联合 DTB，已合并 Hi556；
# - 不碰 Android 槽；--write-boot 由 kernel/update-boot-image.sh 完成（含备份+回读校验）；
# - 只写 /usr/lib/linux-image-<ver>/qcom/ 与 /boot/dtb-<ver>/qcom/。
set -euo pipefail
TAG=dtb
. "$(dirname "$0")/../install/lib/common.sh"

WRITE_BOOT=0; SLOT_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --write-boot) WRITE_BOOT=1; shift ;;
        --slot) SLOT_ARG=${2:-}; shift 2 ;;
        --yes) ASSUME_YES=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) awk 'NR>1 { if ($0 ~ /^#/) { sub(/^# ?/, ""); print } else exit }' "$0"; exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
done
export DRY_RUN ASSUME_YES
need_root

KREL=$(uname -r)
SRC="$PKG_ROOT/kernel/dtb/sm8250-xiaomi-elish-csot.dtb"
DEST="/usr/lib/linux-image-$KREL/qcom/sm8250-xiaomi-elish-csot.dtb"
BOOT="/boot/dtb-$KREL/qcom/sm8250-xiaomi-elish-csot.dtb"
[ -f "$SRC" ] || die "包内 DTB 不存在: $SRC"

LABEL=""
if [ "$WRITE_BOOT" = 1 ]; then
    ENVFILE=/boot/armbianEnv.txt
    [ -f "$ENVFILE" ] || die "缺少 $ENVFILE，无法确定 Linux 启动槽"
    LABEL=$(sed -n 's/^[[:space:]]*abl_boot_partition_label[[:space:]]*=[[:space:]]*//p' "$ENVFILE" | tail -1 | tr -d '\r')
    [ -n "$LABEL" ] || die "$ENVFILE 未设置 abl_boot_partition_label（不盲写启动槽）"
    if [ -n "$SLOT_ARG" ] && [ "$SLOT_ARG" != "$LABEL" ]; then
        die "--slot $SLOT_ARG 与 armbianEnv 的 $LABEL 不一致"
    fi
fi

D=$(date +%Y%m%d-%H%M%S)
BK=/root/elish-dtb-backup-$D
if [ "$DRY_RUN" = 0 ]; then
    run mkdir -p "$BK"
    for f in "$DEST" "$BOOT"; do
        [ -e "$f" ] && run cp -a "$f" "$BK/$(echo "$f" | tr '/' '_')"
    done
fi

log "源 DTB: $SRC"
log "sha256: $(sha256sum "$SRC" | cut -d' ' -f1)"
step "安装 DTB（不重建启动槽）"
run install -D -m 0644 "$SRC" "$DEST"
run install -D -m 0644 "$SRC" "$BOOT"
if [ "$DRY_RUN" = 0 ]; then
    run bash "$PKG_ROOT/kernel/dtb/verify-combined-dtb.sh" "$DEST"
fi

if [ "$WRITE_BOOT" = 1 ]; then
    step "重建 Linux 启动槽 $LABEL（不碰 Android 槽）"
    confirm "即将重建并写入 $LABEL（boot 分区会先 dd 备份）。继续？" || die "用户取消（未写启动槽）"
    run bash "$PKG_ROOT/kernel/update-boot-image.sh" --slot "$LABEL"
    log "已完成；如刚改 DTB，建议 sudo reboot 后验证 Hi556/前后摄"
else
    log "未加 --write-boot：只更新了 rootfs/boot 下的 DTB 文件"
    log "需要让新 DTB 生效时执行： sudo $PKG_ROOT/kernel/update-boot-image.sh --slot ${LABEL:-<armbianEnv 槽>}"
fi
