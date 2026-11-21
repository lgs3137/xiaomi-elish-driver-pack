# 相机对外接口（第三方 App）

> 当前实现事实（2026-11-21，包版本 2026.11.21）。架构与实测数据见 [`architecture.md`](architecture.md)，
> 构建/CLI 用法见 [`../README.md`](../README.md)。
> 本文只描述**现在系统里存在、已验证的接口**，不再保留历史方案对比。

## 0. 摘要

1. **两路标准 V4L2 虚拟相机**（v4l2loopback，生产者 `elish-camera` 常驻推 NV12）：
   - `/dev/video2` = `Elish Front Camera`；
   - `/dev/video20` = `Elish Rear Camera`。
   原生 V4L2 App（ffmpeg、GStreamer `v4l2src`、Guvcview 等）直接读这两个设备。
2. **两个原生 PipeWire 相机节点**（`elish-camera autoserve` 发布）：
   `elish-camera-front` / `elish-camera-rear`，描述 `Elish Front Camera` / `Elish Rear Camera`，
   NV12 全分辨率，`media.class=Video/Source`、`media.role=Camera`、
   `api.libcamera.location=front|back`，**EnumFormat 完整**，可在 Camera portal 的 fd 中枚举。
3. **Flatpak / portal App 走 Camera portal**（`org.freedesktop.portal.Camera` →
   `AccessCamera` → `OpenPipeWireRemote` → PipeWire fd），GNOME Snapshot 51 已实测
   预览/切换前后摄/拍照可用。
4. **一次只能一路相机出流**（两个 sensor 共享 CAMSS/DTB 资源）；切换约 1–2 s。
5. **生产者必须先 `STREAMON`**（autoserve 启动时即完成并填黑帧）：没有生产者时消费者会拿到 `EINVAL`。
6. **不要升级 WirePlumber、不要装 `libspa-0.2-libcamera`**：现有组件足够，装了反而破坏本管线。

## 1. 设备与格式

| 项 | 值 |
|---|---|
| 模块 | v4l2loopback（参数持久化在 `/etc/modprobe.d/elish-vcam.modprobe.conf`） |
| 模块参数 | `video_nr=2,20 card_label="Elish Front Camera,Elish Rear Camera" exclusive_caps=0 max_buffers=16 max_width=8192 max_height=8192` |
| `/dev/video2` | 前摄，默认 NV12 **3280×2464@30** |
| `/dev/video20` | 后摄，默认 NV12 **4208×3120@30** |
| 格式 | 只有 **NV12**（planar，`bytesperline == width`，无 stride 补齐） |
| 设备名 | 由 `card_label` 在 modprobe 时决定，运行中改不了 |

- 分辨率/帧率由**生产者**（`elish-camera serve` / `stream` / `record --loopback`）决定；
  消费者 `VIDIOC_S_FMT` 只被回显，改不了实际格式。
- 生产者不运行时，设备仍存在但 CAPTURE 端 `G_FMT/S_FMT` 返回 `EINVAL/EBUSY`。
  autoserve 启动时即打开两个 loopback 并填黑帧（消费者随时可打开），检测到消费者后
  再启动对应 sensor 出流；没有消费者时停流省电。
- 同一时刻只允许一路 sensor 出流；两个设备被同时打开时，只有**最后打开**的那个有画面。

### v4l2loopback 生产者语义（`src/loopback.c` 的实现依据）

1. 格式由生产者 `S_FMT(OUTPUT)` 决定，消费者 `G_FMT(CAPTURE)` 看到的就是它。
2. NV12 是 PLANAR 注册：`sizeimage = width*height*3/2`，无 stride 补齐；调用方 stride
   大于 width 时 `elish_lb_push_nv12()` 按行重排。
3. 生产者 `STREAMON(OUTPUT)`（或首次 `write()`）后 `ready_for_capture` 才置 1，
   在此之前消费者打开会失败。
4. OUTPUT 队列没有「空闲 buffer」语义：push 循环 round-robin 填 4 个 buffer + `QBUF`。
5. 多消费者：每个 CAPTURE `open()` + STREAMON 的进程都能读到同一路帧（内核分发，
   上限为模块 `max_openers`，默认 10）。
6. 帧率用 `S_PARM(OUTPUT)` 设置，消费者可读到 30 fps；没有 `V4L2_CAP_TIMEPERFRAME`
   标志的 App（如 Guvcview）改不了 fps，但仍按推送节奏取帧。
7. 生产者关闭后格式不会立刻复位，下一个生产者应自己 `S_FMT`；消费者不要假设默认格式。

## 2. 消费者兼容矩阵

