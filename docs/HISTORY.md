# 历史记录（里程碑时间线）

> 2026-11-21 整理为简洁时间线：只保留里程碑、关键根因与结果，冗长命令、重复数字与旧指标已删除。
> 当前状态以 [`HARDWARE-STATUS.md`](HARDWARE-STATUS.md) 为准，未完成项见 [`TODO.md`](TODO.md)；
> 安装/校验/协议细节见各子包文档。文中日期为事件发生时间。

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

### PD 9V 快充（0010，同日）

- **根因**：PM8150B 的 `FAST_CHARGE_CURRENT_CFG` 从未被驱动写入，PMIC 上电默认只有 **1.5A**，
  所以 PD 9V 协商成功后电池侧也只有 1.36A ≈ 5.4W。
- **修复**：`kernel/patches/0010-smb5-fast-charge-current-vbus.patch`——USB 插入 / PD 协商 / AICL
  变化时读取 VBUS：≥6.5V（9V 档）设电池充电电流 6A，5V 档保持 1.5A，拔线恢复；VBUS 读数为 0
  时保持不变，避免 APSD/PD 重协商瞬态误降档（第一版内核 #14 踩过这个坑）。
- **实测**（release #15，PD 9V/PPS 充电器，64–66% 电量）：电池侧 **3.7–3.8A ≈ 15W**（修复前
  1.36A ≈ 5.4W），VBUS 8.73–8.75V、AICL 3.3A、电池温度 ≤40°C、无抖动。
- **剩余**：`bq2597x` 电荷泵并联（20–27W 档）与 JEITA 限流曲线见 `TODO.md` §2。

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
