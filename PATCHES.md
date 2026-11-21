# 补丁与配置修改总清单（合并包）

本包所有代码修改以补丁/源码文件形式提供；**不含编译产物、固件**。
状态基线：2026-11-21（release 内核 #13）。历史演进见 `docs/HISTORY.md`。

## 一、内核（多项目共用一次构建，详见 `kernel/README.md`）

### 1. 传感器 fastrpc（`kernel/patches/0001-fastrpc-sdsp-vmid-and-sensors-pd.patch`）

- 基准：Linux v6.18.44 pristine `drivers/misc/fastrpc.c`
- hunk 1：`fastrpc_get_args()` 中 `if (ctx->fl->sctx->sid && ctx->fl->pd != SENSORS_PD)`
  → sensors PD 强制 remote heap，避免 SMMU context fault；
- hunk 2：`fastrpc_rpmsg_probe()` SDSP 分支增加 VMID 候选表
  `{3,5}` 优先（`SDSP assign try [%u]: %d`），全失败 `dev_warn` 继续。
- 完整修改版：`kernel/patches/fastrpc.c.modified`。

### 2. 指纹内核文件（相对 6.18.44 + Armbian 补丁）

| 文件 | 修改 | 安装位置 |
|---|---|---|
| `kernel/qseecom/` | 新增 QSEECOM TEE 驱动（`core.c/Kconfig/Makefile`） | `drivers/tee/qseecom/`（含 Kconfig/Makefile 集成） |
| `kernel/mdt_loader.c` | 增加 ELF64 支持（`fingerpr` 用；`gfenu` 是 ELF32） | `drivers/soc/qcom/mdt_loader.c` |
| `kernel/qcom_scm.c` | 增加 `qcom_scm_qseecom_app_get_id/app_load/app_unload` 与响应解析 | `drivers/firmware/qcom/qcom_scm.c` |
| `kernel/goodix_fp_spi/` | Goodix GF3626 SPI 传感器驱动（out-of-tree 模块） | 编译为 `goodix_fp_spi.ko` |
| `kernel/config-used-6.18.44` | 实际编译配置（TEE/QSEECOM/MDT/BTF/FASTRPC 等） | 内核 `.config` |
| `kernel/ARMBIAN-BASELINE.md` | 如何获取 Armbian sm8250 基线 | — |

权威完整系列为 `kernel/patches/fingerprint/qseecom-tee-series.patch`（14 文件：驱动、Kconfig/Makefile、
`qcom_scm.c`/`mdt_loader.c`、3 个头文件、Documentation/MAINTAINERS）。从零重建时优先应用此补丁；
包内同时提供逐文件副本。

### 3. LPASS pinctrl（`kernel/patches/0002-pinctrl-lpass-lpi-defer-on-clock-timeout.patch`）

`pinctrl-lpass-lpi.c`（1 hunk）：`-ETIMEDOUT/-EAGAIN/-EBUSY` 返回 `-EPROBE_DEFER`，修 pogo 键盘/USB
随机失效。部署需 `update-initramfs` + 重建 boot 镜像；详见 `kernel/PINCTRL-LPASS.md`。

### 4. QCOM_MDT_LOADER 用户可选（`kernel/patches/0003-qcom-mdt-loader-user-selectable.patch`）

pristine 6.18.44 的 `QCOM_MDT_LOADER` 是裸 `tristate`（无 prompt），会被 `QCOM_Q6V5_PAS=m` select 成 m，
而 `TEE_QSEECOM=y` 依赖它 → 改为用户可选并显式 `=y`。

### 5. SMB5 充电 resume（`kernel/patches/0004-smb5-typec-legacy-reset-resume.patch`）

`qcom_pm8150b_charger.c`：resume 后复位 Type-C legacy 状态并重跑 APSD/AICL，修 suspend/resume 后
`power_role=source` / 100 mA 卡死。带充电器 3 轮验证；详见 `kernel/CHARGER-RESUME.md`。

### 6. 相机传感器驱动补丁

| 补丁 | 内容 |
|---|---|
| `0005-ov8856-bggr-vflip.patch` | OV8856 2-lane 默认 BGGR + VFLIP（注意：前摄 3280×2464 必须显式 `vflip=0`，否则无帧；elish-camera 已处理） |
| `0006-ov13b10-of-supplies-reset.patch` | OV13B10 OF match + avdd/dovdd/dvdd 供电 + reset 脉冲 |
| `0007-cn3927v.patch` | CN3927V VCM 驱动（`focus` sysfs + DTS node），后摄软件 AF |
| `0008-hi556-of.patch` | Hi556 OF match + 非 ACPI power/identify |

### 7. 睡眠死机修复（`kernel/patches/0009-fastrpc-listener-unfreezable.patch`，2026-11-21）

~18 行，仅 `drivers/misc/fastrpc.c`：把 FastRPC reverse-tunnel listener 线程（handle 3）标记
`PF_NOFREEZE`，使其在 s2idle 期间不被 system-suspend freezer 冻结，继续应答 DSP 侧文件服务请求；
否则唤醒时 SLPI `sensor_process` PD 的 `frpc_dsp` 请求超时 → PD 崩溃 → rproc recovery，偶发 recovery
的 `qcom_scm_pas_shutdown` 卡在 EL3 → 全系统卡死（“睡死”）。

验证：打补丁内核自 2026-11-19 起共 **20 次 s2idle**（含 10h47m、5h50m 长睡）**0 次** PDM/fatal/crash；
release 配置 #13 当日 4 次 s2idle 0 崩溃；`suspend_stats` success=4 fail=0。详见 `docs/HISTORY.md`。

### 8. 内核集成与 initramfs hook（不是驱动补丁，但缺了会编译失败/破坏不变量）

