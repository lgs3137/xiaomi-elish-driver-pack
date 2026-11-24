# 统一内核构建（传感器 + 指纹 + GNSS + 相机）

本目录是**多项目共用的内核资产**。目标：只编译/安装**一次**内核，同时满足：

- 传感器：`/dev/fastrpc-sdsp` 出现、SLPI SDSP VMID `{3,5}` 分配成功、sensors PD 用 remote heap；
- 指纹：`/dev/tee0`、`/dev/teepriv0`、`/dev/goodix_fp`，QSEECOM/mdt_loader(qcom_scm) 可用，
  DTB 含 `/fingerprint` 节点（`firmware-name="gfenu"`）；
- GNSS：DTB 含 QUP5 UART（`i2c@994000` → `qcom,geni-uart`）与 `/bcm4775` 电源节点；
  `airoha_gps.ko` 是**独立模块**（无内核源码补丁），按 `../gnss/kernel/README.md` 另行编译安装；
- 相机：OV8856/OV13B10/CN3927V/Hi556 的驱动补丁与 DTS 节点（见 `../camera/README.md`）。

> 基线：Linux **6.18.44** + Armbian sm8250 补丁（获取方式见 `ARMBIAN-BASELINE.md`）+ 指纹内核文件 +
> 传感器/相机/充电补丁。目标内核版本必须仍是 `6.18.44-current-sm8250`（ABI/模块依赖）。
> 当前已部署 release 构建 **#22**（2026-11-22，release 配置，无 PM_DEBUG / DPM_WATCHDOG 等诊断项；含 0009 睡眠修复、0010–0013 PD 快充/分段充电、0014–0015 bq2597x 并联泵、0016 满电状态修复、0017 唤醒后电源键抑制）。

## 文件

