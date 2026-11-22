# 相机（前摄 OV8856 / 后摄 OV13B10 / 景深 Hi556）— 当前状态与用法

> 适用：包版本 **2026.11.21**，内核 `6.18.44-current-sm8250`（release #15）。
> 本文件只保留当前状态、安装、用法与限制；构建/CLI/方向配置见
> [`elish-camera/README.md`](elish-camera/README.md)，架构与实测事实见
> [`elish-camera/docs/architecture.md`](elish-camera/docs/architecture.md)，
> 第三方 App 接口见 [`elish-camera/docs/interface.md`](elish-camera/docs/interface.md)。

## 当前状态（2026-11-21 实机验收）

| 能力 | 状态 |
|---|---|
| 前摄 3280×2464 彩色拍照 / HEVC/H.264 录像 | ✅ ~30 fps |
| 后摄 4208×3120 彩色拍照 / 录像 | ✅ ~30 fps（重负载 25–29 fps） |
| GPU debayer（Adreno 650 / FD650，EGL-GLES） | ✅ 前 11–12 ms、后 19–20 ms 每帧 |
| Venus 硬件编码吞吐（不限速） | ✅ 前 135 fps / 后 90.6 fps（HEVC） |
| 虚拟相机 `/dev/video2`（前）/ `/dev/video20`（后） | ✅ NV12 全分辨率、标准 V4L2、30 fps |
| PipeWire 原生相机节点 / portal Camera | ✅ `Elish Front/Rear Camera`（`media.role=Camera`），`IsCameraPresent=true`，GNOME Snapshot 实测可用 |
| 后摄 AF/AE/AWB（CN3927V VCM） | ✅ 软件扫焦（实测最佳 focus=640）+ AE/AWB；前摄固定焦点（硬件无 AF） |
| LSC/CCM 画质调校（Android Chromatix 逆向数据） | ✅ 默认启用；后摄暗角 4.4×→~1×，`ELISH_LSC/ELISH_CCM=0` 可关；调校数据不随包 |
| Hi556 景深 | ✅ RAW10 2592×1944 SGRBG10 @ ~30 fps，checker test pattern 通过（2026-11-20）；无 3A/深度用户态（Android 侧仅作 depth 使用，是否彩色未验证） |
| 前后摄同时出流 | ❌ CAMSS/DTB 共享资源限制，一次一路 |
| 拍照闪光灯（`flash_strobe`） | ❌ 内核未开 `CONFIG_V4L2_FLASH_LED_CLASS`（手电筒模式见 [`torch/`](../torch/README.md)） |

- 前后摄**不能同时出流**（CAMSS/DTB 共享资源，一次一路，切换约 1–2 s）。
- **Hi556** 节点已合并进包内**单一联合 DTB**（`kernel/dtb/sm8250-xiaomi-elish-csot.dtb`）；
  `kernel/dtb/hi556/` 保留生成/应用脚本（见 `kernel/dtb/hi556/README.md`）。
  早期“卡在 PM8150A L1/L2 供电”的结论已纠正：Android 的 `pm8150a_l2` = RPMH `ldoc2`（1.2V），
  mainline 驱动已支持，只是 DTS 缺节点。当前只到 **RAW**，无 3A/彩色/深度用户态。

## 安装

```bash
sudo ./camera/install.sh                 # 编译 elish-camera + 脚本/udev/自启/休眠恢复 + orientation 权限
bash ./camera/elish-camera/verify.sh     # 只读自检（也并入 install/check-all.sh）
```

- 前提：内核/联合 DTB 已按 `kernel/README.md` 安装（联合 DTB 已含 CAMSS/VCM 与 Hi556 节点）。
- 调校数据可选：`sudo ./camera/install.sh --tuning-bins <dir>` 从本机 Android vendor 提取
  LSC/CCM 后编译；不给则用中性 LSC/CCM（不影响使用）。

## 使用

```bash
# 常驻后端（autoserve）：按 App 打开的设备自动路由到前/后摄
elish-camera-ctl start [--front-size WxH --front-fps N --rear-size WxH --rear-fps N --autofocus]
elish-camera-ctl status | stop | panel | gui front|rear

# 拍照 / 录像（全分辨率，GPU debayer + Venus 硬编）
elish-camera photo  --camera front|rear -o out.png
elish-camera record --camera front|rear -o out.mp4 -d 10 [--codec h264] [--bitrate 25000]
elish-camera serve  --camera front|rear     # 常驻虚拟相机
elish-camera focus  --camera rear           # 后摄扫焦（前摄固定焦点）

# 屏幕方向 / 平板模式
elish-camera-ctl orientation tablet on|off|auto
elish-camera-ctl orientation rebuild idle|live|off
elish-camera-ctl rotate front|rear <0|90|180|270|auto>
```