- `kernel/include/` 3 个头文件 + `kernel/INTEGRATION.md`：qcom_scm.h / mdt_loader.h / tee.h，
  以及 drivers/tee Kconfig/Makefile 集成点、QCOM_MDT_LOADER 依赖；
- `kernel/initramfs/hooks/xiaomi-elish-firmware`：修复版 hook，跳过 `slpi.mbn` 符号链接/`.disabled`，
  防止真固件被打进 initramfs。

### 9. DTB（非补丁，配置改动）

- 传感器：`qcom,vmids = <3 15 5 6>`（SLPI fastrpc 节点）+ fastrpc reserved-memory/remote heap；
- 指纹：`/fingerprint` 节点（`compatible="goodix,gf3626"`、`firmware-name="gfenu"`、
  `interrupts=<23 1>`、`reset-gpios=<&tlmm 125 GPIO_ACTIVE_LOW>`、L10A 3.008V、pinctrl IRQ）；
- GNSS：`/soc@0/geniqup@9c0000/i2c@994000` 改为 `qcom,geni-uart` + `status=okay`
  （`pinctrl-0` = `qup-uart5-default-state`，gpio12–15）；根 `/bcm4775`（`gps-ldo`、PMIC
  `gps-clk-default`、`gps-enable-active/suspend`）；
- 相机：OV8856/PM8008/CAMSS 节点 + 后摄 OV13B10/CN3927V + Hi556（`ldoc2`/`cci0`/`csiphy0`/MCLK1/GPIO26，
  2026-11-20 合并）；
- 已验证联合 DTB 随包：`kernel/dtb/sm8250-xiaomi-elish-csot.dtb`
  （sha256 `0d639355650ad34ef3a03ed6af44f4fd2e1ec287aadd543a7c707238f8b544e8`）；
- 不要用当前树 DTS 重建（会丢 17 节点/109 属性）；dtc 往返破坏的是 **L10C（regulators-1/ldo10）**，
  不是 L10A。详见 `kernel/dtb/README.md` 与 `NOTES.md`。

## 二、用户态补丁

| 补丁 | 位置 | 内容 |
|---|---|---|
| hexagonrpc v0.3.2 warm-attach | `sensors/userspace/hexrpc/patches/0001-hexrpc-0.3.2-warm-attach.patch` | `HEXAGONRPC_WARM_ATTACH=1` 时 warm open 重试；attach `EPERM` 50µs 重试 |
| hexagonrpc M2 可写 registry | `sensors/userspace/hexrpc/patches/`（0002/0003/0004/0005 等） | 可写 persist + `sns_reg_version` 映射，PD registry 初始化 35 s→8.2 s |
| iio-sensor-proxy 三处 | `sensors/userspace/iio-sensor-proxy/patches/0001-iio-sensor-proxy-hotplug-stayalive.patch` | claim→polling、无传感器常驻、无条件连接 uevent |
| libfprint goodixqsee 日志 | `fingerprint/src/libfprint/patches/libfprint-goodixqsee-logging.patch` | `bring_up()`/worker 失败日志（TA 看门狗依赖） |

## 三、GNSS 新增代码（不是对现有驱动的 patch）

本机 AG3335 无主线驱动，GNSS 由本包新增的源码/配置实现：

- `gnss/kernel/airoha_gps_driver.c`：从 Android 下游移植的电源/时钟/pinctrl 控制模块；
- `gnss/userspace/airoha-gnssd.c`：用户态守护进程（上电 + PAIR 运行时初始化 + NMEA→pty + 自愈）；
- `gnss/userspace/gps-nmea-share.c`：gpsd NMEA → GeoClue2 network-nmea socket；
- `gnss/systemd/`：`airoha-gnssd.service` + `gps-nmea-share.service` + gpsd/GeoClue drop-in；
  `gnss/install/install.sh` 负责安装。

## 四、系统配置改动（随包文件，不是源码补丁）

| 类别 | 内容 |
|---|---|
| 传感器 | `sensors/systemd/`（slpi-sensors、slpi-fw-guard、sensor-boot-report、iio drop-in、udev ×3、休眠钩子、tuning、D-Bus） |
| 指纹 | `fingerprint/system/`（pam.d/sudo 指纹栈（可选安装）、qsee-supplicant/loader/看门狗 unit、fprintd drop-in、udev、弹窗脚本） |
| 内核集成 | `drivers/tee/Kconfig`/`Makefile` 集成点；`CONFIG_LOCALVERSION`/BTF 保持；`q6v5_pas auto_boot=true` 恢复 |
| GNSS | `gnss/systemd/`、`/etc/default/gpsd`（`DEVICES=/dev/ttyGNSS0`）、`/etc/modules-load.d/airoha-gps.conf` |
| 闪光灯 | `flash-led/`（wrapper + systemd drop-in；不改 Armbian 包文件） |
| 手电筒（可选） | `torch/`（GNOME 46 扩展 + CLI；走 logind） |
| 相机 | `camera/system/`、udev（VCM/DMA heap）、v4l2loopback 配置、autostart、休眠恢复 |

## 五、应用校验

- 内核补丁：对 pristine v6.18.44 `patch -p1 --dry-run` 通过；升级前可用 `kernel/compat-check.sh` 只读预演；
- hexrpc/iio 补丁：对 v0.3.2 / `ca0d5b0` 通过；
- 指纹内核文件为整文件替换/新增，需按 `kernel/README.md` 放入源码树后编译验证（ABI 三件套）；
- GNSS：`kernel/dtb/verify-combined-dtb.sh`（节点）+ `gnss/install/verify.sh`（设备/服务/NMEA/gpsd）；
- 合并自检 `install/check-all.sh` 已包含以上各项。
