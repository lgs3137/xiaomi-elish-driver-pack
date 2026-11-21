# elish-camera — 前后摄全分辨率 GPU 拍摄/录像管线

Xiaomi Pad 5 Pro（SM8250 / elish）在 mainline Armbian 上，把前后摄以**全分辨率、约 30 fps**
的彩色画面采集出来，用 **GPU（Adreno 650 / FD650，EGL-GLES）去马赛克**、
**Venus（V4L2 M2M）硬件编码**录像，并通过**标准 V4L2（v4l2loopback）+ 原生 PipeWire 相机节点**
暴露给第三方 App。

> 当前状态一览（已验收/限制）见 [`../README.md`](../README.md)；
> 架构与实测事实见 [`docs/architecture.md`](docs/architecture.md)；
> 第三方 App 接口矩阵见 [`docs/interface.md`](docs/interface.md)。

## 关键指标（本机实测）

| 项 | 指标 |
|---|---|
| 前摄拍照/录像 | 3280×2464 彩色，~30 fps（HEVC 20 Mbps 录制实测 30.05 fps） |
| 后摄拍照/录像 | 4208×3120 彩色，~30 fps（实测 29.96 fps；重负载 25–29 fps） |
| GPU debayer（含回读，NV12） | 前 11.0–12.1 ms/帧、后 18.7–19.8 ms/帧（p95 ≤14.7 / ≤22.1） |
| RGB888 静照 | 前 ~13 ms、后 21–26 ms |
| Venus 编码吞吐（不限速，真实 sensor 内容） | 前 3280×2464 HEVC **135 fps**；后 4208×3120 HEVC **90.6 fps** |
| 实时编码 | 30 fps 节拍 0 丢帧；`push` p95 4.7–8.1 ms |
| 后摄 AF | 软件扫焦，实测室内目标最佳 focus=640（0–1023） |
| LSC 画质调校 | 后摄暗角 4.4×→~1×（本机提取数据后默认启用；数据不随包） |

## 构建

```bash
make            # build/elish-camera + tools
```

依赖：`gcc`、`pkg-config`、`egl`/`glesv2`/`libdrm`/`gbm` 开发头、`zlib`、`ffmpeg`（MP4 封装）。
不需要 GStreamer（仅作为第三方消费者验证时使用）。

## 用法

```bash
# 相机信息
./build/elish-camera list

# 全分辨率拍照（方向按当前显示自动选择，也可 --rotate 覆盖）
./build/elish-camera photo --camera front -o front.png
./build/elish-camera photo --camera rear  -o rear.png

# 录像（HEVC 20 Mbps，默认 30 fps；-d 0 表示一直录到 Ctrl-C）
./build/elish-camera record --camera front -o front.mp4 -d 10
./build/elish-camera record --camera rear  -o rear.mp4  -d 10 --codec h264 --bitrate 25000

# 录像同时作为虚拟相机输出（/dev/video2 前摄 / /dev/video20 后摄）
./build/elish-camera record --camera front -o front.mp4 --loopback /dev/video2

# 常驻虚拟相机，给第三方 App（Guvcview/ffmpeg/GStreamer/PipeWire/portal）
./build/elish-camera serve --camera front          # -> /dev/video2
./build/elish-camera serve --camera rear           # -> /dev/video20

# 指定分辨率/帧率/旋转/对焦
./build/elish-camera photo --camera rear --size 2104x1560 --rotate 90 --focus 640
./build/elish-camera record --camera front --size 1640x1232 --fps 30 --rotate 180
```

第三方 App 侧：

```bash
ffmpeg -f v4l2 -input_format nv12 -video_size 3280x2464 -i /dev/video2 -frames:v 10 out-%02d.png
gst-launch-1.0 -q v4l2src device=/dev/video2 num-buffers=30 ! fakesink
guvcview --device=/dev/video2
gst-launch-1.0 -q pipewiresrc target-object=<serial> num-buffers=30 ! fakesink
```

## 相机控制面板 / 切换 / 对焦

两个相机是**两个独立的标准 V4L2 设备**，并且后端会自动路由：

- `/dev/video2`  = 前摄（默认 3280×2464@30）
- `/dev/video20` = 后摄（默认 4208×3120@30）

