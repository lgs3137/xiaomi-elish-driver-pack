# elish-camera 架构与实现事实

> 适用：Xiaomi Pad 5 Pro（SM8250 / elish）、Armbian noble、内核 `6.18.44-current-sm8250`；
> 包版本 2026.11.21。本文只记录**当前实现事实与设计依据**；对外接口/消费方式见
> [`interface.md`](interface.md)，构建与用法见 [`../README.md`](../README.md)。

## 1. 传感器与 media graph

### 前摄 OV8856
- entity `ov8856 23-0010`，subdev `/dev/v4l-subdev24`
- 链路（单相机模式）：CSIPHY4（subdev4）→ CSID0（subdev6）→ VFE0 RDI0 → `/dev/video0`
- 2-lane；模式：**3280×2464@30fps**、1640×1232
- raw：**pBAA**（MIPI RAW10 packed），3280×2464 stride **4112**，单帧 10,131,968 B
- 实际 CFA 顺序：**BGGR**（见 §2.1）
- 控制：`exposure` 6..2482、`analogue_gain` 128..2047、`digital_gain` 0..4095；
  **必须 `vertical_flip=0`**（见 §2.2）
- 固定焦点镜头，无 AF 硬件。

### 后摄 OV13B10
- entity `ov13b10 20-0010`，subdev `/dev/v4l-subdev25`
- 链路：CSIPHY1（subdev1）→ CSID0 → VFE0 RDI1 → `/dev/video1`
- 4-lane；模式：**4208×3120@30fps**、4160×3120、4160×2340、2104×1560@60、2080×1170、1364×768@120
- raw：**pgAA**（packed，SGRBG），4208×3120 stride **5264**，单帧 16,423,680 B
- 实际 CFA 顺序：**GRBG**（见 §2.1）
- 控制：`exposure` 6..3188、`analogue_gain` 128..1984、`digital_gain` 1024..4095
- 对焦：CN3927V VCM，sysfs `/sys/bus/i2c/devices/20-000c/focus`（0..1023，非标准 V4L2）；
  软件扫焦实测室内目标最佳 **focus=640**，`elish-camera focus --camera rear` 一次扫焦写入。
- EEPROM：24c64 @ 0x51（8 KB）。LSC/CCM 调校数据**不随包**，只提供本机只读提取脚本
  （[`../tools/android_tuning/README.md`](../tools/android_tuning/README.md)）；提取后默认启用，
  后摄暗角 **4.4× → ~1×**，`ELISH_LSC=0` / `ELISH_CCM=0` 可关闭。

### Hi556 景深（已实测 RAW 出流）
- 已合并进包内**单一联合 DTB** `kernel/dtb/sm8250-xiaomi-elish-csot.dtb`（模型级，无本机私有信息）。
- 链路：`hi556 21-0020` → CSIPHY0 → CSID0 → VFE0 RDI2；2-lane / 437 MHz。
  Android 侧对应：CCI1 i2c0、MCLK2 GPIO95、reset GPIO26、avdd=PM8008 L3P 2.8V、
  dovdd/dvdd=PM8150A L1/L2（= RPMH `ldoc2` 1.2V）。
- 上电顺序：3 路供电 → MCLK → **最后**释放 reset（与 OV8856/OV13B10 相反）。
- 实测：stage1 probe、stage2 接 camss 均正常，RAW10 **2592×1944 SGRBG10 @ ~30 fps**，
  checker test pattern 校验通过（2026-11-20）。
- 早期“卡在 PM8150A L1/L2 供电”的结论已纠正：Android 的 `pm8150a_l2` 即 RPMH `ldoc2`（1.2V），
  mainline 驱动已支持，当时只是 DTS 缺节点；不存在与 USB PHY 的供电冲突。
- 当前只到 **RAW 出流**：无 3A/彩色/深度用户态。生成/应用脚本见
  `kernel/dtb/hi556/README.md`。

### 前后摄互斥（实测结论）
- 两个 sensor **不能同时出流**：后摄先开、前摄后开时，前摄一启动后摄立刻停流；
  反过来同理。原因在 CAMSS/DTB 共享资源，不是功耗。
- 但两个相机是**两个独立的标准 V4L2 设备**：`/dev/video2`（前）/ `/dev/video20`（后）。
  `elish-camera autoserve` 常驻并把「被打开的那个设备」映射到当前唯一可用的传感器：
  哪个设备有 consumer，就切到对应相机并给它喂帧；没有 consumer 时停流省电。
  因此第三方 App 只需打开想要的设备，不需要控制面板/脚本。
- 切换时仍必须 `media-ctl -d /dev/media0 -r` → 重新配置链路 → 设格式 → 开流。

## 2. 关键坑（全部实测）

### 2.1 Bayer 顺序（决定颜色是否正确）
- 方法：对同一帧 raw 统计 4 个 2×2 相位均值。Bayer 的两个绿色相位应几乎相等。
- 结果：前摄 `m(0,1)≈m(1,0)`（差 0.0）→ 绿在 (0,1)/(1,0) → **BGGR**；
  后摄 `m(0,0)≈m(1,1)`（差 1.2）→ 绿在 (0,0)/(1,1) → **GRBG**。
