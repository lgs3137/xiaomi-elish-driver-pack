# 硬件驱动状态（本机权威基线）

- **设备**：Xiaomi Mi Pad 5 Pro（SM8250 / elish，**WiFi 版**，CSOT 面板）
- **系统**：Armbian 26.8.14 noble（Ubuntu 24.04 用户态），GNOME 46（Wayland）
- **内核**：`6.18.44-current-sm8250`，release 构建 #18（`SMP Sat Nov 21 15:21:00 CST 2026`；release 配置，**无** PM_DEBUG / DPM_WATCHDOG 等诊断项；含 0009 睡眠修复与 0010–0013 快充/分段充电）
- **包版本 / 更新日期**：**2026.11.21**（本文件按 2026-11-21 release #18 实测刷新）
- **用途**：后续会话/安装/排查**以本文件为准**；历史里程碑见 [`HISTORY.md`](HISTORY.md)，未完成项见 [`TODO.md`](TODO.md)。
- **判定标准**：✅ 已驱动且当前可用；⚠️ 部分驱动/有已知功能缺陷；❌ 有硬件但 Linux 未驱动；— 本机不存在。

---

## 0. 结论速览

| 类别 | 硬件 | 状态 |
|---|---|---|
| **相机** | 前 **OV8856 8MP**（固定焦点）+ 后 **OV13B10 13MP**（CN3927V VCM + EEPROM 24c64）+ 景深 **Hi556** | ⚠️ 前后摄全分辨率彩色拍照/录像已可用（前 3280×2464 / 后 4208×3120，GPU debayer + Venus HEVC/H.264 ~30fps；`/dev/video2`/`/dev/video20`；两个原生 PipeWire `media.role=Camera` 节点；portal/Snapshot 实测）；后摄 AF/AE/AWB；**Hi556 RAW10 2592×1944@~30fps 已验证**（checker test pattern，已并入单一联合 DTB）；无 Hi556 用户态深度/彩色；前后摄不能同时出流；前摄固定焦点 |
| 已驱动 | **GNSS（Airoha AG3335，QUP5 UART + PAIR 协议）** | ✅ 室外真实定位 mode=3、12 星、GGA quality=1；GeoClue2 + Pure Maps 3.5.1 已验证（见 §3） |
| 已驱动 | 传感器：加速度、环境光、旋转矢量方向、指南针 heading | ✅ |
| 部分驱动 | 原始陀螺、原始磁力计三轴、接近/SAR | ⚠️ 用户态（libssc/udev）未暴露，非硬件驱动缺口 |
| 已驱动 | 传感器启动：`PRE_DELAY=0`、`IIO_DELAY=8`，M2 可写 registry | ✅ 开机到传感器可用 **20.9 s**（改造前 79s）；PD registry 初始化 **8.2 s**；`iio-sensor-proxy` 单实例 NRestarts=0 |
| 可靠性 | 干净启动成功率 | ⚠️ 约 **13/14**；偶发 SLPI/PD 静默卡死（固件侧，干净重启恢复） |
| 已驱动 | **休眠/唤醒（s2idle）** | ✅ **睡眠死机已修复**（`kernel/patches/0009-fastrpc-listener-unfreezable.patch`）：20 次 s2idle 0 崩溃；唤醒后传感器 **3.3–6.0 s** 恢复 |
| 已驱动（可配置） | 屏幕方向 / 平板模式 / 相机流重建 | ✅ `tablet_mode=on/off/auto`、`rebuild_mode=idle/live/off`；`elish-camera-ctl orientation` |
| 已驱动 | 相机后端登录自启 | ✅ `elish-camera-autostart` + `/etc/xdg/autostart/elish-camera-autoserve.desktop` |
| 已驱动 | 相机画质调校（LSC/CCM） | ✅ 仅提供本机只读提取脚本（不随包带调校数据）；提取后默认启用（后摄暗角 4.4×→~1×）；`ELISH_LSC`/`ELISH_CCM` 可关 |
| 已驱动 | 指纹 Goodix GF3626 | ✅ fprintd 录入/验证、GDM 解锁、sudo 认证（当前走 bioauth）、`fp-ta-watchdog` 自动恢复；自检 OK=19 / WARN=1 / FAIL=0 |
| 已驱动 | 音频 | ✅（PA/WirePlumber 争用唯一 PCM 已修复：用户级 `51-disable-alsa.lua`；相机 PipeWire 不受影响） |
| 已驱动 | 闪光灯 / 手电筒 | ✅ `white:flash`；开机误闪已修复（默认组件 `flash-led/`）；手电筒可选（`torch/`，默认不装） |
| 已驱动 | 显示/触摸/笔/霍尔/电池充电/WiFi/BT/键鼠/Venus/GPU/UFS/PCIe/PMIC | ✅ 基础平台可用；充电：5V 基础 + **PD 9V 快充已打通**（电池侧低电量 ~15W，高电量按分段曲线降档，不再提前 Full）；bq2597x 泵 / 27W 与 11V 档未接 |
| 功能缺陷 | 睡眠唤醒后 pogo 键盘可能失效/反复重枚举 | ⚠️ host USB PHY resume 内核问题；重启/重插恢复，用户态不改（历史危险复位已禁用） |
| 本机不存在 | 5G 版本（本机 WiFi 版；5G 变体不在本包测试范围） | — |