| 路径 | 用途 |
|---|---|
| `qseecom/` | QSEECOM TEE 驱动（`drivers/tee/qseecom/`） |
| `mdt_loader.c` | 带 ELF64 支持的 `drivers/soc/qcom/mdt_loader.c` |
| `qcom_scm.c` | 含 `qcom_scm_qseecom_*` 的 `drivers/firmware/qcom/qcom_scm.c` |
| `goodix_fp_spi/` | 指纹传感器模块源码（out-of-tree 模块） |
| `config-used-6.18.44` | 实际编译配置（含 TEE/QSEECOM/BTF/BinderFS 等） |
| `ARMBIAN-BASELINE.md` | 如何获取 Armbian sm8250 基线（不随包提供完整补丁集） |
| `patches/0001-fastrpc-sdsp-vmid-and-sensors-pd.patch` | 传感器 fastrpc 两处修改 |
| `patches/0002-pinctrl-lpass-lpi-defer-on-clock-timeout.patch` | LPASS pinctrl 时钟超时 defer（pogo 键盘/USB，独立于传感器/指纹） |
| `patches/0003-qcom-mdt-loader-user-selectable.patch` | 让 QCOM_MDT_LOADER 用户可选（TEE_QSEECOM=y 依赖） |
| `patches/0004-smb5-typec-legacy-reset-resume.patch` | SMB5 suspend/resume 后 Type-C legacy/100mA 卡死修复（见 `CHARGER-RESUME.md`） |
| `patches/0005-ov8856-bggr-vflip.patch` | OV8856 2-lane 默认 BGGR + VFLIP（见 `../camera/README.md`） |
| `patches/0006-ov13b10-of-supplies-reset.patch` | OV13B10 OF match + avdd/dovdd/dvdd 供电 + reset 脉冲（节点已并入联合 DTB） |
| `patches/0007-cn3927v.patch` | OV13B10 后摄 CN3927V VCM 驱动（focus sysfs + DTS node） |
| `patches/0008-hi556-of.patch` | Hi556 景深 OF match + 非 ACPI power/identify（节点已并入联合 DTB，2026-11-20 实机 RAW 出流验证） |
| `patches/0009-fastrpc-listener-unfreezable.patch` | FastRPC listener 线程 `PF_NOFREEZE`：s2idle 期间继续应答 DSP，修复唤醒后 sensor PD `frpc_dsp` 崩溃（睡眠死机根因；2026-11-21 实测 20 次 s2idle（含 10h47m 长睡）0 崩溃，release #13 当日 4 次 0 崩溃） |
| `patches/0010-smb5-fast-charge-current-vbus.patch` | SMB5 快充电流：PD 9V（VBUS≥6.5V）时把 PMIC 默认 1.5A 的电池充电电流提高到 6A，5V 档保持 1.5A；实测 9V 输入下电池侧 ~3.8A ≈ 15W（2026-11-21） |
| `patches/0011-charger-taper-stepdown.patch` | 充电降档：检测到 VBAT 偏高/终止时对半降低充电电流（避免大电流提前触发 Full） |
| `patches/0012-charger-soc-step-charging.patch` | 按电量分段的 step-charging 曲线（6A/4A/2.5A/1.5A/1A/0.5A），高电量继续充、不早停 |
| `patches/0013-charger-ignore-fullon-flag.patch` | 忽略 `BATT_GT_FULL_ON` 正常标志，只对真正的 inhibit/terminate 降档 |
| `patches/0014-bq2597x-probe-typec-notifier.patch` | bq2597x（master/slave 并联充电器）probe 时 typec psy 可能尚未注册；改为后台每秒重试（≤120 次）、拿到后注册 notifier，并把 notifier 里 30s `msleep` 改成延迟工作队列（否则阻塞 power_supply 回调）；修复后 `present=1`、9V 下泵参与充电（2026-11-21） |
| `patches/0015-bq2597x-soc-gated-charging.patch` | 并联泵按电量门控：SoC ≥96% 时禁用泵（防满电过充），每 30s 复查，降到 96% 以下自动恢复；读不到 SoC 时保守关闭 |
| `patches/0016-bq27xxx-discharging-status.patch` | 电量计状态优先级：先看电流方向（放电→`DISCHARGING`），再看 `FC` 满电标志；修复 100% 拔线后仍显示 `Full`/充电图标的问题 |
| `patches/0017-pwrkey-post-resume-grace.patch` | 唤醒后电源键抑制：resume 完成后 `wake_ignore_ms`（默认 6000ms）内的电源键事件直接丢弃，避免 s2idle 恢复期间连按电源被 logind 当成反复 suspend（屏幕亮一下又灭）；参数可在 `/sys/module/pm8941_pwrkey/parameters/wake_ignore_ms` 实时调整 |
| `build-and-install.sh` | 一键：应用补丁/配置/编译/模块/DTB/initramfs hook/启动槽（调用 `update-boot-image.sh`） |
| `update-boot-image.sh` | 推荐：预检 DTB/initramfs + 备份目标 Linux 启动槽 + 重建 + 回读校验（自动检测） |
| `compat-check.sh` | 升级前只读兼容性检查：补丁 dry-run + 整文件副本 diff + 关键符号/DTS 检查 |
| `PINCTRL-LPASS.md` | 该补丁的症状/部署/initramfs 注意事项 |
| `CHARGER-RESUME.md` | SMB5 Type-C legacy/suspend 充电卡死修复与验证 |
| `include/` | 指纹驱动必需的 3 个内核头文件（qcom_scm.h / mdt_loader.h / tee.h） |
| `INTEGRATION.md` | 头文件与 drivers/tee Kconfig/Makefile 集成步骤（从零构建必需） |
| `patches/fingerprint/qseecom-tee-series.patch` | **权威完整 QSEECOM 系列补丁**（14 文件，含 docs/Kconfig/Makefile/头文件） |
| `boot/` | 系统 `zz-update-abl-kernel` 副本（参考）；统一用 `update-boot-image.sh` |
| `integration/` | DTS vmids 片段（完整基线重建参考） |
| `initramfs/` | 修复版 initramfs hook（防止 SLPI 固件被打进 initramfs）+ 安装脚本 |
| `dtb/sm8250-xiaomi-elish-csot.dtb` | 已验证的模型级联合 DTB（含传感器/指纹/GNSS/相机与 Hi556；不要用树内 DTS 重编，见 `dtb/README.md`） |
| `patches/fastrpc.c.modified` | 已打补丁的完整 fastrpc.c（对照用） |
| `dtb/` | 联合 DTB 说明、指纹节点参考、校验脚本 |

