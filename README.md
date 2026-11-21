# Xiaomi Mi Pad 5 Pro（elish）— Linux 合并驱动包<br>传感器 · 指纹 · GNSS · 相机

[English](README.en.md)

在 **Xiaomi Mi Pad 5 Pro**（Qualcomm **SM8250 / elish**，CSOT 面板，WiFi 版）上，把 Armbian Linux 的
**传感器（SLPI/SSC）**、**指纹（Goodix GF3626）**、**GNSS（Airoha AG3335）**、**相机（OV8856 / OV13B10 / Hi556）**
四套功能合并为一个**可重复安装的驱动/系统集成包**：共享同一内核、DTB 与 boot 镜像，提供**一键安装器**、
单组件安装脚本、设备数据提取指南与完整文档。

- **版本**：2026.11.21
- **适用设备**：Xiaomi Mi Pad 5 Pro（elish，CSOT 面板，WiFi 版）
- **适用系统**：Armbian 26.8.14（Ubuntu 24.04 noble）+ kernel `6.18.44-current-sm8250`
- **许可**：本包原创部分 **MIT**（见 `LICENSE`）；上游代码/补丁保留各自许可证（见文末）

> **打包约定**：本包只含**代码、补丁、系统配置、脚本与文档**；**不含**固件、设备数据、日志、
> 指纹模板、密钥/序列号、PAM/sudoers 备份，也不含**预编译用户态二进制**。
> 唯一附带的二进制是**模型级联合 DTB**（无本机私有信息，原因见 `kernel/dtb/README.md`）。
> 厂商数据/固件用 `docs/DEVICE-DATA-EXTRACTION.md` 从**你自己的设备/官方发行包**提取。

---

## 目录

