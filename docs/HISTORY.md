# 历史记录（里程碑时间线）

> 2026-11-21 整理为简洁时间线：只保留里程碑、关键根因与结果，冗长命令、重复数字与旧指标已删除。
> 当前状态以 [`HARDWARE-STATUS.md`](HARDWARE-STATUS.md) 为准，未完成项见 [`TODO.md`](TODO.md)；
> 安装/校验/协议细节见各子包文档。文中日期为事件发生时间。

## 2026-11-22 — pogo 键盘唤醒 HID 假死：用户态自动复位（默认组件 `pogo/`）

- **现象**：s2idle 唤醒后 pogo 键盘（USB `3206:3ffc`）完全无输入；USB 设备仍在、`lsusb` 正常，
  但按键/触摸板没有 input 事件；物理拔插或重启才恢复。
- **根因修正**：此前认为“host USB PHY fast-resume 不重初始化”。2026-11-12 实验 A（关闭
  `a800000.usb` 的 wakeup，强制 `dwc3_core_exit()` + `dwc3_core_init_for_resume()`）唤醒后键盘
  仍无输入；`authorized` 0→1 / `USBDEVFS_RESET` 也只重枚举主机侧。真正卡住的是**键盘 MCU/HID
  侧**（设备级控制请求仍应答），只有脉冲键盘 reset 引脚才恢复。
- **修复**：系统唤醒后脉冲键盘 reset GPIO（TLMM 141）。为避免 sleep-post 内过早操作（历史 1s
  直操作曾硬死机），hook 用 `systemd-run --on-active=3s` 延迟到 USB/xHCI resume 完成后再执行：
  `/usr/lib/systemd/system-sleep/69-elish-pogo-kb.sh` + `/usr/local/sbin/elish-pogo-kb-reset`。
  未接键盘时直接跳过；配置 `/etc/default/elish-pogo-kb`，日志 `/var/log/elish-pogo-kb.log`。
- **验证**：手动脉冲两次均触发 `USB disconnect` → 重枚举（Device 002→003、003→004）并恢复按键；
  装上 hook 后手动睡/醒一次正常；另做 3 轮 `systemctl suspend` + RTC 自动唤醒，hook 每轮 +3s
  触发（devnum 7→8→9→10），无死机、键盘可用。
- **限制**：每次唤醒键盘重枚举约 1–1.5s（Device 号递增；唤醒后 3s 内打字可能丢键）。**不要**
  再用 `authorized`/`USBDEVFS_RESET`/重绑控制器（历史上重绑 `a8f8800.usb` 曾导致
  `qcom_snps_hsphy_exit` 告警、tee 卡 D、USB 瘫痪）。这是 MCU 侧问题的用户态兜底，
  以后若有内核正确修复可卸载本组件再做长睡验证。

## 2026-11-21 — s2idle 睡眠死机修复（0009）+ PD 9V 快充（0010）

- **现象**：设备偶发“睡死”——s2idle 唤醒后全系统卡死，需长按电源。
- **根因**：hexagonrpcd 阻塞在 fastrpc listener（handle=3）的 ioctl 等待；suspend 时内核 freezer 冻住该线程，
  DSP 侧文件服务请求无人应答 → frpc 超时 → SLPI `sensor_process` PD 崩溃 → recovery 的
  `qcom_scm_pas_shutdown` 卡在 EL3。
- **修复**：`kernel/patches/0009-fastrpc-listener-unfreezable.patch`（约 18 行，仅
  `drivers/misc/fastrpc.c`）：对 handle=3 的调用线程设 `PF_NOFREEZE`，freezer 跳过它。
- **验证**：打补丁内核自 2026-11-19 至 11-21 共 20 次 s2idle（含 10h47m、5h50m、5h43m、3h33m 长睡）
  0 次 PDM/fatal/crash；release #13（`SMP Sat Nov 21 10:38:33 CST 2026`，release 配置）当日 4 次
  s2idle 0 崩溃，唤醒后传感器 3.3 s / 6.0 s 恢复，开机传感器可用 20.92 s。
- **本轮 release 同步更新**：联合 DTB（已含 Hi556 节点）与 release 内核模块的安装后 sha256
  基线（见 `VERSIONS.md`）。

### PD 9V 快充与分段充电（0010–0013，同日）