---

## 1. 相机（已打通；当前接口与限制）

| 项 | 内容 |
|---|---|
| 硬件 | 前摄 **OV8856 8MP**（2-lane，固定焦点）+ 后摄 **OV13B10 13MP**（4-lane，CN3927V VCM，EEPROM 24c64）+ 景深 **Hi556 5MP** |
| 当前能力 | 前 3280×2464 / 后 4208×3120 全分辨率彩色拍照/录像；GPU debayer（FD650 EGL/GLES）+ Venus HEVC/H.264 硬编，实测约 30fps；虚拟相机 `/dev/video2`（前）/`/dev/video20`（后）标准 V4L2 NV12；两个原生 PipeWire `media.role=Camera` 节点（带 `api.libcamera.location`）；portal/Snapshot 实测；后摄软件 AF/AE/AWB |
| 关键事实 | Bayer：前摄 **BGGR**、后摄 **GRBG**；前摄必须 `vertical_flip=0`（vflip=1 时 3280×2464 无帧）；Venus encoder/decoder 的 video 节点号不跨启动稳定，需按 sysfs 名发现 |
| Hi556 景深 | media graph `hi556 21-0020` → CSIPHY0 → CSID0 → VFE0 RDI2；RAW10 2592×1944 SGRBG10 @ ~30fps，checker test pattern 通过；上电顺序 3 路供电 → MCLK → 最后释放 reset（与 OV 相反）；已合并进单一联合 DTB；**尚无 3A/彩色/深度用户态** |
| 限制 | 前后摄不能同时出流（CAMSS/DTB 限制）；前摄固定焦点；Flatpak/COSMIC 的 portal backend 受限；拍照闪光 `flash_strobe` 不支持（内核未开 `CONFIG_V4L2_FLASH_LED_CLASS`） |
| 实现/文档 | `camera/elish-camera/`（源码 + `install.sh` + `verify.sh`）；架构/接口见 `camera/elish-camera/docs/` |
| 备注 | VCM sysfs 需 video 组可写（`camera/99-elish-vcm.rules`）；闪光灯开机误闪修复见 `flash-led/`；通用手电筒见 `torch/`（默认不装） |

---

## 2. 部分驱动 / 已知功能缺陷

### 2.1 传感器：加速度/环境光/方向/指南针已可用；原始陀螺/磁力计/接近未暴露