`elish-camera autoserve`（由 `elish-camera-ctl` 管理）常驻运行，**哪个设备被 App 打开，
后端就把当前唯一可用的传感器切到那个设备**。所以在 Guvcview 的 **Device 下拉里直接选
`/dev/video20` 就会自动切到后摄**（约 1–2 秒出画面），不需要再手动切脚本/面板；用户
关掉设备后后端自动停止相机（省电）。

注意硬件事实：两个传感器**不能同时出流**（实测：一个开始出流，另一个立即停），
所以两个设备不能同时有画面；同一时刻只有一个 App 能取流。

分辨率/帧率：v4l2loopback 的格式由生产者决定（consumer 的 S_FMT 只会被回显），
Guvcview 里不能改；用面板或命令改后端配置（会自动重开 Guvcview）：

```bash
elish-camera-ctl panel                      # 图形面板：相机/分辨率/帧率/自动对焦
elish-camera-ctl start --front-size 1640x1232 --front-fps 30 \
                       --rear-size 2104x1560 --rear-fps 60 --autofocus
elish-camera-ctl gui rear                   # 在 /dev/video20 上打开 Guvcview
elish-camera-ctl status / stop
```

桌面入口：**Guvcview**（系统已有；打开后在 Device 下拉里选 `/dev/video2`
前摄或 `/dev/video20` 后摄）与 **Elish Camera Settings**（分辨率/帧率/对焦/
方向面板）。后端由登录自启的 autoserve 拉起。

自动对焦（仅后摄，前摄 OV8856 是固定焦点镜头）：

```bash
elish-camera focus --camera rear            # 一次扫焦，输出最佳位置并写入 VCM
elish-camera photo --camera rear --autofocus
elish-camera-ctl start --rear-size 2104x1560 --autofocus   # 预览时自动对焦
```

注意：VCM 的 sysfs 需要 video 组可写，安装包里的
`/etc/udev/rules.d/99-elish-vcm.rules` 已处理；若手工部署请执行
`sudo chgrp video /sys/bus/i2c/devices/20-000c/focus && sudo chmod 664 .../focus`。

分辨率/帧率（会自动对齐到真实 sensor 模式）：

| 相机 | 模式 |
|---|---|
| 前摄 | 3280x2464@30、1640x1232@30 |
| 后摄 | 4208x3120@30、4160x3120@30、4160x2340@30、2104x1560@60、2080x1170@60、1364x768@120 |

`--fps` 低于模式帧率时会自动丢帧（例如后摄 2104x1560@60 模式录 30fps 视频）。

## 画质调校（Android Chromatix LSC / CCM）

**本包不包含任何设备调校数据**（没有 `tuning_data.h`、没有 Chromatix bin/JSON/CSV）。
只提供只读提取/生成脚本：[`tools/android_tuning/`](tools/android_tuning/README.md)。

在有数据时，GPU 颜色管线支持：

- **LSC**：后摄 OV13B10 的 4 通道 × 13×17 实测增益网格（暗角 4.4× → ~1×）；
- **CCM**：D65 段 3×3 矩阵（AWB 之后、gamma 之前）；
- 前摄 OV8856 只有厂商模板 LSC，默认关闭（`ELISH_LSC_FRONT=1` 可开）。

行为：

- 仓库默认构建**没有 `src/tuning_data.h`** → LSC/CCM 使用 identity（中性），
  默认关闭，源码可正常编译/运行；
- 按 `tools/android_tuning/README.md` 从**你自己的设备**只读提取并生成
  `src/tuning_data.h` 后重新 `make`，LSC/CCM 默认开启；
- 一键安装器会自动做这件事：`sudo ./install.sh --android <vendor.img> ...` 会提取
  `com.qti.tuned.*.bin` 并在编译相机前生成头文件；也可
  `sudo ./camera/install.sh --tuning-bins <dir>` 单独指定；
- `ELISH_LSC=0` / `ELISH_CCM=0` 可关闭；生成物已被 `.gitignore` 忽略，不要提交/分发。