## 步骤 A：在现有 Armbian 构建树上增量构建（推荐）

本机/原项目使用 `/var/tmp/kbuild-src`（6.18.44 + Armbian 补丁）。从零可用步骤 B。

```bash
cd /var/tmp/kbuild-src
# 0) 指纹头文件 + 集成点（缺了会编译失败，见 INTEGRATION.md）
cp <本包>/kernel/include/linux/firmware/qcom/qcom_scm.h include/linux/firmware/qcom/qcom_scm.h
cp <本包>/kernel/include/linux/soc/qcom/mdt_loader.h   include/linux/soc/qcom/mdt_loader.h
cp <本包>/kernel/include/uapi/linux/tee.h              include/uapi/linux/tee.h
grep -q 'drivers/tee/qseecom/Kconfig' drivers/tee/Kconfig || printf '\nsource "drivers/tee/qseecom/Kconfig"\n' >> drivers/tee/Kconfig
grep -q 'CONFIG_TEE_QSEECOM' drivers/tee/Makefile || printf 'obj-$(CONFIG_TEE_QSEECOM) += qseecom/\n' >> drivers/tee/Makefile
# 1) 指纹内核文件
cp -a <本包>/kernel/qseecom drivers/tee/qseecom
cp -a <本包>/kernel/mdt_loader.c drivers/soc/qcom/mdt_loader.c
cp -a <本包>/kernel/qcom_scm.c drivers/firmware/qcom/qcom_scm.c
# 确认 drivers/tee/Kconfig 末尾有 source "drivers/tee/qseecom/Kconfig"
# 确认 drivers/tee/Makefile 有 obj-$(CONFIG_TEE_QSEECOM) += qseecom/
# 2) 传感器/相机/充电补丁（独立文件，互不影响）
patch -p1 < <本包>/kernel/patches/0001-fastrpc-sdsp-vmid-and-sensors-pd.patch
patch -p1 < <本包>/kernel/patches/0002-pinctrl-lpass-lpi-defer-on-clock-timeout.patch
patch -p1 < <本包>/kernel/patches/0004-smb5-typec-legacy-reset-resume.patch
patch -p1 < <本包>/kernel/patches/0005-ov8856-bggr-vflip.patch
patch -p1 < <本包>/kernel/patches/0006-ov13b10-of-supplies-reset.patch
patch -p1 < <本包>/kernel/patches/0007-cn3927v.patch
patch -p1 < <本包>/kernel/patches/0008-hi556-of.patch
patch -p1 < <本包>/kernel/patches/0009-fastrpc-listener-unfreezable.patch
patch -p1 < <本包>/kernel/patches/0010-smb5-fast-charge-current-vbus.patch
patch -p1 < <本包>/kernel/patches/0011-charger-taper-stepdown.patch
patch -p1 < <本包>/kernel/patches/0012-charger-soc-step-charging.patch
patch -p1 < <本包>/kernel/patches/0013-charger-ignore-fullon-flag.patch
patch -p1 < <本包>/kernel/patches/0014-bq2597x-probe-typec-notifier.patch
patch -p1 < <本包>/kernel/patches/0015-bq2597x-soc-gated-charging.patch
patch -p1 < <本包>/kernel/patches/0016-bq27xxx-discharging-status.patch
patch -p1 < <本包>/kernel/patches/0017-pwrkey-post-resume-grace.patch
# 补丁状态判定（增量树常见“上下文漂移”）：正向 dry-run → 反向 dry-run → 新增行内容命中（≥70%）。
# 0010/0011/0014 在已演进的树里正反向都失败，但内容已并入，会显示“已应用（上下文漂移）”。
# 3) 让 QCOM_MDT_LOADER 用户可选（若树内 Kconfig 仍是裸 tristate）
grep -q 'tristate "Qualcomm MDT firmware loader"' drivers/soc/qcom/Kconfig || \
  patch -p1 < <本包>/kernel/patches/0003-qcom-mdt-loader-user-selectable.patch
# 4) 配置
cp <本包>/kernel/config-used-6.18.44 .config
make ARCH=arm64 olddefconfig
# 5) 必须恢复 q6v5_pas 的 auto_boot=true（见下）
# 6) 编译
make ARCH=arm64 -j$(nproc) Image
make ARCH=arm64 -j$(nproc) modules
```