- 两个 V4L2 设备：`/dev/video2`（前）、`/dev/video20`（后）；App 打开哪个，后端就切到对应传感器。
- 没有磁吸保护套时可装可选组件 `tablet-mode/`：在 GNOME 控制中心切换「自动 / 开 / 关」，
  等效于 `elish-camera-ctl orientation tablet ...`（见 `tablet-mode/README.md`）。
- 分辨率/帧率由**生产者**决定（consumer 的 `S_FMT` 只回显），用 `elish-camera-ctl` 或命令参数改。
- 第三方 App：Guvcview 直连 `/dev/video2`/`/dev/video20`；ffmpeg/GStreamer 用 V4L2（NV12）；
  Flatpak/portal App（GNOME Snapshot）使用原生 PipeWire 节点，完整矩阵见
  `elish-camera/docs/interface.md`。
- 完整 CLI/方向/桌面入口说明见 `elish-camera/README.md`。

## 依赖

- 内核 `6.18.44-current-sm8250` + 联合 DTB（`kernel/dtb/sm8250-xiaomi-elish-csot.dtb`）。
- 用户态：`egl`/`glesv2`/`libdrm`/`gbm` 开发头、`zlib`、`ffmpeg`、`v4l-utils`、`v4l2loopback`。
- udev：`camera/99-elish-vcm.rules`（VCM focus 可写）、`camera/99-elish-dma-heap.rules`（GPU debayer）。
- **不要**安装 `libspa-0.2-libcamera`，不要改 DTB/内核模块（会破坏本管线）。

## 已知限制

- Hi556 景深：只有 RAW 出流，无 3A/深度用户态（Android 侧仅作 depth 使用）；前后摄不能同时出流；前摄固定焦点无 AF。
- 高负载下后摄 25–29 fps；分辨率/帧率需在生产者侧配置。
- v4l2loopback 经 WirePlumber 发布的节点不暴露 EnumFormat，旧 portal/GStreamer App 可能不识别；
  本包用自研原生 PipeWire 节点解决（Snapshot 已验证）。
- Flatpak/COSMIC 的 portal backend 限制：只验证了 GNOME 46（portal-gnome 46.2）；
  COSMIC 等其它桌面 backend 未验证。
- 测量/测试用的 `testdata/` raw 文件不随包；需要时在 `camera/elish-camera/` 下构建后
  `./build/capture_test --camera front|rear --frames N --out /tmp/cap` 从自己设备采集。
- 后摄 EEPROM 校准 dump（24c64，单机私有）不随包，读取方法见 `docs/DEVICE-DATA-EXTRACTION.md` §4。

## 服务 / 自启 / 休眠唤醒恢复

- 登录自启：`/etc/xdg/autostart/elish-camera-autoserve.desktop` → `elish-camera-autostart`；
- 休眠唤醒：`camera/system/elish-sensors-resume*`——等加速计就绪后重启 iio，让 mutter 重新 claim，
  实测唤醒后 **3.3–6.0 s** 恢复自动旋转（日志：`journalctl -t elish-sensors-resume -b`）。

若手工部署（未跑 `camera/install.sh`）：

```bash
sudo install -m755 camera/elish-camera-autostart /usr/local/bin/
sudo install -m644 camera/elish-camera-autoserve.desktop /etc/xdg/autostart/
sudo install -m755 camera/system/elish-sensors-resume-worker /usr/local/sbin/
sudo mkdir -p /usr/lib/systemd/system-sleep
sudo install -m755 camera/system/elish-sensors-resume /usr/lib/systemd/system-sleep/
sudo install -m644 camera/system/elish-sensors-resume.service /etc/systemd/system/
sudo systemctl daemon-reload
```

## 自检

```bash
bash camera/elish-camera/verify.sh     # 脚本/udev/虚拟相机/后端/PipeWire 节点
elish-camera-ctl status                # 后端 + /dev/video2,20 + consumers + 节点数
```