验证（本机带数据构建）：合成 RAW 暗角 4.4× → 0% 波动；CCM 与矩阵数学逐通道一致；
真机 `verify` PASS；开销后摄 +0.7~0.9 ms、前摄 +0.1 ms，不参与 3A 统计。

## 屏幕方向 / 自动旋转（可配置）

GNOME 的自动旋转只在 mutter 认为设备处于**平板模式**时启用
（`PanelOrientationManaged = touch_mode && has_accelerometer && laptop_panel`）。
本机磁吸保护套的霍尔传感器被映射成 `SW_TABLET_MODE`，而 pogo 键盘的 USB HID
**开机就一直枚举、拔掉键盘也不会消失**，所以用户态无法可靠判断键盘是否在连接。

硬件事实（实测）：

- mainline DTB 只把 2 颗霍尔接到 input 开关：`switch-lid`（gpio110，`SW_LID`，合盖休眠）
  与 `switch-tablet-mode`（gpio121，`SW_TABLET_MODE`，保护套折到背面 = 1）；
  键盘套/普通保护套/断开键盘时两个开关读数相同，无法区分。
- 本包提供配置（`/etc/elish-orientation.conf` + `elish-camera-ctl orientation`）；
  `tablet_mode=on/off` 的生效依赖**设备侧** `elish-tablet-mode` helper（uinput 发布虚拟
  `SW_TABLET_MODE`，本机为系统侧 `/usr/local/bin/elish-tablet-mode-switch` + systemd 服务，
  **不随本包安装**；源码在本目录 `tools/tablet_mode_switch.c`，未纳入 `make`）。
  没有该 helper 时 `auto` 即跟随真实霍尔，`on/off` 不生效。
  配置命令：

```bash
elish-camera-ctl orientation                 # 图形设置面板（zenity）
elish-camera-ctl orientation tablet on       # 总是平板模式 -> 自动旋转开（无配置时按 on）
elish-camera-ctl orientation tablet off      # 关闭平板模式 -> 自动旋转关
elish-camera-ctl orientation tablet auto     # 跟随磁铁/保护套霍尔开关
elish-camera-ctl orientation rebuild idle    # 旋转时：空闲再重建相机流（默认）
elish-camera-ctl orientation rebuild live    # 旋转时：立即重建并自动重开 Snapshot
elish-camera-ctl orientation rebuild off     # 旋转时：不重建（方向保持旧值）
```

- 配置写在 `/etc/elish-orientation.conf`，后端（以及 helper 若在运行）会自动读取（1–2 秒内生效）；
- 虚拟开关**只发布 `SW_TABLET_MODE`，不碰 `SW_LID`**；合盖休眠仍由真实霍尔
  `SW_LID` → logind 处理（helper 对 gpio-keys 只读、不 grab 设备）。
- `live` 模式会 `flatpak kill` 再重开 Snapshot（约 2–3 秒黑屏）；
- `idle` 模式不打断正在预览的 App，相机空闲后自动按新方向重建，下次打开即正确。

## 屏幕方向 / 画面旋转（自动）

后端启动时读取 GNOME Mutter 的显示方向（`DisplayConfig` transform；无桌面会话时退回 xrandr
几何），自动给前后摄选旋转角，使**竖屏/横屏使用都是正的**：

| 显示 transform | 前摄 | 后摄 |
|---|---|---|
| 0（横屏） | 180° | 180° |
| 1（竖屏，旋转 90°） | 90° | 90° |
| 2（横屏倒置） | 0° | 0° |
| 3（竖屏，旋转 270°） | 270° | 270° |

- `photo`/`record`/`stream` 未显式给 `--rotate` 时按此自动选择；
- autoserve 每 4 s 轮询显示 transform，屏幕旋转后按 `rebuild_mode` 自动重建流
  （`idle` 等空闲、`live` 立即重建）；也可手动 `elish-camera-ctl start` 重新配置；
- 个别方向仍不对（相机模组校准差异）时可手动指定并持久化：

```bash
elish-camera-ctl rotate front 90     # 立即重启后端并重开对应相机（front|rear, 0/90/180/270/auto）
elish-camera-ctl rotate rear 90
```

## Flatpak / portal App