- **根因**：PM8150B 的 `FAST_CHARGE_CURRENT_CFG` 从未被驱动写入，PMIC 上电默认只有 **1.5A**，
  所以 PD 9V 协商成功后电池侧也只有 1.36A ≈ 5.4W。
- **修复**：`kernel/patches/0010-smb5-fast-charge-current-vbus.patch`——USB 插入 / PD 协商 / AICL
  变化时读取 VBUS：≥6.5V（9V 档）设电池充电电流 6A，5V 档保持 1.5A，拔线恢复；VBUS 读数为 0
  时保持不变，避免 APSD/PD 重协商瞬态误降档（第一版内核 #14 踩过这个坑）。
- **实测**（release #15，PD 9V/PPS 充电器，64–66% 电量）：电池侧 **3.7–3.8A ≈ 15W**（修复前
  1.36A ≈ 5.4W），VBUS 8.73–8.75V、AICL 3.3A、电池温度 ≤40°C、无抖动。
- **提前 Full 修复（0011–0013）**：大电流下 SMB5 的 VBAT 采样被 IR 压降抬高，真实电量 ~83% 就
  `TERMINATE_CHARGE`（显示 Full 且不回充）。0011 先做“偏高就对半降流”验证可行；0012 改为按电量
  分段的 step-charging 曲线（<70% 6A、70–80% 4A、80–88% 2.5A、88–93% 1.5A、93–97% 1A、≥97% 0.5A）；
  0013 修正把 `BATT_GT_FULL_ON`（正常模式标志）当异常的问题。release #18 实测：89–92% 仍持续充电
  （1.5A/0.75A 档），不再提前报 Full。
- **后续**：驱动层温控（泵+FCC）、5V DCP 电流上限、66W 私有协议见 `TODO.md` §1。

### bq2597x 并联快充与 PPS 11V 实验（0014–0015 + pps-charger，同日）

- **并联泵启用**：mainline 里两块 `bq2597x`（master/slave）一直 `present=0`。根因是 probe 时
  `tcpm-source-psy` 可能还没注册，原驱动只查一次就永久放弃；notifier 里还有 30 秒 `msleep` 会阻塞
  power_supply 回调。`0014` 改为后台每秒重试 + delayed work，`present` 变 1；`0015` 按 SoC 门控
  （≥96% 关泵防过充，每 30s 复查）。9V 固定档下电池侧从 ~15W 提到 **~18–20W**。
- **PPS 实验**：给 DTB sink PDO 增加 PPS APDO（3.3–11V/5A）后，TCPM 可协商 11V/3A、11V/4.5A、9V/5A；
  最初发现本机 100W PD 头在 PPS 契约建立约 **13 秒**后主动发 Hard Reset（TCPM `Received hard reset`）。
- **keep-alive 突破（同日深夜）**：这个 13s 复位是充电头的 **PPS 看门狗**——每 **≤8 秒重发一次当前
  PPS 请求**即可稳定保持；另外每次重协商后要重设 SMB5 输入限流（ICL=3A），否则充电会掉到系统负载。
  实测 11V keep-alive 连续 2 分钟零复位，11V 分档后 50–56% 电量电池侧 **~20.5W**
  （固定 9V 约 18.9W，+8%）；短测 11V/4A 可达 23.5W+，电池温度约 40°C。
- **高电量退出（2026-11-22 凌晨）**：实测 ~90% 时 SMB5 会提前报 `Full`（浮充电压先到），若继续 11V PPS 电量会卡住；
  服务改为 **≥88% 或 SMB5 报 Full 就退出 PPS**，回到 9V 固定档由 SMB5 涓流到 100%（已实测 90→91% 继续上升）。
- **结论**：标准 PPS + keep-alive 可用（受温度限制，41.5°C 回退固定档）；原厂 66W 仍需要
  11V/6A 私有协议 + 双泵协同。受控服务 `pps-charger/` 作为可选组件（`--with-pps-charger`），
  安装后默认启用。
- **观测**：9V 下电池温度 40°C 左右；满电时泵会被 0015 关闭；11V 时 25W 会让电芯很快到 42°C。
- **满电状态修复（0016）**：`bq27xxx_battery` 原来先看 `FC` 满电标志再看电流方向，导致 100% 拔线后
  仍报 `Full` / 显示充电图标；改为放电（电流为负）优先报 `DISCHARGING`，充电到 100% 仍正常显示 `FULL`。

