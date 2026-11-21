# Hi556 景深相机 DTB 补丁（已合并进联合 DTB）

Hi556 是 elish（Xiaomi Pad 5 Pro / SM8250 / CSOT）的 5MP 景深摄像头（Hynix，CCI0 / CSIPHY0 / 2-lane），
Linux 侧由 mainline `drivers/media/i2c/hi556.c` 驱动。本目录的 DTS 补丁为联合 DTB **纯新增**供电、
I2C、MCLK、reset 与 CAMSS 连接节点（+7 节点 / +1 phandle / 0 改动 / 0 删除）。

> 包内只有一份模型级联合 DTB `../sm8250-xiaomi-elish-csot.dtb`
> （sha256 `0d639355650ad34ef3a03ed6af44f4fd2e1ec287aadd543a7c707238f8b544e8`，139,091 B），
> **已合并 Hi556 stage2 节点**，无需再单独应用 Hi556 补丁。本目录只保留构建/校验/回滚脚本，
> 供审计补丁内容或从旧基线重建时使用；`.dts`/`.patch`/`.dtso` 文本不随包。

## 实机验证结果（2026-11-20）

| 项 | 结果 |
|---|---|
| probe | `hi556 21-0020` 出现并绑定 `hi556` 驱动（compatible `hynix,hi556`）；`ldoc2` 注册为 `vreg_l2c_1p2`（1.2 V，HPM） |
| 出流 | RAW10 2592×1944 `SGRBG10_1X10`；30 帧约 27 fps（模式 30 fps，含启动开销） |
| media 链路 | `hi556 21-0020 (/dev/v4l-subdev26) → msm_csiphy0 → msm_csid0 → msm_vfe0_rdi2 → /dev/video3` |
| 数据通路 | sensor `test_pattern=7`（Check Board）解包为清晰棋盘格 → MIPI lane/CSID/VFE 正确 |
| 前后摄回归 | 无回归：后摄 4208×3120、前摄 3280×2464 的拍照与 3 s 录像正常 |
| 用户态 | **仅 RAW 出流**；Linux 下无 3A/彩色/深度管线（Android 深度算法属闭源 CAMX/CHI） |

## DTS 补丁内容

| # | 节点路径 | 关键属性 |
|---|---|---|
| 1 | `/soc@0/rsc@18200000/regulators-1/ldo2` | `regulator-name="vreg_l2c_1p2"`、min 1200000 / max 1304000、`initial-mode=<3>`（RPMH HPM） |
| 2 | `/soc@0/geniqup@8c0000/i2c@884000/pmic@8/regulators/ldo3`（PM8008 L3P） | 仅新增 `phandle`（该节点原未被引用）；不改原有电压 |
| 3 | `/soc@0/pinctrl@f100000/cam-mclk1-default-state` | `pins="gpio95"`、`function="cam_mclk"`、drive-strength 4、bias-disable |
| 4 | `/soc@0/pinctrl@f100000/camera-depth-active-state` | `pins="gpio26"`、`function="gpio"`、drive-strength 2、bias-disable |
| 5 | `/soc@0/cci@ac4f000/i2c-bus@1/camera@20` | `compatible="hynix,hi556"`、`reg=<0x20>`、三路 supply（`avdd`=L3P 2.8V、`dovdd`=L1C 1.8V、`dvdd`=L2C 1.2V）、`clocks=<&camcc CAM_CC_MCLK1_CLK>`（19.2 MHz）、`clock-names="clk"`、`reset-gpios=<&tlmm 26 GPIO_ACTIVE_LOW>`、两个 pinctrl、endpoint `data-lanes=<1 2>`、`link-frequencies=<437000000>` |
| 6 | `/soc@0/camss@ac6a000/ports/port@0/endpoint` | `clock-lanes=<7>`、`data-lanes=<0 1>`、`bus-type=<4>`（D-PHY）、`remote-endpoint` → Hi556 endpoint |

节点由 `hi556-build-dtb.py` 生成，phandle 由脚本分配并校验全局唯一（基线最大 `0x1106`，新增 `0x1200`–`0x1205`）。
驱动侧要求已逐条核对：mainline `hi556.c` 强制 2 lane、437MHz link freq、三路 supply 名 `dovdd/avdd/dvdd`、
`clock-names="clk"`（非 `xvclk`）、`hynix,hi556` OF match；已装 `hi556.ko` 含包内 `0008-hi556-of.patch`。

## 如何应用

### 方案 1：直接用包内联合 DTB（推荐；已含 Hi556）

DTB 是打进 boot 镜像的（内核未开 `CONFIG_OF_OVERLAY`），所以要让改动生效必须重建启动槽：

```bash
sudo ./kernel/install-dtb.sh --write-boot   # 更新 DTB + 重建 Linux 启动槽（自动检测/备份/回读校验）
sudo reboot
```