| 项 | 状态 |
|---|---|
| 已工作 | 加速度计、环境光、旋转矢量方向；**指南针 heading 已可用**（来自 rotv 融合，D-Bus `/net/hadess/SensorProxy/Compass` 属性 `CompassHeading`） |
| 未暴露 | 原始陀螺、原始磁力计三轴（μT）、接近/SAR（`HasProximity=false`） |
| 硬件 | LSM6DSO（加速度+陀螺）、AK991x（磁力计）、TCS3701/BU27030（环境光）、SX932x（SAR/接近） |
| 启动时间 | `PRE_DELAY=0`、`IIO_DELAY=8`：开机到传感器可用 **20.9 s**（release #15：kernel 3.13 s + userspace 18.64 s；`hexrpc-boot.log` `[start] up=20.96 sensors OK`；SLPI start up=12.85 s → PD registry 初始化约 8.1 s）；`iio-sensor-proxy` active、单实例、NRestarts=0 |
| 可靠性 | 干净启动成功率约 **13/14**；残留为 PD 初始化偶发静默卡死（attach 只读 `hw_platform` 后停住、无崩溃/无 assign -22/registry timeout），与延迟无关，干净重启恢复；同 boot 内重启服务无效 |
| 休眠/唤醒 | **PD `frpc_dsp` resume 崩溃已修复**（`kernel/patches/0009-fastrpc-listener-unfreezable.patch`）：打补丁内核自 2026-11-19 至 11-21 共 **20 次 s2idle**（含 10h47m、5h50m、5h43m、3h33m 等长睡）**0 次** PDM/fatal/crash；release #13 当日 **4 次 s2idle**（最长 25.8 分钟）0 崩溃，`/sys/power/suspend_stats` success=4 fail=0；唤醒后传感器恢复 **3.3 s / 6.0 s**（`journalctl -t elish-sensors-resume`；iio 未运行时 worker 会拉起它） |
| iio 启动方式 | 启动脚本在 `IIO_DELAY` 后拉起；补丁版 iio 常驻等待热插（`staying alive ... (patched)`），健康检查最长 150 s；单实例、NRestarts=0 |
| 剩余工作 | 原始陀螺/磁力计/接近仍需在 libssc/udev 层补类型/scale/units（天级，不是硬件驱动问题） |

### 2.2 睡眠唤醒后 pogo 键盘失效

- **现象**：s2idle 唤醒后键盘无响应，需物理拔插；偶发 suspend 后 USB 进入每 ~7 秒断开重连循环（重启后恢复）。
- **根因**：键盘在 host `a8f8800.usb/a800000.usb`（`Xiaomi Pad Keyboard` / USB HID）；问题在 host+wakeup 的 s2idle fast-resume 只做 PHY runtime resume、不重新初始化 PHY/控制器。日志里 `dwc3-qcom-legacy a6f8800.usb: port-1 HS-PHY not in L2` 是 Type-C/外设控制器（device 模式）的误报，不是键盘。
- **不要尝试**：`authorized` 0→1、`USBDEVFS_RESET`、重绑控制器（曾导致 `qcom_snps_hsphy_exit` 死锁、USB 瘫痪）；用户态 `elish-sensors-resume` 只处理 iio/传感器，**刻意不碰 pogo USB**。
- **修复方向**：需改内核 resume 路径或报上游，用户态无解。遇此现象：重启或物理重插键盘。

### 2.3 其他小毛病（非驱动缺口）

- PMIC RTC 无有效后备电池时间，断电后可能回到 1970，系统靠 NTP 校准（不影响硬件驱动判定）。
- GPU cooling device 注册告警、DPU frame event overflow 偶发——已知 dmesg 噪音，不影响使用。
- GStreamer 的 `libgstva.so` 在 Ubuntu arm64 是空插件（软件生态问题）；Firefox 走 libva/VA-API 硬解正常。
- Firefox 原生 Wayland 长睡后触屏失效：**上游 Firefox bug**（mozilla 2032822 / 2026258），与驱动包无关；设备侧 `68-touch-fix` 是包外 workaround，不属于本包组件。

### 2.4 屏幕方向 / 平板模式 / 自动旋转

| 项 | 说明 |
|---|---|
| 相机方向 | 后端读 Mutter `DisplayConfig` transform 自动选旋转角：横屏 180°、竖屏 90°；`elish-camera-ctl rotate front|rear <角度>` 可覆盖 |
| 平板模式 | 由保护套折叠霍尔 `SW_TABLET_MODE`（gpiochip3 line121）决定：折到背面=1→GNOME 平板模式（自动旋转+软键盘）；键盘在前/取下=0→笔记本模式 |
| 配置 | `/etc/elish-orientation.conf`：`tablet_mode=on|off|auto`、`rebuild_mode=idle|live|off`；`elish-camera-ctl orientation`（zenity 面板/CLI）；可选组件 `tablet-mode/` 提供控制中心开关 + uinput 虚拟平板模式（无保护套可用） |
| 相机流重建 | `idle`：使用中不打断、空闲后按新方向重建；`live`：立即重建并自动重开 Snapshot；`off`：不重建 |
| 霍尔数量 | Android vendor DTBO 另有 `hall_intr3`(gpio136)、`hall_intr4`(gpio138)、`gamekey hall_left`(gpio121)/`hall_right`(gpio64)、键盘 MCU gpio155；mainline 只接 2 个开关，额外霍尔读数恒定、不可用于键盘插拔判断 |
| 已知限制 | Snapshot/aperture 不支持预览中途换分辨率，故默认 idle；唤醒后传感器恢复 **3.3–6.0 s**（0009 修复后） |

