#!/bin/bash
# hi556-apply-dtb.sh — 应用/回滚“景深相机 Hi556”联合 DTB 补丁（elish / SM8250 / CSOT）
#
# 安全设计：
#   * 默认 = dry-run：只构建 + 校验 + 打印计划，绝不写盘；
#   * 只有显式 --write-boot 才会安装 DTB 并重建 Linux 启动槽（需 root 手动执行）；
#   * 写盘前自动备份：目标 boot 分区（由 update-boot-image.sh dd 到 /root）、
#     现有 /usr/lib 与 /boot/dtb 下的 DTB（本脚本备份）、以及构建出的新 DTB；
#   * 只写 /boot/armbianEnv.txt 里 abl_boot_partition_label 指向的 Linux 槽，
#     绝不碰 Android 槽；不写块设备（由包内 update-boot-image.sh 负责，且自带回读校验）；
#   * 内核未启用 CONFIG_OF_OVERLAY：DTB 是“打进 boot 镜像”的，必须重建 boot 镜像才生效。
#
# 用法：
#   ./hi556-apply-dtb.sh                                  # dry-run（默认，可普通用户）
#   ./hi556-apply-dtb.sh --stage 1                        # dry-run 只加 ldo2/pinctrl/CCI0 传感器
#   ./hi556-apply-dtb.sh --method dtc                     # dry-run 用 dtc 往返方式构建
#   sudo ./hi556-apply-dtb.sh --write-boot                # 真正安装 + 重建启动槽（推荐分两阶段）
#   sudo ./hi556-apply-dtb.sh --rollback --write-boot     # 回滚到最近一次备份并重建启动槽
#   ./hi556-apply-dtb.sh -h
#
# 推荐流程（分阶段，降低风险）：
#   1) dry-run stage1 -> 确认输出；sudo --write-boot --stage 1 -> 重启 -> 看 dmesg 是否 probe 到 hi556；
#   2) probe 成功后再 sudo --write-boot --stage 2（接 camss port@0，启用出流链路）。
#   若 hi556 探测失败，stage1 不影响现有前/后摄；stage2 未验证 probe 就上会让 camss
#   async notifier 卡住（complete 不触发），前/后摄也会受影响 —— 见 hi556-dts.md §6。

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PKG_DIR=${PKG_DIR:-$(cd "$HERE/../../.." && pwd)}
TOOL="$HERE/hi556-build-dtb.py"
VERIFY="$PKG_DIR/kernel/dtb/verify-combined-dtb.sh"
UPDATE_BOOT="$PKG_DIR/kernel/update-boot-image.sh"

KVER=$(uname -r)
DTB_SYS="/usr/lib/linux-image-${KVER}/qcom/sm8250-xiaomi-elish-csot.dtb"
DTB_BOOT="/boot/dtb-${KVER}/qcom/sm8250-xiaomi-elish-csot.dtb"
BACKUP_ROOT=${BACKUP_ROOT:-/root/hi556-dtb-backup}
ENVFILE=/boot/armbianEnv.txt

MODE=dry-run
STAGE=2
METHOD=fdt
BASE=${BASE_DTB:-}
ROLLBACK=0
ASSUME_YES=0
WORK=

usage() { awk 'NR>1 { if ($0 ~ /^#/) { sub(/^# ?/, ""); print } else exit }' "$0"; }
die()  { echo "FAIL: $*" >&2; exit 1; }
say()  { echo "== $*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)     MODE=dry-run; shift ;;
        --write-boot)  MODE=write; shift ;;
        --rollback)    ROLLBACK=1; shift ;;
        --stage)       STAGE=${2:-}; shift 2 ;;
        --method)      METHOD=${2:-}; shift 2 ;;
        --base)        BASE=${2:-}; shift 2 ;;
        --yes|-y)      ASSUME_YES=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) die "未知参数: $1（-h 查看用法）" ;;
    esac
done

case "$STAGE" in 1|2) ;; *) die "--stage 只能是 1 或 2" ;; esac
case "$METHOD" in fdt|dtc|dtbo) ;; *) die "--method 只能是 fdt/dtc/dtbo" ;; esac

say "环境"
echo "  运行内核 : $KVER"
MODEL=$(tr -d '\0' < /sys/firmware/devicetree/base/model 2>/dev/null || true)
echo "  model    : ${MODEL:-未知}"
case "$MODEL" in
    *CSOT*) PANEL=csot ;;
    *BOE*)  die "本机是 BOE 面板；本补丁只按 CSOT 联合 DTB 生成，请先确认面板型号" ;;
    *)      echo "  WARN     : 无法从 model 判断面板（期望 *CSOT*），继续但请自行确认" ;;