校验（复位后）：

```bash
# 联合 DTB 不变量：传感器 vmids/fastrpc、指纹、L10A/L10C、GNSS 全部 OK
./kernel/dtb/verify-combined-dtb.sh /usr/lib/linux-image-$(uname -r)/qcom/sm8250-xiaomi-elish-csot.dtb
# Hi556 节点（verify 脚本不断言相机）：应输出 hynix,hi556
fdtget -t s /usr/lib/linux-image-$(uname -r)/qcom/sm8250-xiaomi-elish-csot.dtb \
  /soc@0/cci@ac4f000/i2c-bus@1/camera@20 compatible
# 驱动 probe 与出流
dmesg | grep -iE 'hi556|cci|camss|csiphy' | head -40
ls -l /sys/bus/i2c/devices/ | grep 21-0020       # cci0 i2c-bus@1 预计是 i2c-21
```

手动抓 Hi556 RAW（与前后摄共用 CSID0/VFE0，先停相机栈）：

```bash
elish-camera-ctl stop
v4l2-ctl -d /dev/video3 --set-fmt-video=width=2592,height=1944,pixelformat=pgAA \
  --stream-mmap --stream-count=30 --stream-to=/tmp/hi556.raw
elish-camera-ctl start     # 抓完恢复，否则 link ENABLED 时 media-ctl 会报 EBUSY
```

### 方案 2：从旧基线重建（仅当基线不含 Hi556 时）

```bash
# 默认 fdt：libfdt 直接在基线上增补，最稳；只读基线，不写 /boot
python3 kernel/dtb/hi556/hi556-build-dtb.py --base <旧基线.dtb> \
  --out /tmp/hi556.dtb --verify-combined
# 需要 DTS 文本审计/再编辑：--method dtc --emit-dts /tmp/hi556.dts
# 评估离线 overlay 路线：--method dtbo --emit-dtso /tmp/hi556.dtso（不作为主路径）
```

脚本会做"只增不丢"校验与 dtc 往返修复（唯一已知往返损坏点是 `regulators-1/ldo10` 的 4 字节电压，
脚本按基线字节还原；其余属性字节级一致），最后跑 `../verify-combined-dtb.sh` 全量校验。
生成后可用 `hi556-apply-dtb.sh` 安装/回滚（默认 dry-run，`--write-boot` 才写盘并自动备份到
`/root/hi556-dtb-backup/<时间戳>/`，只写 `armbianEnv` 指定的 Linux 槽、不碰 Android 槽）：

```bash
./kernel/dtb/hi556/hi556-apply-dtb.sh                          # dry-run
sudo ./kernel/dtb/hi556/hi556-apply-dtb.sh --write-boot
sudo ./kernel/dtb/hi556/hi556-apply-dtb.sh --rollback --write-boot
```

脚本仍保留 `--stage 1`（只加 ldo2/pinctrl/CCI0 传感器节点，不接 camss）：旧基线重建时先 stage1 验 probe、
成功后再 stage2（见下）。

## 注意事项

- **camss async notifier 依赖**：camss 要把 `camss/ports/*/endpoint` 上的所有 sensor 都 probe 成功，
  才会注册 subdev 节点/link。stage2 接入后若 Hi556 probe 失败，前摄/后摄也会一起不可用；因此旧基线
  重建请先 stage1 验 probe。包内联合 DTB 已验证 probe 成功，直接用即可。
- I2C 7bit 地址为 `0x20`；若 no-ack，`i2cdetect -y 21` 扫 `0x20`/`0x24`，必要时改 `reg` 重建。
- CSIPHY0 物理 lane 沿用前置 OV8856 的映射（sensor `<1 2>` / camss `<0 1>`）；若 CSID 报 CSI2 错误/无帧，
  按实际接线改 endpoint `data-lanes`。
- 供电时序：mainline `hi556.c` 为 clk → 三路 regulator → reset；probe 读 ID 失败时先查 regulator/GPIO。
- 与前后摄共用 CSID0/VFE0：手动抓流前后务必 `elish-camera-ctl stop` / `start`。
- **禁止 dtc 往返**改属性（会破坏 `regulators-1/ldo10` 的 4 字节电压），改属性用等长二进制替换或完整源码重编，
  见 `../README.md`。

## 文件

| 文件 | 说明 |
|---|---|
| `hi556-build-dtb.py` | 构建+校验工具：`--method fdt/dtc/dtbo`、`--stage 1/2`、`--check-only`、`--emit-dts/--emit-dtso`、`--verify-combined` |
| `hi556-apply-dtb.sh` | 应用/回滚脚本（默认 dry-run；`--write-boot` 才写盘；自动备份 + 调 `../../update-boot-image.sh` + 回读校验） |
| `README.md` | 本文档 |