- [支持状态一览](#支持状态一览)
- [适用系统版本](#适用系统版本)
- [实测结果](#实测结果2026-11-21本机同一台设备)
- [包内组件](#包内组件)
- [安装](#安装)
- [构建](#构建)
- [验证](#验证)
- [已知限制](#已知限制)
- [Credit / 上游代码](#credit--上游代码)
- [开源协议](#开源协议mit)

---

## 支持状态一览

> ✅ 完美运行（当前可用、已实测） · ⚠️ 基本运行（可用但有已知限制） · 🚫 受限/未完成 · — 本机不存在

| 子系统 | 组件 | 状态 | 说明 |
|---|---|---|---|
| **传感器** | SLPI/SSC 传感器栈（加速度/环境光/旋转矢量方向/指南针 heading） | ✅ | 自动亮度/自动旋转可用；开机 **~21 s** 可用（M2 后） |
| 传感器 | 启动时序加速（L2/M1/M2） | ✅ | 服务早期启动 + hexrpc 可写 registry：PD 初始化 35 s→**8.2 s** |
| 传感器 | 休眠唤醒恢复 | ✅ | sleep hook + worker，唤醒后 **3–6 s** 传感器就绪并重新 claim（0009 后） |
| 传感器 | **s2idle 睡眠死机**（唤醒后全系统卡死，需长按电源） | ✅ | **根因已修复**：`kernel/patches/0009-fastrpc-listener-unfreezable.patch`；11-19～11-21 共 20 次 s2idle（含 10h47m、5h50m 长睡）**0 崩溃** |
| 传感器 | 原始陀螺 / 磁力计三轴 / 接近（SAR） | 🚫 | 用户态 libssc/udev 未暴露；属软件缺口，非硬件驱动 |
| **指纹** | Goodix GF3626（fprintd 录入/验证、GDM 锁屏/登录、sudo 指纹） | ✅ | TA 需自提；TA 拒服务看门狗自动恢复 |
| **生物认证（可选）** | bioauth：通用 PAM 生物认证栈（指纹/密码，单窗口全屏 UI，sudo/pkexec 可选接入） | ✅ | **默认不装**；`--with-bioauth` 安装；回滚/救援见 `bioauth/INSTALL.md` |
| **GNSS** | Airoha AG3335（QUP5 UART + PAIR + gpsd + GeoClue2） | ✅ | 室外真实定位已验证（mode=3、12 星）；GeoClue 位置与指南针 heading；Pure Maps 已验证 |
| **相机** | 前摄 OV8856 3280×2464 / 后摄 OV13B10 4208×3120 全分辨率拍照/录像 | ✅ | GPU debayer + Venus HEVC/H.264，~30 fps；两个 V4L2 虚拟相机 |
| 相机 | 后摄 AF/AE/AWB、CN3927V VCM、EEPROM 24c64 | ✅ | 软件 AF 扫焦写 focus sysfs |
| 相机 | PipeWire / xdg-desktop-portal / Snapshot | ✅ | 两个 `media.role=Camera` 节点，portal 取流已实测 |
| 相机 | LSC / CCM 画质调校 | ✅ | **不随包提供调校数据**，仅提供本机只读提取脚本；提取后默认启用（后摄暗角 4.4×→~1×），未提取时中性/关闭；`ELISH_LSC=0`/`ELISH_CCM=0` 可关 |
| 相机 | Hi556 景深 | ⚠️ | **RAW 出流已验证**（2592×1944 SGRBG10 @ ~30 fps，checker test pattern），节点已合并进**单一联合 DTB**；无深度/彩色用户态 |
| 相机 | 前后摄同时出流 | 🚫 | CAMSS/DTB 资源限制，一次只能一路 |
| **相机闪光灯/手电筒** | 后摄闪光灯 LED（PM8150L `white:flash`）：开机误闪修复 + 手电筒 | ✅ | **开机 logo 阶段误闪已修复**（默认组件 `flash-led/`）；手电筒可选 GNOME 46 控制中心开关 + `torch` CLI（`--with-torch`，默认不装） |
| **内核/系统** | 联合 DTB（传感器 vmids + 指纹节点 + GNSS QUP5 UART + 相机节点 + Hi556） | ✅ | 模型级、无本机私有信息；构建/校验见 `kernel/dtb/README.md` |
| 内核 | fastrpc SDSP VMID/sensors-PD、QSEECOM/TEE、mdt_loader、qcom_scm、goodix_fp_spi | ✅ | 指纹/传感器内核层 |
| 内核 | LPASS pinctrl clock-timeout defer（pogo 键盘/USB 随机失效） | ✅ | 独立补丁 `kernel/patches/0002-…` |
| 内核 | SMB5 Type-C legacy/100mA resume 卡死 | ✅ | 带充电器 3 轮 suspend/resume 验证 |
| 系统 | 显示/触摸/笔/霍尔/电池/音频/WiFi/BT/USB 键鼠/GPU/UFS/PCIe/Venus | ⚠️ | 基础平台；**音频已修复**（2026-11-13，PulseAudio/WirePlumber PCM 争用，见 `docs/HARDWARE-STATUS.md`） |
| 系统 | 屏幕方向/平板模式/自动旋转配置 | ⚠️ | `tablet_mode=on/off/auto`、`rebuild_mode`；无保护套可用可选组件 `tablet-mode/`（控制中心开关 + uinput 虚拟霍尔） |
| 系统 | 睡眠唤醒后 pogo 键盘 | ⚠️ | 已知内核 USB PHY resume 问题；重启/重插恢复，用户态不改（防死锁） |
| 系统 | 充电 | ⚠️ | 5V 基础 + **PD 9V 快充 + bq2597x 双泵并联已打通**（电池侧 ~18–20W）；PPS 11V keep-alive 稳定可用（50–56% 电量 ~20.5W，比固定档 +8%），可选组件 `pps-charger/`；66W 需原厂私有协议 |
| — | 5G 版本 | — | 本机为 WiFi 版（5G 变体不在本包测试范围；其余杂项硬件所有型号均无） |

完整硬件基线见 [`docs/HARDWARE-STATUS.md`](docs/HARDWARE-STATUS.md)。

---

## 适用系统版本

| 项目 | 值 |
|---|---|
| 设备 | Xiaomi Mi Pad 5 Pro（代号 **elish**，CSOT 面板，WiFi 版） |
| SoC | Qualcomm Snapdragon 870（**SM8250**） |
| 发行版 | **Armbian 26.8.14 noble**（Ubuntu 24.04 LTS 用户态），GNOME 46 |
| 内核 | **`6.18.44-current-sm8250`**（Armbian sm8250 基线 + 本包补丁；BTF/ABI 三件套见 `kernel/README.md`） |
| 启动 | Linux 启动槽由 `/boot/armbianEnv.txt` 的 `abl_boot_partition_label` 决定（本机 `boot_b`；脚本自动跟随，**不写死**）；只写该槽，**不碰 Android 槽** |
| 面板 | CSOT（本包联合 DTB 为 `sm8250-xiaomi-elish-csot.dtb`；BOE 变体未实测） |
| 内核源码（构建用） | 同版本 Armbian sm8250 源码树（如 `/var/tmp/kbuild-src`）；不随包附带 |
| 依赖 | Ubuntu 24.04 包；一键安装器 `--deps` 自动安装 |

> 传感器数据/固件、指纹 TA、GNSS flash 镜像、相机校准 dump **不在包内**，需从自己的设备或
> 官方发行包提取，见 [`docs/DEVICE-DATA-EXTRACTION.md`](docs/DEVICE-DATA-EXTRACTION.md)。

---

## 实测结果（2026-11-21，本机同一台设备）

同一台 elish（CSOT），Armbian noble + `6.18.44-current-sm8250` **release 构建 #13**（无诊断选项），
干净启动；睡眠测试含 10 小时级长睡。

### 启动 / 传感器 / 唤醒

| 指标 | 实测 |
|---|---|
| 桌面就绪（systemd `Startup finished`） | **21.42 s**（kernel 3.16 s + userspace 18.26 s；`graphical.target` 17.96 s） |
| 开机 → 传感器可用 | **20.92 s**（`hexrpc-boot.log [start] up=20.92 sensors OK`） |
| PD registry 初始化（SLPI 起到 sensors OK） | **8.2 s**（M2 可写 registry 前 ~36–42 s） |
| iio 状态 | active、单实例、**NRestarts=0** |
| 合盖 → 唤醒 → 传感器恢复/重新 claim | **3.3 s**（首次）/ **6.0 s**（iio 未运行时 worker 拉起）；s2idle |
| 自动旋转 | 唤醒后可用（实测） |
| s2idle 睡眠死机 | **已修复**（0009）：11-19～11-21 共 **20 次 s2idle**（含 10h47m、5h50m、5h43m、3h33m 长睡）**0 次** PDM/fatal/crash detected；release #13 当日 4 次 0 崩溃（`suspend_stats` success=4 fail=0） |
| 传感器自检 | **14 项 OK / 0 FAIL**；PDM 崩溃 0 |

### 指纹（2026-11-13 完整验证；2026-11-21 复核）

| 指标 | 实测 |
|---|---|
| `fprintd-list` | Goodix QSEE match-on-chip，已录入指纹模板 |
| 录入 / 验证 | ✅（`fprintd-enroll` / `fprintd-verify`） |
| GDM 锁屏 / 登录 | ✅（`enable-fingerprint-authentication=true`） |
| sudo 指纹 | ✅（`pam_fprintd` 8 s 超时→密码回退；旧 `--pam` 栈，可选） |
| TA 拒服务恢复 | ✅ `fp-ta-watchdog` 自动重载 loader |
| 指纹自检 | **OK=19 / WARN=1 / FAIL=0**（WARN：未启用旧 `--pam` sudo 指纹栈，属可选） |

### GNSS（2026-11-13 室外验证）

| 指标 | 实测 |
|---|---|
| 链路 | `/dev/ttyHS1`(921600) → `airoha_gps.ko` → `airoha-gnssd` → `/dev/ttyGNSS0` → gpsd |
| NMEA | 1 Hz，已转发句子数 3939+；`gpsd` TPV 正常（室内 `mode=1` 属正常） |
| 室外定位 | **mode=3、12 星、GGA quality=1**（2 分钟内锁定） |
| GeoClue2 | `gps-nmea-share` → `/run/gps-share.sock`；GeoClue Location 可用 |
| 指南针 | `CompassHeading` 实测 ≈176–177°；GeoClue heading 可用 |
| 地图应用 | GNOME Maps（位置）；Pure Maps 3.5.1（位置+罗盘）已验证 |

### 相机（2026-11-12 实测；管线未变）

| 指标 | 实测 |
|---|---|
| 前摄 | 3280×2464 PNG；HEVC 20 Mbps 录制 **30.05 fps** |
| 后摄 | 3120×4208 PNG；HEVC 20 Mbps 录制 **29.96 fps** |
| GPU debayer | 前摄 11.0–12.1 ms/帧；后摄 18.7–19.8 ms/帧（p95 ≤14.7 / ≤22.1） |
| Venus 编码吞吐（不限速） | 3280×2464 HEVC **135 fps**；4208×3120 HEVC **90.6 fps** |
| 虚拟相机 | `/dev/video2`（前，NV12 3280×2464）、`/dev/video20`（后，NV12 3120×4208） |
| PipeWire / portal | 两个 `media.role=Camera` 节点；portal `OpenPipeWireRemote` + Snapshot 已验证 |
| 后摄软件 AF | 实测室内目标最佳 focus=640（0–1023） |
| LSC 画质调校 | 后摄暗角 4.4×→~1×（本机提取调校数据后；数据不随包） |
| Hi556 景深 | RAW10 2592×1944 SGRBG10 @ ~30 fps，checker test pattern 通过（2026-11-20） |
| 相机自检 | **OK=23 / WARN=0 / FAIL=0** |

### 闪光灯 / 手电筒（2026-11-20）

| 指标 | 实测 |
|---|---|
| 开机 Plymouth 阶段后摄闪光灯误闪 | ✅ 已修复：LED 状态恢复不再写 `white:flash`（修复前后 LED 事件 **2 → 0**） |
| 手电筒 | ✅ `torch` CLI（logind `SetBrightness`，普通用户可用）；可选 GNOME 46 控制中心开关（headless Shell 实测 ACTIVE，注销/登录后生效） |
| 拍照闪光灯（`flash_strobe`） | 🚫 无软件支持（内核未开 `CONFIG_V4L2_FLASH_LED_CLASS`；需内核/相机后端开发） |

### 充电 / 快充（2026-11-21）

| 指标 | 实测 |
|---|---|
| 充电器识别 | USB-C PD 3.0 + PPS（`port0/power_operation_mode=usb_power_delivery`，TCPM 契约 9V/3A） |
| 修复前 | 电池侧 1.36A ≈ **5.4W**（PMIC 默认 FCC 1.5A，驱动从未设置） |
| 修复后（`0010`） | 低电量（55–66%）电池侧 **3.7–3.8A ≈ 15W**，VBUS 8.73–8.75V、AICL 3.3A、温度 ≤40°C |
| 分段充电（`0011–0013`） | <70% 6A、70–80% 4A、80–88% 2.5A、88–93% 1.5A、93–97% 1A、≥97% 0.5A；**提前 Full 已修复**（89–92% 仍继续充电，不再卡在 83%） |
| bq2597x 双泵并联（`0014–0015`） | 修 probe 时序后 master/slave **present=1**、9V 下参与充电；低电量电池侧 **~18–20W**（比 SMB5 单路 +3–5W）；满电 ≥96% 自动关闭泵（防过充） |
| PPS keep-alive（`pps-charger/`，可选） | sink PDO 已加 PPS APDO（DTB `d7840b30…`）；本机充电头 PPS 有 **~13s 看门狗**会 hard reset，服务每 **8s** 重发请求即可稳定保持（实测 11V 2 分钟零复位）；11V 分档后 50–56% 电量电池侧 **~20.5W**（固定 9V 约 18.9W，+8%），短测 11V/4A 可到 23.5W+；温度 ≥41.5°C 回退固定档 |
| 满电拔线状态（`0016`） | 电流方向优先于 `FC` 满电标志：100% 拔线立即显示放电，不再误报“已充满/充电中”；充电到 100% 仍正常显示 FULL |
| 剩余 | 66W 需原厂 11V/6A 私有协议 + 泵协同；JEITA 限流曲线（`docs/TODO.md` §2） |

### 合并自检（`install/check-all.sh`，2026-11-21）

| 项 | 结果 |
|---|---|
| 联合 DTB（传感器 vmids + 指纹 + GNSS + 相机节点） | ✅ 通过 |
| 传感器栈 | **14 OK / 0 FAIL** |
| 指纹栈 | 19 OK / 1 WARN / 0 FAIL（WARN 为可选的旧 `--pam` 栈未启用） |
| GNSS 栈 | 正常（非 root 时 polkit 规则只能 WARN） |
| initramfs 固件不变量 | ✅ 不含 SLPI 固件 |
| 相机栈 | 23 OK / 0 FAIL |
| 闪光灯开机误闪修复 | ✅ 通过（`flash-led/verify.sh`） |
| GNOME 手电筒（可选） | 未装 → SKIP；已装 → ✅ |
| apt 状态 | 已 hold `linux-image/dtb/headers-current-sm8250`、`armbian-firmware-full`、`libfprint-2-2` |

> 完整自检建议 `sudo ./install/check-all.sh`（以 root 可读更多系统文件）。

---

## 包内组件

```
README.md / README.en.md / QUICKSTART.md / INSTALL.md / NOTES.md / PATCHES.md / VERSIONS.md / MANIFEST.md
LICENSE / SHA256SUMS / install.sh（一键安装入口 = install/turnkey.sh 包装）
kernel/        统一内核：驱动源码/补丁、内核配置、initramfs hook、模型级联合 DTB（含 Hi556）、
               一键内核构建安装脚本（build-and-install.sh）、Linux 启动槽重建脚本（自动检测）
sensors/       传感器子包：systemd/udev/D-Bus 集成、启动/唤醒脚本、hexrpc/libssc/iio 补丁与
               编译说明、数据提取脚本、文档
fingerprint/   指纹子包：qsee-supplicant/libfprint 源码与补丁、udev/systemd/PAM 配置、
               TA 提取、安装/验证/卸载脚本、文档
bioauth/       可选：通用生物认证 PAM 栈（PAM module + daemon + GTK4 全屏 helper），默认不装
gnss/          GNSS 子包：airoha_gps 驱动源码、airoha-gnssd/gps-nmea-share 用户态、
               systemd/gpsd/GeoClue 集成、协议与排障文档、flash 修复提取说明
camera/        相机子包：elish-camera GPU 管线（前后摄全分辨率、GPU debayer、Venus 硬编、
               虚拟相机、autoserve、自动对焦）、辅助脚本、udev/自启/休眠恢复、install.sh + verify.sh
flash-led/     后摄闪光灯开机误闪修复（默认组件）：Armbian LED 状态恢复守卫（wrapper + drop-in）
torch/         可选：GNOME 46 手电筒 Quick Settings 扩展 + torch CLI（默认不装）
tablet-mode/   可选：平板模式开关（开/关/自动）+ GNOME 46 控制中心扩展（默认不装；
               uinput helper + systemd 服务，无保护套也能强制平板模式/自动旋转）
pps-charger/   可选：受控 11V PPS 快充服务（8s keep-alive 维持契约、温度分档；装后默认启用）
install/       安装器：一键安装 turnkey.sh、数据提取 extract-all.sh、用户态构建 build-userspace.sh、
               备份启动槽 backup-boot.sh、合并自检 check-all.sh、文件落位表
docs/          硬件状态权威基线、整机 TODO、历史记录、升级影响/内核升级风险、设备数据提取指南、安全加固
```

---

## 安装

> 详细步骤见 [`QUICKSTART.md`](QUICKSTART.md)（一键）与 [`INSTALL.md`](INSTALL.md)（手动分步）。
> 所有安装脚本支持 `--help` 与 `--dry-run`；已安装组件会自动跳过（`--force` 重编）。

### 0. 前置

- 设备为 Xiaomi Pad 5 Pro（elish，CSOT），已刷入 Armbian noble；
- root（sudo；若已按安全加固删除免密，用**指纹或密码**授权）；
- 两个设备文件（不随包）：
  - Android vendor 分区镜像（如 `vendor_a.img`，只读 dump）
  - pMOS SLPI 固件包 `firmware-xiaomi-elish-slpi-*.apk`
- 指纹 TA（可选；若系统已有 `/lib/firmware/gfenu.*` 会复用）；
- 网络（用户态组件需要 `git clone` 上游源码；内核需要自备同版本源码树）。

### 1. 全组件一键安装（推荐）

```bash
# 预览 → 正式安装 → 可选内核/DTB → 重启验证
./install.sh --dry-run --android /path/vendor_a.img --pmos /path/firmware-xiaomi-elish-slpi-*.apk
sudo ./install.sh --android /path/vendor_a.img --pmos /path/firmware-xiaomi-elish-slpi-*.apk --yes
```

- **内核/DTB 是硬依赖**：sensor/fastrpc/fingerprint/GNSS/相机驱动都依赖已打补丁的内核 + 联合 DTB。
  `--with-kernel` 是显式 opt-in（会写 Linux 启动槽 + 需自备内核源码），对全新系统不是“可选”；
  已运行本包完整内核+DTB 时才可跳过（安装器会预检并警告）。
- **联合 DTB（含 Hi556）**：`--with-dtb --write-boot` 只装 DTB 并重建 Linux 槽；`--with-kernel` 在内核步骤中一并安装。
- **相机 LSC/CCM**：`--android` 提取阶段会同时取 `com.qti.tuned.*.bin`，编译相机时在本机生成
  `src/tuning_data.h`（数据不随包、不提交）；没有调校 bin 时自动用中性 LSC/CCM。

### 2. 单组件安装

| 组件 | 命令 |
|---|---|
| 内核 / DTB（首次必需） | `sudo ./kernel/build-and-install.sh --kernel-src <源码> --write-boot`；只装 DTB：`sudo ./kernel/install-dtb.sh [--write-boot]` |
| 传感器 | `sudo ./sensors/install/install-system-files.sh`（+ `install-data.sh`，数据先提取） |
| 指纹 | `sudo ./install/build-userspace.sh --skip-hexrpc --skip-libssc --skip-iio` + `sudo ./fingerprint/install/install-fingerprint-files.sh` |
| GNSS | `sudo ./gnss/install/install.sh`（`airoha_gps.ko` 由内核步骤编译安装） |
| 相机 | `sudo ./camera/install.sh` + `bash ./camera/elish-camera/verify.sh` |
| 闪光灯修复（默认） | `sudo ./flash-led/install.sh`（turnkey 自动装） |
| GNOME 手电筒（可选） | `sudo ./torch/install.sh`（装完注销/重新登录） |
| 平板模式开关（可选） | `sudo ./tablet-mode/install.sh`（开/关/自动；装完注销/重新登录） |
| PPS 快充服务（可选，装后启用） | `sudo ./pps-charger/install.sh`（一键器：`--with-pps-charger`） |
| 控制台静音（可选） | `sudo ./install/quiet-console.sh`（sysctl + boot loglevel=3；`--rollback` 回滚） |
| bioauth（可选，默认不装） | `sudo ./install.sh --no-deps --skip-extract --skip-build --with-bioauth --yes`（接入 sudo/pkexec 见 `bioauth/INSTALL.md`） |
| 安全加固（可选，推荐） | 关闭 GDM 自动登录、删除 sudo 免密、保留指纹授权：见 `docs/HARDENING.md` |

传感器/指纹/GNSS/相机的详细手动步骤分别见 `sensors/INSTALL.md`、`fingerprint/INSTALL.md`、`gnss/INSTALL.md`、
`camera/README.md`；内核细节见 `kernel/README.md`。

### 3. 数据 / 固件提取（本包不附带）

```bash
sudo ./install/extract-all.sh --android <vendor.img> --pmos <slpi.apk> [--fingerprint-adb] [--out DIR]
```
自动提取并校验（registry=155 / config=40 / proto=79 / slpi.mbn md5）。完整清单与手动方法：
[`docs/DEVICE-DATA-EXTRACTION.md`](docs/DEVICE-DATA-EXTRACTION.md)。

---

## 构建

- **一键安装器**会自动 `git clone` 上游源码、应用本包补丁并编译安装（源码缓存在 `/var/tmp/elish-build`）；
- 手动构建步骤：
  - 内核：`kernel/README.md`（步骤 A/B、配置检查、ABI 三件套）
  - hexrpc：`sensors/userspace/hexrpc/README.md`（v0.3.2 + 本包补丁）
  - libssc / iio：`sensors/userspace/*/README.md`
  - 指纹：`fingerprint/INSTALL.md`（qsee-supplicant、libfprint goodix-qsee）
  - 相机：`camera/elish-camera/Makefile`（`make -C camera/elish-camera`）
- 已验证的源码版本/commit 与安装后 sha256 参考见根 `VERSIONS.md`（子包 README 列各自组件版本）。

---

## 验证

```bash
sudo ./install/check-all.sh         # 合并自检（DTB/传感器/指纹/GNSS/相机/闪光灯/initramfs/apt）
sensor-status                       # 传感器总览（服务/固件路径/PDM/iio/数值）
bash camera/elish-camera/verify.sh  # 相机栈
./kernel/compat-check.sh --src <新内核源码树>   # 升级前：补丁/整文件兼容性 dry-run（只读）
sudo ./fingerprint/install/verify-fingerprint.sh "$USER"
sudo ./gnss/install/verify.sh
sudo ./flash-led/verify.sh          # 闪光灯开机误闪修复
sudo ./torch/verify.sh              # 可选手电筒（未安装则 SKIP）
sudo ./tablet-mode/verify.sh        # 可选平板模式开关（未安装则 SKIP）
sudo ./pps-charger/verify.sh         # 可选 PPS 快充服务（未安装则 SKIP）
sudo ./kernel/dtb/verify-combined-dtb.sh
```

---

## 已知限制

- 传感器 PD 偶发静默卡死（约 **1/14** 次干净启动）：固件侧问题，干净重启恢复，非本包可修；
- 原始陀螺/磁力计三轴/接近未暴露（libssc/udev 层待补）；
- 相机：Hi556 景深无深度/彩色用户态；前后摄不能同时出流；前摄固定焦点；Flatpak/COSMIC 的 portal backend 限制；
- pogo 键盘唤醒后可能失效（内核 USB PHY resume；**不要**用 `authorized`/`USBDEVFS_RESET`/重绑控制器）；
- 指纹 TA 需自提；`libfprint-2-2` 升级会覆盖自编译库（建议 hold）；内核/固件升级后需按 `docs/UPGRADE-IMPACT-ALL.md` 重做；
- sudo 指纹 PAM 属安全敏感配置（旧 `--pam` 栈，可选），安装前确保能用密码回退；
- 手电筒 GNOME 扩展需注销/重新登录后生效（GNOME 46 不支持热加载新扩展）；
- 拍照闪光灯（`flash_strobe`）不支持：内核未开 `CONFIG_V4L2_FLASH_LED_CLASS`，相机软件无 flash 控件；
- 充电：5V 基础 + PD 9V 快充 + bq2597x 双泵并联（低电量 ~18–20W）已打通；可选 PPS 服务用 11V keep-alive（~20.5W，+8%，温度 40°C 左右）；66W 需原厂私有协议（`docs/TODO.md` §2）；
- Firefox 原生 Wayland **长睡唤醒后触屏失效**属上游 Firefox bug（mozilla 2032822 / 2026258），与本驱动包无关。

---

## Credit / 上游代码

本包是"多上游整合 + 大量逆向/适配/验证"的成果，感谢以下项目与个人：

### 上游代码库

| 项目 | 用途 | 许可 |
|---|---|---|
| [Linux kernel](https://git.kernel.org/) / [mainline](https://github.com/torvalds/linux) | 内核基础与驱动框架 | GPL-2.0 |
| [Armbian build](https://github.com/armbian/build) / armbian-firmware | sm8250 基线、配置、传感器固件数据 | GPL-2.0 / 各自 |
| [linux-msm/hexagonrpc](https://github.com/linux-msm/hexagonrpc) | SLPI/SSC FastRPC 文件服务（hexagonrpcd 0.3.2） | GPL-2.0 |
| [mmcallister/libssc](https://codeberg.org/mmcallister/libssc) | SSC 传感器发现/通信库（0.4.4） | LGPL-2.1 |
| [hadess/iio-sensor-proxy](https://gitlab.freedesktop.org/hadess/iio-sensor-proxy) | IIO→D-Bus SensorProxy | GPL-2.0-or-later |
| [wrobelda/libfprint](https://github.com/wrobelda/libfprint)（goodix-qsee） | Goodix QSEE 指纹驱动 | LGPL-2.1 |
| [wrobelda/qsee-supplicant](https://github.com/wrobelda/qsee-supplicant) | QSEE supplicant / app-loader | GPL-2.0 |
| [postmarketOS](https://gitlab.com/postmarketOS)（device-xiaomi-elish / firmware 包） | SLPI 单文件固件来源 | 各自（pMOS 打包） |
| PipeWire / WirePlumber | 相机/音频媒体管线 | MIT / MIT |
| [v4l2loopback](https://github.com/v4l2loopback/v4l2loopback) | 虚拟相机 | GPL-2.0 |
| Mesa / EGL / GLES / libdrm / GBM | GPU debayer 渲染 | MIT / 各自 |
| GeoClue / gpsd / Pure Maps | 定位栈与地图应用 | LGPL / BSD / GPL |
| quectel-open-source/GNSSTool 等 GNSS 参考 | AG3335 协议参考 | 各自 |
| 社区 hexrpc 可写 registry 补丁（suckbluefrog / gennro / Armada OS 打包） | M2 可写 sensor registry | 随上游补丁 |

### 个人 / AI 贡献

- **caitming** — 项目发起、设备实验、内核/驱动集成、测试与维护；
- **DeepSeek Harness AI Agent（deepseek-flash）** — 只读逆向分析、传感器启动加速 L2/M1/M2 与唤醒恢复、
  hexrpc 可写 registry 补丁适配、s2idle 睡眠死机根因定位与 fastrpc `PF_NOFREEZE` 修复、相机/指纹/GNSS
  集成验证、安装器与文档编写。

---

## 开源协议（MIT）

本包**原创部分**（安装器、系统配置、脚本、文档）以 **MIT License** 发布，见 [`LICENSE`](LICENSE)。

> 上游代码/补丁（内核与驱动补丁、hexagonrpc、libssc、iio-sensor-proxy、libfprint、
> qsee-supplicant、PipeWire、v4l2loopback 等）**保留各自原许可证**（主要为 GPL-2.0 /
> LGPL-2.1 / MIT 等），以各上游仓库的 LICENSE 为准；再分发/修改时请同时遵守相应许可证。

---

## 维护

- 硬件基线：`docs/HARDWARE-STATUS.md`（权威）
- 整机待办/已知问题：`docs/TODO.md`；历史开发/部署记录：`docs/HISTORY.md`
- 升级影响：`docs/UPGRADE-IMPACT-ALL.md`；内核升级风险与操作清单：`docs/KERNEL-UPGRADE-RISK.md`
- 回滚/救援：`kernel/README.md` 与安装脚本的自动备份（安装内核/系统前会备份 Linux 启动槽与关键配置）