| App 类型 | 使用接口 | 本机状态 | 说明 |
|---|---|---|---|
| 原生 Linux App（ffmpeg / GStreamer / Guvcview 等） | V4L2 `/dev/video2`、`/dev/video20` | ✅ 已实测 | NV12 30 fps，1080p/3280×2464/4208×3120 均可 |
| 多消费者并发 | V4L2 | ✅ 已实测 | 3 个消费者同时读仍 30 fps |
| 纯 PipeWire 客户端 | WirePlumber 发布的 v4l2 节点 | ⚠️ 能用但受限 | 节点存在，但**没有 EnumFormat（空 caps）**；GStreamer/aperture 系会过滤掉。优先用 autoserve 原生节点或直接读 V4L2 |
| Flatpak / portal App（GNOME Snapshot、Cheese 等） | Camera portal → PipeWire fd | ✅ 已实测（Snapshot 51） | 用 autoserve 发布的原生节点；见 §3 |
| Flatpak App 直接读 `/dev/video*` | 无（sandbox 隔离） | ❌ | 需要 `--device=all`，不推荐；应走 portal |
| 只支持 YUYV/MJPEG 的 App | V4L2 | ⚠️ 需适配 | 设备只提供 NV12；需生产者侧转换或第二路设备 |
| libcamera 原生 App | libcamera | ❌ | 未装 `libspa-0.2-libcamera`，raw sensor 不直出；走 NV12 虚拟相机 |
| COSMIC 等非 GNOME 桌面 | portal backend | ⚠️ 未验证/受限 | 本包只在 GNOME 46（xdg-desktop-portal-gnome 46.2）上验证 |

## 3. Flatpak / portal 现状

- Camera portal（version 1，xdg-desktop-portal 1.18.4）接口：
  `IsCameraPresent`（本机 `true`）、`AccessCamera`（权限请求）、`OpenPipeWireRemote`（受限 fd）。
- 端到端已验证：`IsCameraPresent=true` → `OpenPipeWireRemote` 返回可用 fd →
  `pipewiresrc fd=<fd>` 取到 NV12 全分辨率帧；GNOME Snapshot 51（Flatpak）能枚举两个相机、
  预览、切换前后摄、拍照。
- **为什么需要原生 PipeWire 节点**：v4l2loopback 节点经 WirePlumber 发布后不暴露
  `SPA_PARAM_EnumFormat`（空 caps），aperture 系 App 会把它们过滤掉（显示“未找到摄像头”）。
  autoserve 发布的原生节点 caps 完整，portal fd 中可见。
- **镜像方向**：节点带 `api.libcamera.location`（前摄 `front`、后摄 `back`）；aperture 系 App
  据此只对前摄做水平镜像。缺该属性时两个预览都会被镜像。
- **默认相机**：Snapshot 用 GSettings 记住上次相机，可预设前摄：
  `flatpak run --command=gsettings org.gnome.Snapshot set org.gnome.Snapshot last-camera-id 'Elish Front Camera'`。
- **权限**：沙箱 App 首次使用会弹 portal 权限对话框，需要有人点允许；主机（非沙箱）应用
  首次授权较宽松，但**不要依赖**这种行为。预先授权可用
  `flatpak permission-set camera <app-id> camera yes`（本机未实测）。
- 同一时刻只有一路 sensor 出流：App 能枚举到两个原生节点，autoserve 按「哪个节点被消费」路由 sensor，
  另一个节点保持空闲（无画面）。

## 4. 常用命令

```bash
# 启动/管理常驻后端（autoserve：两个 V4L2 设备 + 两个 PipeWire 节点 + 自动路由）
elish-camera-ctl start [--front-size WxH --front-fps N --rear-size WxH --rear-fps N --autofocus]
elish-camera-ctl status        # 后端 + /dev/video2,20 + consumers + 节点
elish-camera-ctl stop

# 原生 V4L2 消费者
ffmpeg -f v4l2 -input_format nv12 -video_size 3280x2464 -i /dev/video2 -frames:v 10 /tmp/f-%02d.png
gst-launch-1.0 -q v4l2src device=/dev/video2 num-buffers=30 ! fakesink
guvcview --device=/dev/video20

# 直接消费原生 PipeWire 节点（用 object.serial；用 wpctl/pw-dump 查）
gst-launch-1.0 -q pipewiresrc target-object=<serial> num-buffers=30 ! fakesink

# 生产者自检工具（在 elish-camera/ 目录下构建后运行）
build/loopback_test --dev /dev/video2 --size 1920x1080 --fps 30 --seconds 10
```

本机环境基线：kernel `6.18.44-current-sm8250`、v4l2loopback 0.12.7、
PipeWire 1.0.5 + WirePlumber 0.4.17、xdg-desktop-portal 1.18.4、portal-gnome 46.2、Flatpak 1.14.6。

## 5. 限制与排障

| 现象 | 原因 / 处理 |
|---|---|
| 消费者先打开报 `ioctl(VIDIOC_G_FMT): Invalid argument`（rc=234） | 生产者还没推流；让 autoserve 常驻，生产者先 STREAMON |
| 打开设备后 1–2 s 才出画面 | autoserve 检测 + 切 sensor 的正常延迟；不是故障 |
| 两个相机设备同时打开只有一个有画面 | 硬件/camss 限制，一次一路 |
| Guvcview 里改不了分辨率/帧率 | 格式由生产者决定；用 `elish-camera-ctl` 改后端配置 |
| Flatpak App 里看不到相机 | 确认 autoserve 已启动、两个原生 PipeWire 节点存在；aperture 系 App 会过滤空 caps 节点 |
| `pipewiresrc target-object=<node.name>` 连接失败 | 用数字 `object.serial`（GStreamer 侧限制）；沙箱 App 应走 portal |
| 直接（非 portal）PipeWire 访问受限 | 沙箱 App 走 portal；原生 App 优先直接读 V4L2 |
| 装 `libspa-0.2-libcamera` 后异常 | 不要装：会引入 libcamera 相机路径并干扰现有节点 |
