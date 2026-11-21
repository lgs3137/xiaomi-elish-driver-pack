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

### 8. SMB5 快充电流（`kernel/patches/0010-smb5-fast-charge-current-vbus.patch`，2026-11-21）

`qcom_pm8150b_charger.c`：PMIC 上电默认的 `FAST_CHARGE_CURRENT_CFG` 只有 1.5A，Linux 驱动从未设置它，
导致 PD 9V 也只按 5V 档慢充。补丁在 USB 插入 / PD 协商 / AICL 变化时读取 VBUS：

- VBUS ≥ 6.5V（PD 9V 档）→ 电池充电电流设 6A；5V 档保持 1.5A；拔线恢复默认；
- VBUS 读数为 0 时保持不变（避免 APSD/PD 重协商瞬态误降档）。

实测（2026-11-21，release #15，PD 9V/PPS 充电器，64–66% 电量）：电池侧 3.7–3.8A ≈ **15W**
（修复前 1.36A ≈ 5.4W），VBUS 8.73–8.75V，AICL 3.3A，电池温度 ≤40°C，无回退/抖动。
更高档位（bq2597x 电荷泵并联、27W）仍待后续。

### 9. 分段充电曲线与提前 Full 修复（0011–0013，2026-11-21）

- **问题**：SMB5 用自己测的 VBAT 判满；6A 大电流下 IR 压降让它在真实电量 ~83% 时就 `TERMINATE_CHARGE`
  （用户看到 "Full" 停充），且之后不自动回充。
- `0011-charger-taper-stepdown.patch`：每 10 秒读充电状态寄存器，一旦出现 VBAT 偏高/终止就把充电电流对半降档，
  让充电继续（第一版一次验过：83% → 87%）。
- `0012-charger-soc-step-charging.patch`：改为按电量分段的 step-charging 曲线（读 `bq27z561` 的 `capacity`）：
  <70% 6A、70–80% 4A、80–88% 2.5A、88–93% 1.5A、93–97% 1A、≥97% 0.5A；保留“仍偏高再对半”保护。
- `0013-charger-ignore-fullon-flag.patch`：`BATT_GT_FULL_ON` 是接近满电的正常模式标志，之前被误判为异常，
  导致 89% 时被一路降到 0.5A；现在只有真正的 `VBATT_GTET_INHIBIT / TERMINATE / INHIBIT` 才降档。
- 实测（release #18）：9V 档 6A 起步；89–92% 按曲线降到 1.5A/0.75A，**不再提前报 Full**，电量继续上升。

### 9b. bq2597x 并联快充（0014–0015，2026-11-21）

- **背景**：本机有双 `bq2597x` 并联充电器（master/slave，9V 下与 SMB5 一起给 1S2P 电池充电）；
  mainline 内核里它们 `present=0`，从未参与充电。
- `0014`：probe 时 `tcpm-source-psy` 可能还没注册（只查一次就永久失败）→ 后台每秒重试、拿到后注册 notifier；
  同时 notifier 里的 `msleep(30000)` 改为 delayed work，避免阻塞；修复后 `bq2597x-master/slave present=1`，
  9V 固定档下电池侧从 ~15W 提到 **~18–20W**。
- `0015`：按 SoC 门控泵（≥96% 关闭、<96% 恢复、每 30s 复查，读不到 SoC 保守关闭），避免满电继续灌。
- **PPS keep-alive（2026-11-21 晚）**：给 DTB 的 sink PDO 增加 PPS APDO（3.3–11V/5A）后，
  本机 100W PD 头会在 PPS 契约建立约 **13 秒**后主动发 Hard Reset（TCPM `Received hard reset`）。
  实测这是充电头的 PPS 看门狗：**每 ≤8 秒重发一次当前 PPS 请求**即可稳定保持（11V 连续 2 分钟零复位），
  但每次重协商后要重设 SMB5 输入限流（ICL=3A），否则充电会慢慢掉到系统负载。
  受控服务 `pps-charger/` 已实现 keep-alive，可选安装（`--with-pps-charger`），50–56% 电量下
  11V 电池侧 ~20.5W（固定 9V 约 18.9W，+8%），短测 11V/4A 可到 23.5W+，41.5°C 回退固定档。