### ⚠️ qcom_q6v5_pas 的 auto_boot

早期实验曾把 `sdm845_slpi_resource_init.auto_boot` 改成 `false`，构建树里可能仍有残留。
**全量 `make modules`/`modules_install` 前必须改回 upstream `true`**（sm8250 SLPI 复用该结构）：

```bash
grep -n -A3 'sdm845_slpi_resource_init = {' drivers/remoteproc/qcom_q6v5_pas.c
# 期望 .auto_boot = true
sed -i '/sdm845_slpi_resource_init = {/,/};/ s/\.auto_boot = false/.auto_boot = true/' \
  drivers/remoteproc/qcom_q6v5_pas.c
```

原因：本方案靠"开机时固件路径悬空 → 内核不 auto_boot → 服务先起监听器、再放固件启动 SLPI"，
固件不变量保证开机时没有可加载固件。`auto_boot=false` 只影响内核开机自动启动（用户态写
`state=start` 仍可启动 SLPI），但本机安装的 stock 模块是 `true`，实验性的 `false` 会与 stock
行为不一致、易混淆，所以**必须恢复 upstream `true`**。

## 步骤 B：从零重建基线

1. 下载 Linux 6.18.44 源码（sha256 参考 `../VERSIONS.md`）。
2. 按 `ARMBIAN-BASELINE.md` 获取 Armbian sm8250 补丁集并应用到 6.18.44。
3. 复制本目录 `config-used-6.18.44` 为 `.config`，`make ARCH=arm64 olddefconfig`。
4. 按步骤 A 的 0–3 步加入指纹文件与各补丁，并恢复 `auto_boot=true`。
5. 编译 Image + modules。

## 配置检查（必须）

```bash
grep -E 'CONFIG_TEE=|CONFIG_TEE_QSEECOM=|CONFIG_QCOM_QSEECOM=|CONFIG_QCOM_MDT_LOADER=|\
CONFIG_QCOM_FASTRPC=|CONFIG_DEBUG_INFO_BTF=|CONFIG_MODULE_ALLOW_BTF_MISMATCH=|\
CONFIG_ANDROID_BINDERFS=|CONFIG_LOCALVERSION=' .config
```

期望：`TEE=y`、`TEE_QSEECOM=y`、`QCOM_QSEECOM=y`、`QCOM_MDT_LOADER=y`、`QCOM_FASTRPC=m`、
`DEBUG_INFO_BTF=y`、`MODULE_ALLOW_BTF_MISMATCH=y`、`ANDROID_BINDERFS=y`、`LOCALVERSION="-current-sm8250"`。
BTF 编译需要 ≥4GB swap。

## Waydroid / Android 容器（binderfs，2026-11-24）

本包内核启用 `CONFIG_ANDROID_BINDERFS=y`，供 Waydroid 使用。Waydroid 是 **LXC 容器**（不是虚拟机）：
它共享本内核、直接执行原生 arm64 代码，唯一的内核前置就是 binder（binderfs）。不装 Waydroid 时该选项
无副作用（见下面的节点行为变化）。