- 用错会得到紫/绿色偏；灰世界 AWB 无法纠正 R/B 互换造成的肤色错误。
- 驱动上报的 media bus code（前摄 SBGGR / 后摄 SGRBG）只用于 CSI 路由，不等于物理 CFA 顺序。

### 2.2 前摄全分辨率无帧的回归
- 把 `V4L2_CID_VFLIP` 默认值设成 1 时，**vflip=1 下 3280×2464 模式 STREAMON 成功但永远没有 DQBUF**。
- 本管线每次打开都显式 `vertical_flip=0`（`capture.c`）；vflip=0 时 30 fps 正常。

### 2.3 其它
- `BG10`（16-bit plain Bayer）`VIDIOC_S_FMT` 接受但不出帧；GPU 输入必须 packed RAW10。
- 不要用 GStreamer `glshader` 做 debayer（只接受 RGBA）。
- `media-ctl -V` 设错 mbus code ⇒ STREAMON `-32 EPIPE`。
- 方向由显示 transform 自动选择（见 `../README.md`「屏幕方向」）；CLI `--rotate` 可覆盖。
- **Venus 设备号不跨启动稳定**：重启后 encoder/decoder 的 video 节点编号可能互换。
  必须按 sysfs 名字 `qcom-venus-encoder` / `qcom-venus-decoder` 发现，不要硬编码。
- 采集偶发无帧：已加 2 s poll 超时 + 自动重配重试（最多 3 次）。

## 3. GPU（Adreno 650 / FD650）

- Mesa 25.2.8，EGL 1.5，GBM surfaceless 可无显示器建 context；renderer `FD650`；GLES 3.2。
- 自研管线：packed RAW10 在 GPU 内解码 → 双线性去马赛克 → WB/gamma → NV12 或 RGB888；
  旋转在 shader 内完成（rot90/270 与 rot0/180 差异 <5%）。
- 关键优化：`glReadPixels` 仅 ~0.8–0.9 GB/s；改为 `/dev/dma_heap/system` 的 dma-buf +
  EGLImage render target（CPU cached mmap ~10 GB/s），Y/UV 同 buffer + `DMA_BUF_IOCTL_SYNC`，
  再按行拷进调用方 NV12 缓冲。若用 `glReadPixels`，前摄会到 ~24–27 ms、后摄 ~35–40 ms，
  达不到 30 fps 预算——这是选 dma-buf 的直接原因。
- 实测 NV12 全流程（GPU 渲染 + 回读 + stride 组装，含系统负载）：前摄 3280×2464
  **11.0–12.1 ms/帧**（p95 ≤14.7）；后摄 4208×3120 **18.7–19.8 ms/帧**（p95 ≤22.1）。
  RGB888 静照：前摄 ~13 ms、后摄 21–26 ms。
- 场景统计 `elish_gpu_stats`：三趟固定 4×4 kernel GPU 降采样（1024 block 均值 → 256 → 64 →
  回读 16 KB），量纲为「减黑电平 64/1024 → clamp≥0 → 乘 WB gain」的 pre-gamma 线性均值
  （10-bit RAW/4 → 0..255），`mean_y` 用 Rec.601 加权；单次 ~5.6–7.8 ms，每 8 帧调一次
  （摊到每帧 ~0.7 ms）。
- dma-buf 一致性用 `--verify` 验证：同输入 60 帧 checksum 恒定、交替输入逐帧一致，无旧帧/花屏。

## 4. Venus 硬件编码

- 节点按 sysfs 名发现（`qcom-venus-encoder`，video 节点号随启动变化），
  V4L2 stateful M2M multi-planar；OUTPUT 只接 NV12，CAPTURE 支持 H.264 / HEVC / VP8。
- 驱动把请求尺寸向上对齐（宽 128、高 32），再用 `VIDIOC_S_SELECTION` crop 回请求尺寸，
  因此码流尺寸精确：4208×3120（padded 4224×3136）、3280×2464（padded 3328×2464）。
- 吞吐（真实 sensor 内容，90 帧不限速）：后摄 4208×3120 HEVC **90.6 fps** / H.264 94.4 fps；
  前摄 3280×2464 HEVC **135 fps** / H.264 136 fps。
- 实时 30 fps 节拍下 0 丢帧、0 固件跳帧（端到端 28.9–29.2 fps，最坏迟到 ≤17.6 ms < 33.3 ms）；
  单次 `elish_enc_push_nv12()` p95 4.7–8.1 ms。码流可被 ffmpeg 软解，MP4 可播。