### 9c. 满电拔线仍显示充电（0016，2026-11-21）

- **现象**：充到 100% 后拔掉充电器，电池状态仍报 `Full`，桌面/UPower 显示“已充满/充电中”，
  实际电流已经为负（在放电）。
- **根因**：`bq27xxx_battery` 先判断 `FC`（满电）标志、后看电流方向；`FC` 在满电后会锁存一段时间，
  不会立刻随拔线清除。
- **修复**：`0016-bq27xxx-discharging-status.patch` 把电流方向放到最前——`curr < 0` 直接报
  `DISCHARGING`，其余情况再按 `FC`/正电流/零电流判断；充电到 100% 时仍正常显示 `FULL`。

### 9d. 唤醒后电源键抑制（0017，2026-11-22）

- **问题**：s2idle 唤醒要 2–6 秒（触屏重下固件、传感器 iio claim、音频 DSP），用户以为没醒，
  连按电源键；logind 把每一次都当成 suspend 切换 → 屏幕亮一下又灭、反复进出睡眠。
- **修复**：PMIC 电源键驱动 `pm8941-pwrkey` 在 resume 时记录 `wake_ignore_ms`（默认 6000ms），
  IRQ 里丢弃该窗口内的电源键事件；logind 收不到按键就不会再 suspend。PMIC 长按强制断电不受影响。
- **实测**：唤醒后 6 秒内的连按不再触发 suspend；9 秒后按电源正常睡眠。参数可实时写
  `/sys/module/pm8941_pwrkey/parameters/wake_ignore_ms`（0 关闭）。

### 10. 内核集成与 initramfs hook（不是驱动补丁，但缺了会编译失败/破坏不变量）

- `kernel/include/` 3 个头文件 + `kernel/INTEGRATION.md`：qcom_scm.h / mdt_loader.h / tee.h，
  以及 drivers/tee Kconfig/Makefile 集成点、QCOM_MDT_LOADER 依赖；
- `kernel/initramfs/hooks/xiaomi-elish-firmware`：修复版 hook，跳过 `slpi.mbn` 符号链接/`.disabled`，
  防止真固件被打进 initramfs。

### 11. DTB（非补丁，配置改动）

- 传感器：`qcom,vmids = <3 15 5 6>`（SLPI fastrpc 节点）+ fastrpc reserved-memory/remote heap；
- 指纹：`/fingerprint` 节点（`compatible="goodix,gf3626"`、`firmware-name="gfenu"`、
  `interrupts=<23 1>`、`reset-gpios=<&tlmm 125 GPIO_ACTIVE_LOW>`、L10A 3.008V、pinctrl IRQ）；
- GNSS：`/soc@0/geniqup@9c0000/i2c@994000` 改为 `qcom,geni-uart` + `status=okay`
  （`pinctrl-0` = `qup-uart5-default-state`，gpio12–15）；根 `/bcm4775`（`gps-ldo`、PMIC
  `gps-clk-default`、`gps-enable-active/suspend`）；
- 相机：OV8856/PM8008/CAMSS 节点 + 后摄 OV13B10/CN3927V + Hi556（`ldoc2`/`cci0`/`csiphy0`/MCLK1/GPIO26，
  2026-11-20 合并）；
- USB-C：sink PDO 增加 PPS APDO（3.3–11V/5A，`0xc0dc2164`），保留 5V/3A 固定与 5–9V/3A 可变 PDO；
- 已验证联合 DTB 随包：`kernel/dtb/sm8250-xiaomi-elish-csot.dtb`
  （sha256 `d7840b30c36290e6735d6bf96605929304e16c199a510b373782589b64234354`，2026-11-21 晚加 PPS）；
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