esac
[ -f "$ENVFILE" ] || die "缺少 $ENVFILE"
SLOT=$(sed -n 's/^[[:space:]]*abl_boot_partition_label[[:space:]]*=[[:space:]]*//p' "$ENVFILE" | tail -1 | tr -d '\r')
[ -n "$SLOT" ] || die "$ENVFILE 未设置 abl_boot_partition_label，拒绝盲写"
echo "  Linux 槽 : $SLOT（$ENVFILE）"
echo "  面板     : ${PANEL:-unknown}"
[ -f "$TOOL" ] || die "缺少构建脚本 $TOOL"

if [ "$ROLLBACK" = 1 ]; then
    say "回滚模式"
    if [ ! -d "$BACKUP_ROOT" ] || ! ls -1d "$BACKUP_ROOT"/*/ >/dev/null 2>&1; then
        die "找不到备份目录 $BACKUP_ROOT/*/（未应用过或备份被清理）"
    fi
    LATEST=$(ls -1d "$BACKUP_ROOT"/*/ | sort | tail -1)
    echo "  最近备份: $LATEST"
    ls -l "$LATEST"
    if [ "$MODE" = dry-run ]; then
        cat <<EOF
  【dry-run】将执行（需 sudo）：
    install -m 0644 $LATEST/sm8250-xiaomi-elish-csot.dtb $DTB_SYS
    install -m 0644 $LATEST/sm8250-xiaomi-elish-csot.dtb $DTB_BOOT
    sudo $UPDATE_BOOT    # 备份 boot 分区 + 重建 $SLOT + 回读校验
    sudo reboot
EOF
        exit 0
    fi
    [ "$(id -u)" -eq 0 ] || die "--write-boot 需要 root：sudo $0 $*"
    [ -f "$LATEST/sm8250-xiaomi-elish-csot.dtb" ] || die "备份里没有 DTB"
    bash "$VERIFY" "$LATEST/sm8250-xiaomi-elish-csot.dtb" || die "备份 DTB 未通过 verify-combined-dtb.sh"
    install -D -m 0644 "$LATEST/sm8250-xiaomi-elish-csot.dtb" "$DTB_SYS"
    install -D -m 0644 "$LATEST/sm8250-xiaomi-elish-csot.dtb" "$DTB_BOOT"
    say "重建启动槽 $SLOT（含 boot 分区备份）"
    bash "$UPDATE_BOOT"
    echo "回滚完成：请 reboot 后确认前/后摄仍正常（dmesg | grep -E 'ov8856|ov13b10|hi556'）"
    exit 0
fi

# ---------------------------------------------------------------- 构建 + 校验
[ -n "$BASE" ] || BASE="$PKG_DIR/kernel/dtb/sm8250-xiaomi-elish-csot.dtb"
[ -f "$BASE" ] || die "找不到基线 DTB: $BASE"
# 包内联合 DTB 自 2026-11-20 起已合并 Hi556；无需再应用（避免重复/覆盖）。
if [ "$(sha256sum "$BASE" | awk '{print $1}')" = "0d639355650ad34ef3a03ed6af44f4fd2e1ec287aadd543a7c707238f8b544e8" ]; then
    echo "基线已是含 Hi556 的合并 DTB（$BASE），无需 stage1/stage2 应用。"
    echo "如需从旧基线重建，请显式传 --base /path/to/old-sm8250-xiaomi-elish-csot.dtb。"
    exit 0
fi
[ -f "$DTB_SYS" ] || echo "  WARN: 当前系统没有 $DTB_SYS（尚未安装联合 DTB？）"

WORK=$(mktemp -d /tmp/hi556-apply-XXXXXX)
NEW="$WORK/sm8250-xiaomi-elish-csot-hi556.dtb"

say "构建新 DTB（method=$METHOD stage=$STAGE）"
python3 "$TOOL" --base "$BASE" --out "$NEW" --method "$METHOD" --stage "$STAGE" \
        --verify-combined ${QUIET:+--quiet}
echo "  新 DTB : $NEW"
sha256sum "$NEW"
echo "  基线   : $BASE"
sha256sum "$BASE"

say "与基线差异（只增不丢）"
python3 "$TOOL" --check-only "$NEW" --base "$BASE" --stage "$STAGE" --quiet \
    && echo "  OK: 只包含计划内新增节点/属性，基线定制节点与 L10C 4 字节属性未变"

# ---------------------------------------------------------------- dry-run 输出
TS=$(date +%Y%m%d-%H%M%S)
BK="$BACKUP_ROOT/$TS"
if [ "$MODE" = dry-run ]; then
    cat <<EOF

===================== dry-run（未写任何文件）=====================
新 DTB 已构建并通过全部校验：$NEW

真正应用（需 sudo，写盘前自动备份）：
  sudo $0 --write-boot --stage $STAGE --method $METHOD

--write-boot 将执行：
  1) 备份现有 DTB -> $BK/
       $DTB_SYS
       $DTB_BOOT
  2) install 新 DTB 到上述两个路径
  3) bash $UPDATE_BOOT
       —— 先 verify-combined-dtb.sh 预检 + 校验 initramfs 不变量
       —— dd 备份 Linux 启动槽 $SLOT 到 /root/${SLOT}-backup-*.img
       —— 调 /etc/kernel/postinst.d/zz-update-abl-kernel 重建 armbian-kernel-csot.img
          （cat Image.gz + DTB -> mkbootimg -> 写 $SLOT）
       —— 回读 cmp 校验
  4) sudo reboot

重启后自检：
  dmesg | grep -iE 'hi556|cci|camss|csiphy' | head -40
  ls -l /sys/bus/i2c/devices/ | grep -E '21-0020|20-00'   # Hi556 在 cci0 i2c-bus@1
  media-ctl -p -d /dev/media0 | head -60
  v4l2-ctl --list-devices

回滚（任一情况：探测不到 / camss 起不来 / 前摄后摄异常）：
  sudo $0 --rollback --write-boot       # 恢复最近备份的 DTB 并重建启动槽
  # 或恢复 boot 分区镜像（update-boot-image.sh 的 /root/${SLOT}-backup-*.img）：
  sudo dd if=/root/${SLOT}-backup-<时间戳>.img of=/dev/disk/by-partlabel/${SLOT}
  sudo reboot

建议分阶段：
  stage1 = ldo2 + pinctrl + CCI0 传感器节点（不动 camss，风险仅限本 DTB 多出的节点）
  stage2 = 再连 camss port@0（Hi556 probe 失败会拖住 camss async notifier，影响前/后摄）
  先 stage1 确认 \`dmesg | grep hi556\` 出现 “hi556 21-0020” 且无 probe 错误，再 stage2。
=================================================================
EOF
    exit 0
fi

# ---------------------------------------------------------------- 实际写盘
[ "$(id -u)" -eq 0 ] || die "--write-boot 需要 root：sudo $0 --write-boot ..."
[ -f "$UPDATE_BOOT" ] || die "缺少 $UPDATE_BOOT"
[ -f "$DTB_SYS" ] || die "当前系统缺少 $DTB_SYS，拒绝继续（先按包 README 安装联合 DTB）"

say "1) 备份现有 DTB -> $BK"
mkdir -p "$BK"
install -m 0644 "$DTB_SYS" "$BK/sm8250-xiaomi-elish-csot.dtb"
[ -f "$DTB_BOOT" ] && install -m 0644 "$DTB_BOOT" "$BK/sm8250-xiaomi-elish-csot.dtb.boot"
cp -a "$NEW" "$BK/sm8250-xiaomi-elish-csot-hi556.dtb"
sha256sum "$BK"/* || true
[ "$ASSUME_YES" -eq 1 ] || {
    echo
    echo "即将写入 $DTB_SYS 和 $DTB_BOOT，并重建启动槽 $SLOT。"
    read -r -p "确认继续？输入 yes: " ans
    [ "$ans" = yes ] || die "用户取消"
}

say "2) 安装新 DTB"
install -D -m 0644 "$NEW" "$DTB_SYS"
install -D -m 0644 "$NEW" "$DTB_BOOT"
bash "$VERIFY" "$DTB_SYS"

say "3) 重建启动槽 $SLOT（update-boot-image.sh：备份 + 重建 + 回读校验）"
bash "$UPDATE_BOOT"

say "4) 完成"
cat <<EOF
已安装：$DTB_SYS
        $DTB_BOOT
已重建启动槽：$SLOT（回读已通过）
备份：$BK
      /root/${SLOT}-backup-*.img（boot 分区镜像，update-boot-image.sh 生成）

下一步：
  sudo reboot
  dmesg | grep -iE 'hi556|cci|camss|csiphy' | head -40
  ls -l /sys/bus/i2c/devices/ | grep 21-0020

回滚：
  sudo $0 --rollback --write-boot
EOF