### 唤醒慢与电源键连按（0017，2026-11-22 凌晨）

- **现象**：s2idle 唤醒很慢，用户连按电源键，屏幕亮一下又灭。
- **日志**：唤醒本身 ~2.3s（systemd-suspend 完成），但触屏 `nvt_ts_resume` 每次都重下固件
  （320–350ms，偶有失败重试）、传感器 worker 要 3.2–6.1s（加速度计 0.1–2.9s + 重启 iio claim）、
  音频 DSP 初始化 + libinput 828ms 延迟；连按电源被 logind 当成反复 suspend（看到 2–6s 间隔的多次 entry/exit）。
- **修复**：`0017-pwrkey-post-resume-grace.patch` 在 resume 后 6 秒内丢弃电源键事件（模块参数可调），
  实测唤醒后连按不再灭屏、9 秒后按电源正常睡眠。
- **后续可优化**（未做）：触屏 resume 固件下载快路径、传感器 worker 减少一次 iio 重启。

### 控制台静音（2026-11-21 晚）

- 注销时 GDM 切 VT，cs35l41 功放 DSP 关闭超时（-110）打出 18 条 error，console 一直露在屏幕上；
- `/etc/sysctl.d/99-elish-quiet-console.conf`：`kernel.printk = 3 4 1 7`（console 只留 crit/alert/emerg，
  journald 不变）；
- `/boot/armbianEnv.txt` 的 extraargs 追加 `loglevel=3 vt.global_cursor_default=0` 并重建启动槽：
  开机 splash 前的早期 error 也不再显示（panic 仍显示）；重建脚本 `install/quiet-console.sh`，可 `--rollback`。

## 2026-11-20 — 闪光灯误闪修复 / 可选手电筒 / Hi556 RAW 打通

- **flash-led（默认组件）**：修复每次开机 Plymouth 阶段后摄闪光灯误闪——Armbian
  `armbian-led-state-restore.sh` 对 default-on LED 的 workaround 会短暂点亮 flash 类 LED；
  用 wrapper（过滤 flash 类 stanza）+ systemd drop-in 解决，不改 Armbian 包文件；实测 `white:flash`
  LED 事件 2→0。
- **torch（可选，默认不装）**：GNOME 46 控制中心手电筒开关 + `torch` CLI，走 logind
  `Session.SetBrightness("leds","white:flash",N)`，普通用户可用。拍照闪光 `flash_strobe` 仍不支持
  （内核未开 `CONFIG_V4L2_FLASH_LED_CLASS`）。
- **Hi556 stage2**：RAW10 2592×1944 SGRBG10 @ ~30fps，checker test pattern 通过；随后合并进单一联合
  DTB（模型级，含 Hi556 节点）。原“PM8150A L1/L2 被 USB 占用”纠正为 **DTS 缺 `ldoc2` 节点**。

## 2026-11-23 — GNSS s2idle 后无 fix 修复（cold start）

- **现象**：s2idle 唤醒后 NMEA 正常、GSV 有 8–10 颗星/SNR，但仰角/方位为空、GGA 无 fix。
- **根因**：芯片备份星历在 suspend 后失效，daemon 发的 `$PAIR004`（hot start）返回
  `$PAIR001,004,2`（失败），导航引擎未启动；daemon 只检查 PAIR002 ACK，未发现 004 失败。
- **修复**：`airoha-gnssd` 在 PAIR066/062/086 后改发 `$PAIR003*39`（cold start，实测 ACK 0），
  重新搜星/下载星历；已安装并重启服务。地铁/室内无信号时 GSV=0 属正常。

## 2026-11-13 — 音频修复 / 传感器启动加速 / 安全加固 / GNSS 真实定位 / 打包自动化

- **音频无输出修复**：根因是 PipeWire/WirePlumber 的 ALSA monitor 与 PulseAudio 争用唯一 PCM
  `hw:Pro,0`（PA 报设备忙、sink 永久 SUSPENDED）；用户级
  `~/.config/wireplumber/main.lua.d/51-disable-alsa.lua`（`alsa_monitor.enabled=false`，只关 ALSA 音频
  监视、保留相机 v4l2 监视）解决；实测 `paplay` 正常、PCM RUNNING，相机 PipeWire 不受影响。