---

## 3. 已驱动（当前可用）

| 子系统 | 硬件/证据 |
|---|---|
| 显示 | CSOT 面板 + DPU/DSI；背光 KTZ8866（i2c 11-0011） |
| 触摸/笔 | NT36523：`NVTCapacitiveTouchScreen`、`NVTCapacitivePen`（基础笔输入已驱动） |
| 霍尔/按键 | `gpio-keys`：`switch-lid`/`switch-tablet-mode`（SW=3），电源键/resin |
| 电池/充电 | 双 `bq27z561`、`pm8150b`、`bq2597x` master/slave、USB-C TCPM/UCSI；suspend/resume 后 Type-C legacy/100mA 卡死已修复（`0004`）；**PD 9V 快充已打通**（`0010`：VBUS≥6.5V 时电池充电电流 1.5A→6A，低电量实测 3.7–3.8A ≈ **15W**）；**提前 Full 已修复**：`0011–0013` 按电量分段降档（<70% 6A … ≥97% 0.5A），89–92% 仍持续充电；`bq2597x` 电荷泵仍 present=0（并联 / 27W 与 11V 档待后续） |
| 音频 | `Xiaomi Mi Pad 5 Pro` 声卡；8×CS35L41 外放、耳机、录音。无输出已修复：根因是 PipeWire/WirePlumber ALSA monitor 与 PulseAudio 争用唯一 PCM（`hw:Pro,0`），用户级 `~/.config/wireplumber/main.lua.d/51-disable-alsa.lua`（`alsa_monitor.enabled=false`）解决，相机 PipeWire 不受影响；遗留 `Enable(0) failed: -110` 为功放下电 hibernate 超时（播放上电正常、无 `PUP-done` 超时，不影响外放） |
| WiFi/BT | QCA6390（ath11k + btqca/hci_uart）；`wlp1s0`/`hci0` 正常 |
| 键盘/鼠标 | USB HID：`Xiaomi Pad Keyboard`、`Xiaomi Pad Mouse`、`Xiaomi Pad`，外接蓝牙鼠标 |
| 传感器 | 加速度/环境光/方向/指南针 heading（见 §2.1） |
| **GNSS** | **Airoha AG3335**：`/dev/ttyHS1`（QUP5 UART，921600）+ `airoha_gps.ko`（供电/时钟/pinctrl）+ `airoha-gnssd`（PAIR002 + PAIR 运行时初始化 + NMEA→pty）+ `gpsd`（`/dev/ttyGNSS0`，NMEA0183）+ `gps-nmea-share` → GeoClue2（`/run/gps-share.sock`）；实机 NMEA 1 Hz，与传感器/罗盘可同时工作；室外真实 fix 验证 mode=3、12 星、GGA quality=1。地图应用：GNOME Maps 仅位置（不读传感器）；**Pure Maps 3.5.1（Flathub）已验证**；朝向：本包 polkit 规则放行 geoclue 的 `ClaimCompass`，实测 GeoClue Location 同时返回位置与 heading，Pure Maps 罗盘在跟随/导航且速度<10km/h 时激活 |
| 指纹 | Goodix GF3626：fprintd 录入/验证、GDM 解锁、sudo 认证（当前接入 bioauth；旧 `pam_fprintd` 栈可选；NOPASSWD 未停用则被绕过）、`fp-ta-watchdog` 自动恢复 |
| 相机闪光灯 | `/sys/class/leds/white:flash`（v4l2 flash LED）；开机误闪修复（`flash-led/`，默认）；可选手电筒（`torch/`：GNOME 46 控制中心开关 + `torch` CLI，默认不装） |
| 视频编解码 | Venus V4L2 stateful：`vainfo` → H.264/HEVC 解码/编码；Firefox VA-API |
| GPU/存储/总线 | Adreno/freedreno、UFS、PCIe、USB 主机 |
| PMIC/杂项 | regulator、ADC、thermal、RTC、flash LED、UCSI 等 |
| 睡眠/唤醒 | s2idle 死机已修复（`0009` fastrpc listener `PF_NOFREEZE`）；唤醒后传感器 3.3–6.0 s 恢复（见 §2.1） |