> **行为变化**：开 binderfs 后 `drivers/android/binder.c` 不再在启动时创建静态 `/dev/binder`、
> `/dev/hwbinder`、`/dev/vndbinder`（该逻辑只在未开 binderfs 时执行）。本包各组件都不依赖这些节点；
> Waydroid 启动时会自己 `mount -t binder binder /dev/binderfs`，再用 `binder-control` 创建设备。

验证（当前运行内核，需 root）：

```bash
zcat /proc/config.gz | grep '^CONFIG_ANDROID_BINDERFS='        # 期望 =y
sudo sh -c 'mkdir -p /dev/binderfs && mount -t binder binder /dev/binderfs && ls /dev/binderfs'
# 期望看到 binder-control（binderfs 的控制节点）
```

Waydroid 本体与 Android 镜像**不随包提供**（需自行装 `waydroid` 包 + arm64 GSI）；本包只负责内核前置。


## ABI 三件套（不满足会黑屏/模块全拒）

```bash
strings vmlinux | grep mod_unload      # 6.18.44-current-sm8250 SMP mod_unload aarch64
pahole -C module vmlinux | grep 'size:'   # 期望 size: 1280
pahole -C module /sys/kernel/btf/vmlinux | grep 'size:'  # 运行内核同值才兼容
grep -E 'CONFIG_DEBUG_INFO_BTF=|CONFIG_MODULE_ALLOW_BTF_MISMATCH=' .config   # 都是 y
```

## 模块安装（内核侧要点）

模块、DTB、initramfs 与启动槽的安装步骤与根 `../INSTALL.md`（§3）配合；内核侧必须注意：

- `fastrpc.ko` 是 in-tree 模块，必须与运行内核同版本源码树编出（ABI 绑定）；替换前先备份
  `/lib/modules/$(uname -r)/kernel/drivers/misc/fastrpc.ko`。
- `goodix_fp_spi.ko` 是 out-of-tree 模块：在 `goodix_fp_spi/` 下
  `make -C <源码树> M=$PWD ARCH=arm64 modules`，装到 `/lib/modules/$(uname -r)/extra/`，
  写 `/etc/modules-load.d/goodix-fp.conf`，再 `sudo depmod -a`。
- 若改动了 initramfs 内模块（如 `pinctrl-lpass-lpi`）或 initramfs hook，必须先
  `sudo update-initramfs -u -k $(uname -r)`，再用 `update-boot-image.sh` 重建启动镜像。

## 联合 DTB（传感器 vmids + 指纹节点 + GNSS + 相机）

统一 DTB 必须同时具备：

- SLPI `glink-edge/fastrpc` 节点：`qcom,vmids = <3 15 5 6>`；
- GNSS：`i2c@994000` 改 `qcom,geni-uart`/`okay`、`qup-uart5-default-state`、根 `/bcm4775`
  （`gps-ldo`、PMIC `gps-clk-default`、`gps-enable-active/suspend`）；
- 根节点 `/fingerprint`：`compatible = "goodix,gf3626"`、`firmware-name = "gfenu"`、
  `interrupts = <23 1>`、`reset-gpios = <&tlmm 125 GPIO_ACTIVE_LOW>`、`vdd-supply`（PM8150A L10A 3.008V）、
  pinctrl（IRQ gpio23）；
- 相机：前摄 OV8856/PM8008、后摄 OV13B10/CN3927V、Hi556 景深节点（详见 `dtb/README.md`）。

**本包附带一份已验证的模型级联合 DTB（已合并 Hi556）**：`kernel/dtb/sm8250-xiaomi-elish-csot.dtb`
（sha256 `0d639355650ad34ef3a03ed6af44f4fd2e1ec287aadd543a7c707238f8b544e8`，139,091 B）。只装 DTB（不重编内核）：

```bash
sudo ./kernel/install-dtb.sh                # 更新 rootfs/boot 下的 DTB
sudo ./kernel/install-dtb.sh --write-boot   # 另重建 Linux 启动槽（自动检测、备份、回读校验）
```

