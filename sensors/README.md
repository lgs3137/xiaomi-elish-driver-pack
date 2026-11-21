# Xiaomi Mi Pad 5 Pro (elish) — Qualcomm SLPI 传感器栈（v1-final 安装包）

在 Armbian Linux（kernel `6.18.44-current-sm8250`）上启用 SM8250 的 SLPI 传感器 DSP（SSC），
让环境光、加速度计、旋转矢量方向、指南针 heading 等传感器在 Linux 桌面可用（自动亮度/自动旋转/朝向）。

本归档是**安装包**：只含代码、补丁、系统集成文件与文档；**不含固件、厂商数据、编译产物、日志**。
缺失的设备相关数据/固件在 `INSTALL.md` / `extract/` 中给出确定来源与提取方法。

本目录只覆盖传感器栈；合并包还包含指纹、GNSS、相机、闪光灯等组件（见顶层 `../README.md`）。
版本/校验（BOM）见 `../VERSIONS.md`，补丁总清单见 `../PATCHES.md`，包内容清单见 `../MANIFEST.md`。

> 本文档基于 **2026-11-21**（kernel release #13）实测状态清理；开发历史只保留在根 `../docs/HISTORY.md`。

## 已验证可用

- ✅ 环境光（`HasAmbientLight` / `LightLevel`）
- ✅ 旋转矢量方向（`AccelerometerOrientation`）
- ✅ 指南针 heading（`/net/hadess/SensorProxy/Compass` → `CompassHeading`，来自 rotv 融合；原始磁力计三轴仍未暴露）
  （权威状态见 `../docs/HARDWARE-STATUS.md`）
- ✅ 加速度计 `lsm6dso`（需要 `99-ssc-accel.rules` 启用；`81-libssc-xiaomi-elish.rules` 提供挂载矩阵）
- ℹ️ 固件 mount matrix 全 0 → iio 回退 identity，旋转方向由 81 规则矩阵修正（如方向不对可调该矩阵）
- ⚠️ 陀螺原始数据未提供（仅融合后的 rotv）；proximity 默认未启用

## 当前指标（2026-11-21，release #13 干净启动实测）

| 指标 | 实测值 |
|---|---|
| 开机 → 传感器可用 | **20.9 s**（`/var/log/hexrpc-boot.log`：`[start] up=20.92 sensors OK`；旧实现 ~79 s） |
| SLPI 启动 / PD registry 初始化 | SLPI start issued up=12.74 s；PD registry 约 **8.2 s**（M2 可写 registry 之前 ~35 s） |
| iio-sensor-proxy | active、单实例、**NRestarts=0** |
| s2idle 睡眠 | **已修复**（`../kernel/patches/0009-fastrpc-listener-unfreezable.patch`）：2026-11-19～21 共 **20 次** s2idle（含 10h47m 等长睡）**0 次** PDM/crash；release #13 当日 4 次 0 崩溃 |
| 唤醒后传感器恢复 | **3.3 s / 6.0 s**（`journalctl -t elish-sensors-resume` 实测；iio 未运行时 worker 会拉起它） |
| 调参默认值 | `PRE_DELAY=0`、`IIO_DELAY=8`（`/etc/sensor-tuning.conf`） |

> 旧口径「开机 ~22 s、唤醒 ~10 s」是 2026-11-13 及以前的测量方式，不再作为当前指标。

## 开机链路（当前实现）

```
kernel（开机不 auto_boot SLPI）→ slpi-fw-guard.service（multi-user 之前修正固件路径不变量）
  → slpi-sensors.service（Type=exec，与桌面启动并行；PRE_DELAY=0）
  → warm 监听器（hexrpc-sdsp-service.sh，HEXAGONRPC_WARM_ATTACH=1）
  → 把固件放进 /run/sensor-fw 并启动 SLPI（/lib/firmware 路径是悬空符号链接）
  → /dev/fastrpc-sdsp 出现后 hexagonrpcd attach（5–20ms 窗口）
  → iio-sensor-proxy 由启动脚本在 IIO_DELAY 后拉起（也会被 GNOME 经 D-Bus 激活），
     补丁版常驻等待 SSC 设备热插
  → libssc 枚举 sensor core → D-Bus SensorProxy → GNOME
```

- 预期日志：`[start] SLPI start issued; device=yes after ...ms`、`[start] sensors OK (...)`；
  iio 日志里的 `No sensors found at startup; staying alive waiting for hotplug (patched)`
  是**补丁版常驻路径**（不是错误），设备随后热插即被注册。
- 开机报告：`/var/log/sensor-boot-report.txt`、`/var/log/sensor-last-boot.txt`；
  一次启动时序诊断：`/var/log/sensor-timing.log`（`sensor-timing-diag.sh`，420 s 后自退）。

## 已知限制 / 残留风险（详见 `NOTES.md`）