- **传感器启动加速 L2+M1+M2**：`slpi-sensors` 提前启动（不再等 `multi-user.target`）+ iio 时序 +
  hexrpc 可写 sensor registry（M2，社区 0005/0006/0007 补丁）；开机到传感器可用 **79 s → 20.9 s**，
  PD registry 初始化 **35 s → 8.2 s**，`iio-sensor-proxy` NRestarts=0；可写 registry 消除 `temp.json`
  写失败重试（1570→0）。
- **安全加固**：关闭 GDM 自动登录、删除 sudo 免密，保留指纹 sudo（PAM `pam_fprintd` 8s 超时回退）
  与 GDM 指纹；相机辅助脚本去掉 `sudo -n` 依赖（改组权限/udev）。见 `HARDENING.md`。
- **GNSS 真实定位**：此前只发 `$PAIR002`，缺星座/NMEA 配置与 hot start；补发
  `$PAIR066`/`$PAIR062` 系列/`$PAIR086`/`$PAIR004`（runtime-only，**不写 flash**），室外 2 分钟内
  mode=3、12 星、GGA quality=1。
- **打包/工具**：一键安装器（turnkey/extract-all/build-userspace）、boot 槽位自动检测（不再写死
  `boot_b`）、`kernel/compat-check.sh` + `docs/KERNEL-UPGRADE-RISK.md`、`docs/DEVICE-DATA-EXTRACTION.md`、
  相机 sudo 依赖修复与 `camera/elish-camera/verify.sh`。
- **系统调优（更早完成，同日收尾）**：禁用 `serial-getty@ttyS0`/`apt-xapian-index.timer`（开机
  95 s → 13.8 s）、plymouth、屏蔽键盘隐形鼠标、QQ/mihomo 原生 Wayland、WiFi 关电源管理、gjs、
  libpam-gnome-keyring、PAM 审批提权、固件精简（`/lib/firmware` 2.2G→350M）、磁盘清理 ~4.1 GB。

## 2026-11-12 — 相机全分辨率 / GNSS / 方向与唤醒 / SMB5 resume 修复

- **相机全分辨率 GPU 管线**：前 OV8856 3280×2464、后 OV13B10 4208×3120 全彩拍照/录像；
  GPU debayer（FD650 EGL/GLES）+ Venus HEVC/H.264 硬编（实测 ~30fps）；`/dev/video2`（前）/
  `/dev/video20`（后）标准 V4L2 NV12；两个原生 PipeWire `media.role=Camera` 节点，
  portal/Snapshot 实测；后摄软件 AF/AE/AWB。
- **GNSS 打通**：Airoha AG3335，QUP5 UART（`/dev/ttyHS1`，921600）+ PAIR 协议 + gpsd +
  `gps-nmea-share` → GeoClue2；此前“BROM 需 HDL_START_CMD”为误判（实为 BROM 握手 + 错误波特率）。
- **屏幕方向/平板模式**：相机方向跟随 Mutter transform（横 180°/竖 90°）；`SW_TABLET_MODE`
  驱动 GNOME 平板模式；`elish-camera-ctl orientation` / `rebuild_mode=idle|live|off`。
- **休眠唤醒传感器恢复**：sleep hook + `elish-sensors-resume`（独立 cgroup 的 worker，等加速计就绪
  后再重启 iio 让 mutter 重新 claim）；相机后端登录自启（`elish-camera-autostart`）。
- **内核补丁**：0002（LPASS pinctrl clock-timeout defer）、0004（SMB5 Type-C legacy reset +
  resume 重跑 APSD/AICL，带充电器 3 轮 suspend/resume 验证，修复 resume 后 100mA 卡死）、
  0005/0006/0007/0008（OV8856/OV13B10/CN3927V/Hi556）、指纹 QSEECOM/TEE 系列补丁。
- **被取代的路线**：曾评估 libcamera + portal 标准相机接入，最终采用自研原生 PipeWire
  `media.role=Camera` 节点方案（不依赖 libcamera/v4l2loopback 枚举）。

## 更早（包建立之前的系统调优）

- 显示/输入/通知/提权等系统级调整（plymouth、GDM 中文、`10-wifi-disable-powermanagement.rules`、
  `10-ignore-xiaomi-pad-mouse.rules`、gjs、gnome-keyring、PAM 审批弹窗等）已并入上文。