**⚠️ 不要用 `/var/tmp/kbuild-src` 的 DTS 直接重编 DTB**：该树的 DTS 不是当前 DTB 的完整源，
用树内 DTS 重编会丢 17 个节点/109 个属性（包括 `/reserved-memory/fastrpc` 的 32MB shared-dma-pool、
fastrpc 的 memory-region、`/gpio-keys` 的 lid/tablet-mode、panel/ts pinctrl、uart16、haptics、
regulator@88e7000 等），且树内只有 vmids、没有指纹与相机节点。若必须从源码重建，先取得
**Armbian db44df750 的完整 sm8250 源码**并补齐这些节点，再逐属性 `dtc` diff 验证。

校验：

```bash
./dtb/verify-combined-dtb.sh /usr/lib/linux-image-$(uname -r)/qcom/sm8250-xiaomi-elish-csot.dtb
# 期望：vmids=3 f 5 6；/fingerprint firmware-name=gfenu、compatible=goodix,gf3626
```

## initramfs（必须先修 hook）与启动镜像

### initramfs 固件不变量

Armbian 原始 hook `/etc/initramfs-tools/hooks/xiaomi-elish-firmware` 会对
`/lib/firmware/.../elish/*` 全部 `add_firmware`，**跟随 `slpi.mbn` 符号链接**把 7.6MB 真固件打进
initramfs（当前系统已如此）。这会让内核可能 boot 早期 auto_boot SLPI → 传感器失效。
本包提供修复版：

```bash
sudo ./kernel/initramfs/install-hook.sh    # 备份原 hook、安装修复版、update-initramfs -u
# 验证：lsinitramfs /boot/initrd.img-$(uname -r) | grep slpi   → 应无输出
```

注意：Armbian BSP 包升级可能覆盖该 hook；升级后需重装本 hook。

### 重建启动镜像并写入 Linux 启动槽

本包**不写死 `boot_b`**：槽位取 `/boot/armbianEnv.txt` 的 `abl_boot_partition_label`
（本机 `boot_b`；不同安装可能是 `boot_a` 或其他）。未设置时脚本拒绝执行；`--slot` 仅作断言。

推荐使用本包的安全封装（预检 DTB/initramfs、备份目标 Linux 启动槽、调系统 hook、回读 cmp）：

```bash
sudo ./kernel/update-boot-image.sh --dry-run   # 只预检/备份，不写盘（当前 initramfs 未修复时会在此失败）
sudo ./kernel/update-boot-image.sh             # 预检 → 备份 → zz-update-abl-kernel → 回读校验
```

`kernel/install-new-kernel.sh` 属**历史脚本，不推荐使用**：它从旧启动镜像里提取 ramdisk、硬编码
`slot_suffix=_b/splash quiet`，在 initramfs 已更新后会使用旧 ramdisk。

## 重启后验证（内核层）

```bash
dmesg -k | grep -iE 'qseecom|tee|goodix|SDSP assign|remoteproc2.*slpi'
# 指纹：found qseecom with version 0x1402000；loaded 'gfenu' 稍后由 loader 打
# 传感器：SDSP assign try [0]: 0；不出现 all SDSP assign attempts failed
ls -l /dev/tee0 /dev/teepriv0 /dev/goodix_fp
cat /sys/devices/platform/fingerprint/firmware_name       # gfenu
lsmod | grep -E 'fastrpc|goodix_fp_spi'
```

之后按 `../sensors/INSTALL.md` 安装传感器用户态、`../fingerprint/INSTALL.md` 安装指纹用户态。

## 升级警告

任何 `apt` 内核/DTB 升级都会覆盖本目录的全部改动并重建 Linux 启动槽（`zz-update-abl-kernel` 用**包内 DTB**；槽位由 armbianEnv 决定）。
升级后必须按本页重做内核 + 联合 DTB + boot 镜像，否则传感器/指纹同时失效。详见根 `../docs/UPGRADE-IMPACT-ALL.md`。