---

## 4. 本机不存在 / 不计划支持（不要当驱动缺口）

| 硬件 | 依据 |
|---|---|
| 5G 版本 | 本机是 WiFi 版（用户确认）；5G 变体不在本包测试范围 |
| 额外霍尔 | vendor DTBO 的 `hall_intr3/4`、`gamekey hall_left/right`、键盘 MCU gpio155 在 mainline 无驱动/未启用，自动旋转/软键盘只需 `SW_TABLET_MODE` |

> 其余所有 elish 型号均不存在的杂项硬件不再列出；DTB 中也未包含对应节点。

---

## 5. 如何复核（当前系统）

```bash
# 整机自检（含 DTB/传感器/GNSS/指纹/initramfs/相机）
sudo ./install/check-all.sh

# 开机与传感器时序
systemd-analyze                                # kernel / userspace / graphical.target
cat /var/log/hexrpc-boot.log | grep 'up='      # 传感器可用时刻（release #15: up=20.96）
systemctl status iio-sensor-proxy --no-pager   # active、单实例、NRestarts=0
journalctl -t elish-sensors-resume -b --no-pager | tail   # 唤醒恢复耗时（3.3–6.0 s）

# 休眠/唤醒（睡眠死机修复）
cat /sys/power/suspend_stats                   # success / fail
dmesg | grep -iE 'frpc_dsp|PDM|crash detected' # 应为空

# 充电 / PD 快充 / 分段曲线
dmesg | grep -iE 'fast-charge current|charge soc-step|charge vbat-high'   # 6A 起步 + 按电量降档
cat /sys/class/power_supply/pm8150b-charger/{voltage_now,current_max,usb_type}
cat /sys/class/power_supply/bq27z561-0/current_now   # 9V 快充时电池侧约 1.8–2.0A（两 gauge 合计 ~3.8A）
cat /sys/class/power_supply/bq2597x-master/present   # 0 = 电荷泵未接

# 相机 / 虚拟相机 / PipeWire 节点
elish-camera-ctl status                        # /dev/video2,20 + consumers + PipeWire 节点数
pw-cli ls Node | grep 'elish-camera-'          # 两个原生 PipeWire Camera 节点
v4l2-ctl -d /dev/video2 --get-fmt-video        # NV12 3280x2464（方向随屏幕变化）
elish-camera photo --camera front -o /tmp/front.png   # 前摄 3280x2464 全分辨率

# 屏幕方向 / 平板模式
elish-camera-ctl orientation                   # tablet_mode / rebuild_mode
elish-check-usb                                # USB 枚举次数/键盘/平板模式

# GNSS
gnss/install/verify.sh                         # DTB 节点/设备/服务/NMEA/gpsd
ls -l /dev/ttyHS1 /dev/airoha_gps /dev/ttyGNSS0 /run/gps-share.sock
gpspipe -w -n 5                                # 室外应 mode=3
systemctl status gps-nmea-share geoclue

# 已驱动抽查
cat /proc/asound/cards                         # Xiaomi Mi Pad 5 Pro
vainfo | head -5                               # Qualcomm Venus V4L2 VA-API
rfkill list; hciconfig -a | head               # WiFi/BT
grep -A3 'NVTCapacitivePen' /proc/bus/input/devices
gdbus call --system --dest net.hadess.SensorProxy --object-path /net/hadess/SensorProxy \
  --method org.freedesktop.DBus.Properties.GetAll net.hadess.SensorProxy
```

---

## 6. 来源与更新约定

- 本文件按 **2026-11-21 release 构建 #13（`SMP Sat Nov 21 10:38:33 CST 2026`）** 的本机实测刷新；历史里程碑见 [`HISTORY.md`](HISTORY.md)。
- 安装后产物 sha256 以 `VERSIONS.md` 为准（fastrpc.ko / goodix_fp_spi.ko / 联合 DTB 等），本文不重复数字。
- **后续更新硬件状态直接改本文件**：同步 §0 速览、对应小节与“更新日期”；与旧报告/旧结论冲突时以本文件为准。