1. **偶发 PD 静默卡死**：约 1/14 次干净开机会出现"attach 只读 hw_platform 就停住、无崩溃、无 assign -22"，
   传感器起不来；干净重启即可恢复。与 PRE_DELAY 无关（0/10/45s 都出现过/都通过过）。
2. **suspend/resume**：0009 已修复 s2idle 唤醒后的 sensor PD 崩溃；`60-sensors-suspend.sh` pre 停 iio、
   post 兜底重拉监听器并重启 iio，唤醒后 3.3–6.0 s 传感器恢复。若唤醒后仍缺失，需干净重启
   （同 boot 内 SCM assign 不可重复）。
3. **固件不变量**：`/lib/firmware/.../slpi.mbn` 必须始终保持"指向 /run 的悬空符号链接"；
   任何普通固件文件出现在该路径都会导致内核开机抢先 auto_boot → 本次开机传感器不可用。
   升级 `armbian-firmware-full` 后务必检查（`slpi-fw-guard` 会在开机时修正并记录告警）。
4. 本目录只覆盖传感器栈；指纹/GNSS/相机等与传感器无关的组件与风险见顶层文档。

## 目录结构

```
README.md / INSTALL.md / NOTES.md / SHA256SUMS
userspace/    hexrpc 0.3.2（warm-attach + M2 可写 registry 补丁）、iio-sensor-proxy 补丁、libssc 说明
systemd/      systemd 单元 / drop-in / udev 规则 / 休眠钩子 / 调参文件 / D-Bus 与 polkit 配置
scripts/      运行时脚本（启动/停止/warm 监听器/固件守卫/开机报告/诊断）与日志说明
install/      安装/校验/升级检查/卸载脚本 + 文件落位对照表（FILES-MAP.md）
extract/      设备数据与固件提取脚本（armbian-firmware / Android vendor 镜像 / pMOS APK）
docs/         IIO-FIX.md（iio 修复原理）、TROUBLESHOOTING.md（故障排查）、UPGRADE-IMPACT.md（升级影响）
```

内核资产统一在顶层：`../kernel/`（fastrpc 补丁、联合 DTB、initramfs hook、内核构建脚本）。

## 快速开始

```bash
# 1) 提取数据（三条来源，见 INSTALL.md 第 2 步）
# 2) 编译安装内核模块与用户态组件（第 3 步）
# 3) 安装系统文件与数据
sudo ./install/install-system-files.sh
sudo ./install/install-data.sh --android ... --armbian ... --firmware ...
# 4) 重启并自检
sudo reboot
./install/verify.sh
```

完整步骤、依赖、验证判据、升级/回滚、故障排查：见 **`INSTALL.md`**、**`NOTES.md`**、**`docs/TROUBLESHOOTING.md`**。

**升级前必读**：`docs/UPGRADE-IMPACT.md`（内核/DTB/boot 镜像、armbian-firmware、iio/hexrpc/libssc
在升级后分别会受什么影响、哪些必须保持原样、哪些可以修补）。

## 组件版本与安装路径

| 组件 | 版本 / 基准 | 安装位置 / 说明 |
|---|---|---|
| hexagonrpcd | hexagonrpc **v0.3.2**（`b7eff23`）+ 0001 warm-attach；默认部署 M2 可写 registry 构建（0001+0003+0004+0005） | `/opt/hexrpc-032b/bin/`，见 `userspace/hexrpc/README.md` |
| libssc | **0.4.4**（`v0.4.4-9-g4e4c6c8`） | `/usr/local/lib/aarch64-linux-gnu/libssc.so.2`，见 `userspace/libssc/README.md` |
| iio-sensor-proxy | commit **`ca0d5b0`**（3.9-1）+ 三处补丁 | `/usr/libexec/iio-sensor-proxy`，见 `userspace/iio-sensor-proxy/README.md` |
| fastrpc.ko | Linux v6.18.44 + `../kernel/patches/0001`；合并包内核构建另含 0009（睡眠修复） | 见 `../kernel/README.md` |

安装后二进制 sha256 参考值见 `../VERSIONS.md`。

## 红线（必须遵守）

- **不要写 Android 启动槽**；不要改 Android 侧任何分区。（本机 Android 在 `boot_a`、Linux 在 `boot_b`；
  若你的 Linux 在别的槽，以 `/boot/armbianEnv.txt` 的 `abl_boot_partition_label` 为准，本包脚本自动跟随）
- 不要在传感器栈运行中 `echo stop > /sys/class/remoteproc/*/state`（会 RCU stall → panic）。
- 不要用 `dtc` 往返修改 DTB（会破坏 `regulators-1/ldo10`（L10C 3.3V）的 4 字节电压属性）——DTB 修改见 `../kernel/dtb/README.md`。

## 第三方组件

hexagonrpc（linux-msm）、libssc（mmcallister）、iio-sensor-proxy（hadess）、postmarketOS 固件包、
Armbian 内核/固件包。补丁与集成脚本见 `../PATCHES.md` 与 `userspace/*/README.md`。