autoserve 除了两个 V4L2 虚拟相机，还会发布**两个原生 PipeWire 相机节点**
（`Elish Front Camera` / `Elish Rear Camera`，NV12 全分辨率，EnumFormat 完整、
`media.role=Camera`、`api.libcamera.location` 标记前/后）。Flatpak/portal App
（已实测 GNOME Snapshot 51）能枚举、预览、切换前后摄；切换/拍照时 autoserve
自动路由传感器。

> 为什么用自研 PipeWire 节点：v4l2loopback 经 WirePlumber 发布的节点不暴露 EnumFormat（空 caps），
> GStreamer/aperture 系的 App 会把它们过滤掉（“未找到摄像头”）。原生节点提供完整 caps 解决此问题。

Snapshot 默认相机由 GSettings 记住，可设为前摄：
`flatpak run --command=gsettings org.gnome.Snapshot set org.gnome.Snapshot last-camera-id 'Elish Front Camera'`。
完整兼容矩阵与 portal 说明见 [`docs/interface.md`](docs/interface.md)。

## 编码与封装限制

- **周期 I 帧不是 IDR**：mainline venus 把 HFI IDR period 硬编码为 0；
  `record --keyint N` 每 N 帧发 `force_keyframe` 产生真 IDR（`ELISH_ENC_FORCE_IDR=N` 等同）。
- **H.264 全分辨率 4208×3120**：可编码/软解，但超出 H.264 level 5.1 MaxFS，SPS 只能标 5.1，
  严格合规的播放器可能拒绝；需要合规时用 HEVC 或降到 ≤4096×2304。
- **H.264 CBR 欠冲约 12–16%**（HEVC 偏差 ±0.7%），是固件 CBR 特性；需要严格码率时优先 HEVC。
- **病态内容**（均匀随机噪声）单帧可能超过 capture buffer，固件静默返回空帧；
  真实相机内容远达不到该量级，不影响正常录制。
- **MP4 时间戳**：raw ES 无时间戳，`elish_mux_mp4()` 用 ffmpeg `setts` 按 `ELISH_MUX_FPS`
  （默认 30）打 CFR 时间戳后 `-c copy`，不重编码；掉帧时不会“加速播放”。

## 目录结构

```
include/elish_camera.h   公共 API（改前先看 docs/architecture.md）
src/capture.c            CAMSS raw 采集 + media graph + 传感器控制
src/gpu_debayer.c        GPU debayer / NV12 / RGB888 / 场景统计
src/venus_enc.c          Venus 硬件 H.264/HEVC 编码 + MP4
src/loopback.c           v4l2loopback 虚拟相机生产者
src/pwcam.c              原生 PipeWire 相机节点
src/main.c               CLI + AE/AWB + PNG + 线程化推流 + autoserve
tools/                   各模块独立测试（debayer_test/enc_test/loopback_test/capture_test）
tools/android_tuning/    本机只读调校提取/生成脚本
docs/                    architecture.md、interface.md、evidence/（Chromatix/EEPROM 只读解析脚本）
testdata/                少量 raw 测试帧（不随包；用 build/capture_test 自采）
```

## 硬件访问与注意事项

- 实机访问加 flock（见 `docs/architecture.md` §8）。
- 不要改 DTB/内核模块、不要重启、不要装 `libspa-0.2-libcamera`（会破坏本管线）。
- 前后摄不能同时出流；切换相机重新打开对应设备即可（autoserve 自动路由）。
- 前摄必须 `vertical_flip=0`（vflip=1 时全分辨率无帧，已在代码中固定）。
- 本机磁盘有限：测量/测试不要生成大 PPM/NV12 文件。

## 模块测试工具

```bash
./build/debayer_test testdata/front-3280x2464-sgrbg10.raw --input 3280x2464 --stride 4112 \
    --bayer bggr --rotate 180 --out-ppm /tmp/f.ppm --frames 20
./build/enc_test --size 4208x3120 --frames 90 --synthetic black --out /tmp/e.h265 --mux /tmp/e.mp4
./build/loopback_test --dev /dev/video2 --size 1280x720 --fps 30 --seconds 10 --pattern bars
./build/capture_test --camera front --frames 30 --out /tmp/cap
```