- 编码器行为/限制：
  - mainline venus 把 HFI IDR period 硬编码为 0，**周期 I 帧不是 IDR**；
    `force_keyframe`（`--keyint N` / `ELISH_ENC_FORCE_IDR=N`）可产生真 IDR。
  - H.264 全分辨率 4208×3120 超出 level 5.1 MaxFS（可编码/软解，但 SPS 只能标 5.1，
    严格合规的播放器可能拒绝）；需要合规时用 HEVC 或降到 ≤4096×2304。
  - H.264 CBR 在该内容下欠冲约 12–16%（HEVC 偏差 ±0.7%）；这是固件 CBR 特性，不是 bug。
  - 病态内容（均匀随机噪声）单帧可超过 capture buffer 大小，固件会静默返回 empty 帧
    （`venus: warning: firmware returned an empty (not coded) frame`）；真实相机内容远达不到该量级。
  - 冷启动首帧 ~0.85 s（固件首次加载），之后每次 start 首帧 56–93 ms。
- MP4 封装：raw ES 无时间戳，`elish_mux_mp4()` / `tools/mux_mp4.sh` 用 ffmpeg
  `setts` bitstream filter 按 `ELISH_MUX_FPS`（默认 30）打 CFR 时间戳后 `-c copy`，不重编码。

## 5. 对外接口（第三方 App）

- v4l2loopback（模块参数持久化在 `/etc/modprobe.d/elish-vcam.modprobe.conf`）：
  `/dev/video2` = Elish Front Camera，`/dev/video20` = Elish Rear Camera，均 NV12。
- `elish-camera serve --camera front|rear` 常驻推 NV12；`record --loopback` 也可推送。
- 原生消费者实测：ffmpeg / GStreamer v4l2src / Guvcview / 3 并发消费者均 30 fps。
- PipeWire：`elish-camera autoserve` **自己发布两个原生 PipeWire 相机节点**
  （`src/pwcam.c`）：`elish-camera-front` / `elish-camera-rear`，描述 `Elish Front/Rear Camera`，
  NV12 全分辨率，属性 `media.class=Video/Source`、`media.role=Camera`、`api.libcamera.location`
  （front/back，供 aperture 系 App 判断是否镜像）。
  原因：v4l2loopback 经 WirePlumber 发布的节点**不暴露 EnumFormat（空 caps）**，
  GStreamer/aperture 系 App（GNOME Snapshot）会过滤掉；原生节点 caps 完整，portal fd 中可见，
  Snapshot 可正常预览/拍照。
  WirePlumber 0.4.17 的 v4l2 monitor 仍会把 `/dev/video2/20` 发布成节点，供纯 PipeWire 客户端使用；
  autoserve 同时按 V4L2 打开和 PipeWire 节点消费两种事件路由传感器。
  **不需要升级 WirePlumber 0.5、不需要 libspa-0.2-libcamera。**
- xdg-desktop-portal Camera frontend 存在：`org.freedesktop.portal.Camera`
  （`IsCameraPresent` 属性 + `AccessCamera`/`OpenPipeWireRemote`）；本机 `IsCameraPresent=true`。
- Flatpak/portal 相机 App 的路由与授权见 [`interface.md`](interface.md)；不是后端缺失。

## 6. 代码结构

```
include/elish_camera.h   公共 API
src/capture.c            CAMSS 采集 + media graph + 传感器控制
src/gpu_debayer.c        EGL/GLES GPU debayer（NV12/RGB888/stats）
src/venus_enc.c          Venus V4L2 M2M 编码 + mp4 封装（ffmpeg stream copy）
src/loopback.c           v4l2loopback 生产者（NV12）
src/pwcam.c              原生 PipeWire 相机节点发布
src/main.c               CLI：list/photo/record/stream/serve/autoserve + AE/AWB + PNG
tools/*                  各模块测试工具 + android_tuning/ 调校提取脚本
docs/                    本文、interface.md、evidence/（Chromatix/EEPROM 只读解析脚本）
testdata/                少量 raw 测试帧（不随包；磁盘有限，勿堆大文件）
```

## 7. 测试帧（testdata/）

| 文件 | 尺寸 | stride | 说明 |
|---|---|---|---|
| front-3280x2464-sgrbg10.raw | 3280×2464 | 4112 | 前摄全分辨率（实际 BGGR） |
| front-1640x1232-sgrbg10.raw | 1640×1232 | 2064 | 前摄 binning |
| rear-4208x3120-sgrbg10.raw | 4208×3120 | 5264 | 后摄全分辨率（GRBG） |

> `testdata/` 不随包（磁盘有限）。需要时用 `build/capture_test --camera front|rear --frames N
> --out /tmp/cap` 从自己设备采集（生成 `/tmp/cap.raw`）。

MIPI RAW10 解码：4 像素/5 字节，`p0=(b0<<2)|(b4&3)`、`p1=(b1<<2)|((b4>>2)&3)`、
`p2=(b2<<2)|((b4>>4)&3)`、`p3=(b3<<2)|((b4>>6)&3)`，10-bit 值 0..1023。

## 8. 开发/协作约定

- 实机访问加 flock：`.locks/camera.lock`（media0/video0/video1）、`.locks/venus.lock`（编码器）、
  `.locks/loopback.lock`（/dev/video2/video20）。
- 禁止：改 DTB/内核模块/重启/装 `libspa-0.2-libcamera`；需要先确认。
- 磁盘有限：不要留大 PPM/NV12/PNG。
