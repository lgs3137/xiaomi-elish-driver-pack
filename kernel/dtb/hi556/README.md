> 包内路径说明（2026-11-20 合并入包时调整）：本目录脚本以包根为基准（`PKG_DIR` 自动取本目录的 `../../..`），
> 基线 DTB 为 `kernel/dtb/sm8250-xiaomi-elish-csot.dtb`；下文 §4.5 中的 `/home/...` 绝对路径已改为相对/`$PKG_DIR` 形式。
> 本功能为**实验性**：请先 dry-run、再分阶段 `--stage 1` 上机验证 probe，成功后才 `--stage 2`。

# Hi556 景深相机 DTS 补丁 + 联合 DTB 构建验证（task-8）

- 设备：Xiaomi Pad 5 Pro（elish / SM8250 / CSOT），Linux `6.18.44-current-sm8250`，联合 DTB 启动
- 目标：给景深相机 **Hi556** 产出可应用的 DTB/DTS 补丁（不刷机，交用户手动应用），并验证能编译出新 DTB
- 日期：2026-11-20
- 约束：全程只读分析，**未写 /boot、未写任何块设备、未 mount、未 sudo、未改 /usr 和驱动包**；
  所有构建/校验产物在 `/tmp/hi556` 与 `.work/android-cam-20261120/`；应用/回滚脚本默认 dry-run，
  只有用户显式 `sudo --write-boot` 才写盘。

---

## 0. 结论摘要（TL;DR）

| 项目 | 结论 |
|---|---|
| 联合 DTB 真实构建源 | **已丢失**（任何源码树都不含 rear OV13B10/CN3927V 等相机节点；包内脚本明确“不从 DTS 重建”）。已用 `dtc` 反编译部署 DTB **完整恢复出可编译源码**，并量化了 dtc 文本往返的唯一损坏点（2 个属性，可自动还原）。见 §2。 |
| DTB / DTS | 包内**单一联合 DTB** `../sm8250-xiaomi-elish-csot.dtb` 已合并 Hi556（sha256 `0d639355…`，模型级、非单机数据）；**DTS/patch/dtso 不随包**，需要时由脚本本地生成（`--emit-dts`/`--emit-dtso`）。见 §3。 |
| 新增内容 | `pm8150l rpmh ldoc2`（1.2–1.304 V，HPM）+ `&cci0`/`cci0_i2c1 camera@0x20(hynix,hi556)` + `&camss port@0`（CSIPHY0，2-lane D-PHY）+ pinctrl（MCLK1=gpio95 / reset=gpio26）。 |
| 构建验证 | 3 种方式（libfdt 直接增补 / dtc 源码编译 / fdtoverlay 离线合并）构建出的 DTB **语义完全一致**；与基线 diff = **+7 节点 / +1 属性 / 0 删除 / 0 改动**；`fdt_check_full` 通过；包内 `verify-combined-dtb.sh` 全部 OK。见 §4。 |
| 应用方式 | DTB → `/usr/lib/linux-image-$(uname -r)/qcom/` + `/boot/dtb-$(uname -r)/qcom/` → 包内 `update-boot-image.sh`（备份 boot 分区 + 重建 boot_b + 回读校验）→ 用户 `reboot`。见 §4.5。 |
| Armbian fdtoverlays/DTBO | **运行时不可用**：内核 `CONFIG_OF_OVERLAY` 未启用，启动链是 ABL + boot 镜像内追加 DTB（无 U-Boot/armbianEnv overlays）。离线 `fdtoverlay` 可行（已实测），但存在 **phandle 重映射陷阱**、风险不更低 → 不作为主路径。见 §5。 |
| 主要风险 | Hi556 I2C 0x20 应答（中高置信）、CSIPHY0 物理 lane 未知、以及 **camss async notifier 依赖**：stage2 若 Hi556 probe 失败会让前/后摄一起失效。→ 提供 **stage1/stage2 分阶段应用**。见 §6。 |

主要交付物（本目录，仅脚本/文档；DTB 已合并进包内单一联合 DTB）：

```
README.md             本报告 + 构建/应用方法
hi556-build-dtb.py    从旧基线本地生成/校验 DTB（--emit-dts/--emit-dtso 输出 /tmp）
hi556-apply-dtb.sh    从旧基线应用/回滚（包内联合 DTB 已含 Hi556，默认检测到后会直接退出）
```

> 包内 DTB：`../sm8250-xiaomi-elish-csot.dtb`，sha256 `0d639355…`，**单一联合 DTB 已合并
> Hi556 的 stage2 节点**（与基线同一模型级文件，不含单机校准/序列号）。
> DTS/patch/dtso 等从部署 DTB 导出的中间文本不随包，需要时用脚本生成到 `/tmp`。

---

## 1. 结论：补丁做了什么

在部署中的联合 DTB（`sm8250-xiaomi-elish-csot.dtb`，
sha256 `14909d42d6a1935f6dd49ff8b4700e0adf4164024c6f0c25f6ba94b6ad3ee4a8`）上**纯新增**：

| # | 节点路径 | 属性（值） | 依据 |
|---|---|---|---|
| 1 | `/soc@0/rsc@18200000/regulators-1/ldo2` | `regulator-name="vreg_l2c_1p2"`、`min=1200000`、`max=1304000`、`initial-mode=<3>`（RPMH HPM） | Android `rpmh-regulator-ldoc2`（`vb_a/vendor.dts:4369-4385`，1.200–1.304V）；mainline `qcom-rpmh-regulator.c:1022` 有 `RPMH_VREG("ldo2","ldo%s2",...)`；父 supply `vdd-l2-l3` 已在 DTS（`vreg_s8c_1p35`） |
| 2 | `/soc@0/geniqup@8c0000/i2c@884000/pmic@8/regulators/ldo3`（PM8008 L3P） | 仅新增 `phandle`（原 DTB 中该节点未被引用过、没有 phandle） | Hi556 `avdd` = Android `L3P` 2.8V；不改原电压值 |
| 3 | `/soc@0/pinctrl@f100000/cam-mclk1-default-state` | `pins="gpio95"`、`function="cam_mclk"`、`drive-strength=<4>`、`bias-disable` | Android `elish-sm8250-camera-board.dtsi:2-14` |
| 4 | `/soc@0/pinctrl@f100000/camera-depth-active-state` | `pins="gpio26"`、`function="gpio"`、`drive-strength=<2>`、`bias-disable` | Android `elish-sm8250-camera-board.dtsi:28-40` |
| 5 | `/soc@0/cci@ac4f000/i2c-bus@1/camera@20` | `compatible="hynix,hi556"`、`reg=<0x20>`、`avdd-supply=vreg_l3p`、`dovdd-supply=vreg_l1c_1p8`、`dvdd-supply=vreg_l2c_1p2`、`clocks=<&camcc CAM_CC_MCLK1_CLK>`(75)、`clock-names="clk"`、`assigned-clock-rates=<19200000>`、`reset-gpios=<&tlmm 26 GPIO_ACTIVE_LOW>`、`pinctrl-0=<&cam_mclk1_default &camera_depth_active>`、endpoint `data-lanes=<1 2>`、`link-frequencies=<437000000>` | Android `elish-sm8250-camera-sensor-mtp.dtsi:146-185`（csiphy 0 / cci-master 1 / gpio95 / gpio26 / 19.2MHz / pm8150a_l1+L3P+pm8150a_l2）+ `drivers/media/i2c/hi556.c` |
| 6 | `/soc@0/camss@ac6a000/ports/port@0/endpoint` | `clock-lanes=<7>`、`data-lanes=<0 1>`、`bus-type=<4>`（D-PHY）、`remote-endpoint` → Hi556 endpoint | mainline `elish-common.dtsi:1268-1290` 的 port@4（OV8856）同构；sensor 侧 1-based、camss 侧 0-based 是上游 Qualcomm 惯例（对照 `qrb5165-rb5-vision-mezzanine.dtso:22/57`） |

phandle 分配（基线最大 `0x1106`）：`ldo2=0x1200`、`hi556_ep=0x1201`、`cam_mclk1=0x1202`、
`camera_depth=0x1203`、`csiphy0_ep=0x1204`、`pm8008 ldo3=0x1205`（overlay 方式下 fdtoverlay 会重编号，语义校验通过）。

**驱动侧要求已逐条核对**（mainline `hi556.c`）：
`HI556_DATA_LANES=2`（`hi556.c:1233` 强制）、`HI556_LINK_FREQ_437MHZ`（`:23`）、
三路 supply 名 `dovdd/avdd/dvdd`（`:628-632`）、`devm_v4l2_sensor_clk_get(dev,"clk")`（`:1344`，
故 `clock-names="clk"`，**不是** “xvclk”）、`reset` GPIO 可选且 `GPIOD_OUT_HIGH`（ACTIVE_LOW 与 Android 低有效一致）、
`hynix,hi556` OF match（`:1441`）。已装模块 `/lib/modules/6.18.44-current-sm8250/updates/hi556.ko`
含包内 `0008-hi556-of.patch`（`of_match_table` + fwnode 全上电识别），`modinfo` 有 `of:N*T*Chynix,hi556`，
DT 节点出现后会自动 modprobe。

---

## 2. 联合 DTB 的“真实构建源”调查（任务 1）

### 2.1 结论：生产该 DTB 的源码已丢失

已做的只读证据（全部可复现）：

1. `grep -rln --include='*.dts*' -i 'ov13b10|cn3927|hi556' /var/tmp` → 只命中 **Android vendor 树**
   `/var/tmp/elish-kernel-src/...`（`elish-sm8250-camera-sensor-mtp.dtsi` 等），
   当前 mainline 构建树 `/var/tmp/kbuild-src/arch/arm64/boot/dts/qcom/` **没有任何** rear OV13B10 / CN3927V 节点。
2. 全盘 `grep -rln --include='*.dts*' 'ov13b10' /home/caitming` → 无命中；备份包
   `~/xiaomi-elish-linux-v1-final.bak-20261113-002050` 只有同一份二进制 DTB，**没有 DTS**。
3. `/var/tmp/kbuild-src` 不是 git 仓库；`sm8250-xiaomi-elish-common.dtsi` 只有前置 OV8856（CCI1/CSIPHY4），
   没有 rear OV13B10/CN3927V/EEPROM。
4. 更早的 DTB 备份（`/usr/lib/.../sm8250-xiaomi-elish-csot.dtb.pre-fp`（11-09）、
   `...dtb.bak-vmids2-20261110-1135`）反编译后 **完全没有** `ov13b10/ov8856/cn3927` 节点；
   而 11-12 19:16 的联合 DTB 才带上相机节点 → 相机节点是 2026-11-12 前摄/后摄适配期间从某份
   **后来被覆盖/丢失的源码**合并进去的（11-17 内核重编时构建树被还原）。
5. 包内明确写死不可从树内重建：`kernel/build-and-install.sh` 第 7 步注释
   “**联合 DTB（模型级，包内已验证；不从 DTS 重建）**”；`kernel/dtb/README.md`
   “不要用当前内核树的 DTS 重建 DTB（会丢 17 节点/109 属性）”“禁止 dtc 往返”。

### 2.2 可复现替代方案：从部署 DTB 恢复源码（已实测）

`dtc 1.7.0` 能把部署 DTB 反编译成完整 DTS，且**文本往返的唯一损坏点是已知且可自动修复的**：

- 反编译→重编后，与基线逐属性（含长度）对比，**只有 2 个属性不同**：
  `/soc@0/rsc@18200000/regulators-1/ldo10` 的 `regulator-min/max-microvolt`：
  `00 32 4b 00`（4 字节，0x324b00=3.3V）→ `02 4b 00`（3 字节，0x024b00=0.15V）。
  原因是 dtc 把该值反编译成字符串 `"\02K"` 后按 3 字节重新编码；其余全部节点/属性字节级一致。
- 该损坏正是包内 `verify-combined-dtb.sh` 的检查项（L10C 必须 `324b00`）。
  `hi556-build-dtb.py` 在 dtc/overlay 流程后会自动把与基线不同的属性**按基线字节还原**
  （只允许“计划内新增”，任何其它差异直接报错），因此修复后 100% 保持基线语义。

由此得到可复现的三条构建路径（本次全部实测通过，产物语义一致）：

| method | 做法 | 特点 |
|---|---|---|
| `fdt`（默认） | libfdt 直接在基线 DTB 上 `add_subnode/setprop` | 不经 dtc 文本往返、不依赖 overlay，最稳；需要系统 `libfdt.so.1`（本机已装） |
| `dtc` | `dtc` 反编译 → 文本增补 → `dtc` 编译 → 还原 ldo10（`--emit-dts` 可导出本地 DTS） | 真正“DTS 编译”，便于审计/再编辑 |
| `dtbo` | 脚本本地生成 dtso（`--emit-dtso`）→ `fdtoverlay` 离线合并 → 修正 fdtoverlay 重分配的 phandle | 用于评估 DTBO 路线（§5）；不用于运行时 |

---

## 3. 补丁 / 片段（不随包；仅脚本本地生成）

包内只有**一个**模型级联合 DTB（`../sm8250-xiaomi-elish-csot.dtb`，已合并 Hi556）；
不再提供 stage1/stage2 两个单独 DTB 文件。
本目录**不附带**从部署 DTB 导出的 `.patch`、`.dtso`、`.dtsi` 文本；
需要查看/审计补丁内容或从旧基线重建时，用构建脚本本地生成：

```bash
BASE=/path/to/kernel/dtb/sm8250-xiaomi-elish-csot.dtb   # 你自己的部署 DTB
# 反编译 + 增补后的 DTS（本地临时文件）
python3 hi556-build-dtb.py --base "$BASE" --method dtc --emit-dts /tmp/hi556-patched.dts
# 离线 overlay 源（本地临时文件；仅评估用）
python3 hi556-build-dtb.py --base "$BASE" --method dtbo --emit-dtso /tmp/hi556-camera.dtso
```

脚本内部包含要新增的节点（ldoc2 / CCI0 sensor / camss port@0 / pinctrl），
并对基线做“只增不丢”/L10C 往返修复校验；**不包含也不需要任何预生成的补丁文件**。

## 4. 构建与验证结果（任务 3）

### 4.1 构建命令

```bash
cd .work/android-cam-20261120
./hi556-build-dtb.py --method fdt  --out /tmp/hi556/final-fdt.dtb   --verify-combined
./hi556-build-dtb.py --method dtc  --out /tmp/hi556/final-dtc.dtb   --verify-combined
./hi556-build-dtb.py --method dtbo --out /tmp/hi556/final-dtbo.dtb  --verify-combined
(旧基线可选用) ./hi556-build-dtb.py --stage 1 --out /tmp/hi556/final-stage1.dtb
```

产物 sha256（均通过全部校验）：

| 产物 | sha256 |
|---|---|
| 合并 stage2（包内 `../sm8250-xiaomi-elish-csot.dtb`） | `0d639355650ad34ef3a03ed6af44f4fd2e1ec287aadd543a7c707238f8b544e8` |
| stage2 `--method dtc` | `be55bb5e76830d9784fcd53937eab9382b73a8595ead41c6c90200fc08aea592` |
| stage2 `--method dtbo` | `2e118e28de965e39681c533d11f567fea077f9f44212cf67be931f75ed9f1c18` |
| stage1 参考（仅旧基线生成到 /tmp，不随包） | `d48d49de548190c29d298632980d044740b5d06aedf6dea32f894df710160ec4` |

### 4.2 “只增不丢”校验（对基线 DTB）

```
新增节点 7 个 / 新增属性 1 个 / 删除 0 / 改动 0
 + /soc@0/camss@ac6a000/ports/port@0/endpoint
 + /soc@0/cci@ac4f000/i2c-bus@1/camera@20（+ /port、/port/endpoint）
 + /soc@0/pinctrl@f100000/cam-mclk1-default-state
 + /soc@0/pinctrl@f100000/camera-depth-active-state
 + /soc@0/rsc@18200000/regulators-1/ldo2
 + /soc@0/geniqup@8c0000/i2c@884000/pmic@8/regulators/ldo3 phandle = <…>
stage1 为新增 6 节点 + 1 属性（无 camss endpoint）。
```

校验器逐项断言：ldo2 电压/模式；Hi556 `reg=0x20`、supply 经 phandle 解析分别落到
`vreg_l1c_1p8`/`vreg_l3p`/`vreg_l2c_1p2`、`clocks/assigned-clocks = <&camcc 75>`、`reset-gpios=<&tlmm 26 1>`、
`pinctrl-0` 指向两个新 pinctrl 节点、endpoint `data-lanes=<1 2>`/`link-frequencies=437000000`、
camss endpoint `data-lanes=<0 1>`/`bus-type=4` 且与 Hi556 endpoint 双向 `remote-endpoint` 一致；
phandle 全局唯一；`/fingerprint`、`/bcm4775`、`/reserved-memory/fastrpc`、`fastrpc qcom,vmids` 与
`L10C 4 字节 3.3V` 等基线不变量全部保持。另有 `fdt_check_full()` 通过。

包内 `verify-combined-dtb.sh` 对新 DTB 的输出：传感器 vmids、fastrpc memory-region、指纹、L10A/L10C、
GNSS QUP5+bcm4775 全部 `OK`，结论“DTB 同时满足传感器、指纹与 GNSS 需求”。

### 4.3 三方式一致性

把 phandle 数值归一化为“指向的节点路径”后比较：`fdt` vs `dtc` vs `dtbo` 的节点集与全部属性**零差异**
（`dtbo` 只是 fdtoverlay 重排了 phandle 编号，引用关系经校验一致）。`dtc` 方式与手工 patch 流程输出 sha256 相同。

### 4.4 这是否意味着上电/出流一定成功？

**不**。DTB 只保证“节点/电源/GPIO/时钟/lane 描述正确、可被驱动匹配”。真正 probe/出流还取决于：
① Hi556 I2C 0x20 是否应答；② CSIPHY0 物理 lane 是否与 `<0 1>`/`<1 2>` 匹配；
③ camss async notifier（见 §6）。这些需要重启实测，本任务不做（不刷机、不重启）。

### 4.5 从旧基线手动应用 / 回滚（历史方法；包内 DTB 已合并，无需此步）

```bash
cd .work/android-cam-20261120
# 0) 先 dry-run（无需 root，什么都不写）：构建+校验+打印计划
./hi556-apply-dtb.sh --stage 1
./hi556-apply-dtb.sh --stage 2          # 推荐先 stage1 实测 probe 后再做 stage2

# 1) 分阶段应用（需要用户 sudo，脚本内会再要一次 yes 确认）
sudo ./hi556-apply-dtb.sh --stage 1 --write-boot
sudo reboot
#    重启后确认 Hi556 probe：
dmesg | grep -iE 'hi556|cci|camss|csiphy' | head -40
ls -l /sys/bus/i2c/devices/ | grep 21-0020      # cci0 i2c-bus@1 预计是 i2c-21
# 2) probe 成功后再应用 stage2（接 camss port@0，启用出流链路）
sudo ./hi556-apply-dtb.sh --stage 2 --write-boot
sudo reboot

# 回滚（任何异常）：
sudo ./hi556-apply-dtb.sh --rollback --write-boot
# 备用：直接写回 update-boot-image.sh 生成的 boot 分区镜像
sudo dd if=/root/boot_b-backup-<时间戳>.img of=/dev/disk/by-partlabel/boot_b && sudo reboot
```

`--write-boot` 的实际动作（全部有备份/校验）：
1. 备份 `/usr/lib/linux-image-$(uname -r)/qcom/sm8250-xiaomi-elish-csot.dtb` 与
   `/boot/dtb-$(uname -r)/qcom/...` 到 `/root/hi556-dtb-backup/<时间戳>/`；
2. `install` 新 DTB 到上述两个路径（`/boot` 目录在 rootfs 上，不是块设备）；
3. 调包内 `kernel/update-boot-image.sh`：verify-combined 预检 + initramfs 固件不变量检查 +
   **dd 备份 Linux 启动槽**（本机 `armbianEnv.txt` → `abl_boot_partition_label=boot_b`）+
   `/etc/kernel/postinst.d/zz-update-abl-kernel` 重建 `armbian-kernel-csot.img` +
   回读 `cmp` 校验；写错槽会起不来，槽位只认 armbianEnv，脚本不盲写；
4. 提示 `reboot` 与自检/回滚命令。

> 风险提示：ABL 启动链只能从备份/串口恢复；写入前请确认 `armbianEnv.txt` 的槽位是本机 Linux 槽
> （本机已核实为 `boot_b`，Android 在 `boot_a`），并保留 `/root/boot_b-backup-*.img`。

---

## 5. Armbian `fdtoverlays` / DTBO overlay 可行性评估（任务 4）

### 5.1 运行时 overlay：不可行（实测证据）

- `/boot/config-6.18.44-current-sm8250` 与包内 `config-used-6.18.44`：
  `# CONFIG_OF_OVERLAY is not set` → 内核**没有** `of_overlay_fdt_apply()`/configfs overlay，
  即使把 `.dtbo` 放到 `/boot` 也没有任何组件会在启动时合并它。
- `/boot/armbianEnv.txt` 没有 `overlays=`/`fdtoverlays=`/`fdtfile=` 等 Armbian overlay 机制配置项；
  `/boot` 下无 `overlay-user/`、无 `boot.scr`/`extlinux.conf`。
- 启动链是 **ABL（Android bootloader）**：`/etc/kernel/postinst.d/zz-update-abl-kernel` 把
  `gzip Image + DTB` 拼成 `Image.gz-dtb` 后 `mkbootimg`，由 ABL 从 `boot_b` 载入；
  内核靠 **追加 DTB** 方式取设备树。这条链没有 U-Boot 的 `fdt apply`，也不识别 Armbian 的 overlays 变量 ——
  与内核 `CONFIG_OF_OVERLAY=n` 相互印证。

### 5.2 离线 `fdtoverlay`：可用，但不比“直接增补 DTB”更安全（已实测）

`fdtoverlay -i base.dtb -o out.dtb hi556-camera.dtbo` 在用户态即可合并（不依赖内核 overlay 支持），
本次 `--method dtbo` 已跑通并通过全部校验。但实测发现两个必须处理的点，使其**风险不低于**直接 DTB 增补：

1. **phandle 重映射陷阱**：`fdtoverlay` 会给 overlay 内节点重新分配 phandle（包括“在已有节点上新增的
   phandle”）。若 overlay 里用**字面数字**引用这些 phandle，引用不会跟着改 → 静默损坏
   （实测：`avdd-supply=<0x1205>`，合并后 ldo3 的 phandle 被改成 `0x230b`，引用失效）。
   只有给 overlay 内节点打 label、让 dtc 生成 `__local_fixups__` 才能自动跟随；
   而“已有节点 ldo3 上新增的 phandle”无法用 label 引用，只能合并后回填（脚本已实现该 post-fix）。
2. **辅助节点泄漏**：`dtc -@` 编出的 overlay 带 `__symbols__`；`fdtoverlay` 会把它合并进基树
   （基线原本没有该节点），脚本需要删除以保持“只增计划内节点”。

结论：DTBO 路线技术上可行（适合想保留 overlay 源、离线生成 DTB 的场景），但
(a) 运行时加载需要重编内核 `CONFIG_OF_OVERLAY=y`+`CONFIGFS_FS` 且需要启动器支持存 overlay 的位置，
当前内核与 ABL 启动链都不具备，改内核超出本任务且风险更高；
(b) 离线合并最终仍要**重建并写 boot 镜像**，与直接替换 DTB 的写入风险完全一样；
(c) 还多一层 phandle 重映射语义。
→ **不作为主路径**；主路径 = `hi556-build-dtb.py --method fdt`（或 `--method dtc`）。
`--method dtbo`（本地 `--emit-dtso`）仅作可复现的备选与评估。

---

## 6. 风险、未知量与分阶段验证

### 6.1 camss async notifier 依赖（最重要，决定分阶段）

mainline camss 在 probe 时遍历 `camss/ports/*/endpoint`，把每个 remote sensor 加入
`v4l2_async_notifier`（`camss.c:3629` `camss_of_parse_ports`）；只有**全部** sensor 都 probe 成功，
才会调用 `camss_subdev_notifier_complete()`（`camss.c:3973`）创建 sensor→csiphy media link 并
`v4l2_device_register_subdev_nodes()`。因此：

- **stage2**（camss port@0 连上 Hi556）后，若 Hi556 I2C 无应答/识别失败（probe 失败），
  `complete()` 不触发 → 现有前摄 OV8856、后摄 OV13B10 的 subdev 节点/link 也不会建立，**三颗相机一起不可用**。
- **stage1**（只加 ldo2 + pinctrl + CCI0 传感器节点，不加 camss port@0 endpoint）不会挂到 camss notifier，
  即使 Hi556 probe 失败，前/后摄完全不受影响 → 先 stage1 实测 probe，成功再 stage2。

### 6.2 需要实测确认的外部未知量（按可能性）

| 项 | 现状/依据 | 排查与对策 |
|---|---|---|
| Hi556 I2C 7-bit 地址 = 0x20 | 中高置信：sensormodule bin 显式 `slaveAddr=0x40`(8-bit) + wide/front 的 0xa2/0xa0 反证；旧记录也试过 0x24 | 重启后看 `dmesg` 是否 `hi556 21-0020: failed to find sensor`；`i2cdetect -y 21` 扫 0x20/0x24；若 no-ack，改 `reg=<0x24>` 重建（脚本改常量即可） |
| CCI 总线频率 | 继承 `i2c-bus@1` 的 `clock-frequency = 1000000`（`i2c-qcom-cci.c:551-556` → FAST_PLUS）；前/后摄同总线 1MHz 工作正常 | 若 I2C 错误多，可把 `i2c-bus@1` 的 `clock-frequency` 改 400000（属“改动”属性，脚本会提示） |
| CSIPHY0 物理 lane | Android 的 lane assign 在 CamX UMD（不在 DT）。sensormodule `laneAssign=0x10` 与前置 OV8856 **完全相同**，前置 mainline 用 sensor `<1 2>` / camss `<0 1>`，故本补丁沿用该映射 | 若 `CSID` 报 CSI2 错误/无帧：按 `csiphy0` 实际接线改 endpoint 的 `data-lanes`（备选 `<0 1>`/`<2 3>`）重建 |
| 供电时序 | Linux `hi556.c` 为 clk→三路 regulator→reset（`hi556_resume`）；Android 是 三路電→MCLK→reset。通常可工作，但 Hi556 对时序较敏感 | 若 probe 读 ID 失败，先确认 3 路供电/GPIO 状态（`/sys/kernel/debug/regulator`、gpiod）；必要时给驱动加 Android 顺序（需另改驱动，超出本任务） |
| PM8008 L3P | 前摄已用 PM8008 L5P，驱动/节点正常；本补丁只给从未被引用的 ldo3 补 phandle，不改电压 | 若 avdd 无法 enable，看 `dmesg | grep pm8008` |
| camcc MCLK1 | `CAM_CC_MCLK1_CLK` id=75（`qcom,camcc-sm8250.h:85`），camcc 驱动暴露全部 MCLK，OV8856 MCLK3 已工作 | `clk_summary` 中看 `cam_cc_mclk1_clk` 19.2MHz |
| IoMMU/CMA | camss 走 VB2 DMA（现有相机已工作），Hi556 2-lane 带宽低 | 一般无需改；若 CMA 不足，`cma=256M` 已在 armbianEnv |

### 6.3 预期日志（stage1 成功后）

```
hi556 21-0020: supply dovdd not found ...   # 若出现 → supply 名/节点问题（本补丁已按 dovdd/avdd/dvdd 配好）
hi556 21-0020: failed to get clock          # 若出现 → clock-names 不是 "clk" 或 camcc 未就绪
hi556 21-0020: failed to find sensor        # I2C 无应答/地址错（先查 0x20/0x24、CCI 频率、供电）
```

---

## 7. 复现命令与文件清单

```bash
D=/home/caitming/Documents/deepseek-harness/default-workspace/.work/android-cam-20261120
cd "$D"
# 构建 + 全量校验（默认 fdt；只读基线，不写 boot）
./hi556-build-dtb.py --out /tmp/hi556.dtb --verify-combined
# 3 种方式 / 分阶段
./hi556-build-dtb.py --method dtc  --out /tmp/a.dtb
./hi556-build-dtb.py --method dtbo --out /tmp/b.dtb --emit-dtso /tmp/c.dtso
./hi556-build-dtb.py --stage 1 --out /tmp/stage1.dtb
# 只校验一个已有 DTB（不做修改）
./hi556-build-dtb.py --check-only /tmp/hi556.dtb
# 应用/回滚（默认 dry-run，--write-boot 才写盘，需 sudo）
./hi556-apply-dtb.sh --stage 1
sudo ./hi556-apply-dtb.sh --stage 1 --write-boot
sudo ./hi556-apply-dtb.sh --rollback --write-boot
```

| 文件 | 说明 |
|---|---|
| `hi556-dts.md` | 本报告 |
| `hi556-build-dtb.py` | 构建+校验工具：`--method fdt/dtc/dtbo`、`--stage 1/2`、`--check-only`、`--fix-roundtrip`、`--emit-dts/--emit-dtso`、`--verify-combined` |
| `hi556-apply-dtb.sh` | 用户应用/回滚脚本（默认 dry-run；`--write-boot` 才写；自动备份 + 调 `update-boot-image.sh` + 回读） |
| `README.md` | 本报告 + 构建/应用方法 |
| `hi556-build-dtb.py` | 从旧基线本地生成/校验 DTB/DTS/dtso（不含预生成的 DTS 文本） |
| `hi556-apply-dtb.sh` | 从旧基线应用/回滚脚本（默认 dry-run；包内联合 DTB 检测到已合并后直接退出） |

> 本目录**不包含** `.patch`、`.dtso`、`.dtsi` 等从部署 DTB 导出的中间文本；
> 需要时用 `--emit-dts`/`--emit-dtso` 在本地生成到 `/tmp`。
> **包内只有一个模型级联合 DTB：`../sm8250-xiaomi-elish-csot.dtb`（已合并 Hi556）。**

**约束声明**：本任务全程只读；未写 `/boot`、未写任何块设备、未 mount、未 sudo、未改 `/usr` 与驱动包；
所有中间文件在 `/tmp/hi556`，交付件只写入 `.work/android-cam-20261120/`。
应用/回滚脚本只准备命令，写盘动作需用户显式 `sudo --write-boot` 执行。

---

## 8. 实机验证结果（2026-11-20，elish 本机）

**stage1（只加 ldoc2/pinctrl/CCI0 sensor 节点，不接 camss）**
- 重启成功；`/sys/bus/i2c/devices/21-0020` 出现并绑定 `hi556` 驱动（compatible `hynix,hi556`）；
- `vendor` 侧 `pm8150a_l2` 对应的 RPMH `ldoc2` 注册为 `vreg_l2c_1p2`（1.2 V，HIL/HPM）；
- 前后摄无回归（拍照/录像正常）；启动时 `regulators-1/ldo1 defer` 警告在打补丁前已存在。

**stage2（接 camss port@0 / CSIPHY0）**
- 重启成功；media 图出现 `hi556 21-0020`（`/dev/v4l-subdev26`），格式 `SGRBG10_1X10/2592x1944`；
- 链路：`hi556:0 -> msm_csiphy0:0`（IMMUTABLE 已使能）→ `msm_csiphy0:1 -> msm_csid0:0` → `msm_csid0:3 -> msm_vfe0_rdi2:0` → `msm_vfe0_video2`（`/dev/video3`）；
- 实测抓 RAW：`v4l2-ctl -d /dev/video3 --set-fmt-video=width=2592,height=1944,pixelformat=pgAA --stream-mmap --stream-count=30 --stream-to=...`
  得到 30 帧（每帧 6,314,112 B，RAW10 packed），约 27 fps（含启动，模式 30 fps）；
- 用 sensor `test_pattern=7`（Check Board）复核：解包预览为清晰棋盘格，确认 **MIPI lane/CSID/VFE 数据通路正确**；抓完已恢复 `test_pattern=0`；
- 期间前后摄始终可用；stage2 后后摄 4208×3120、前摄 3280×2464 拍照与 3 s 录像（90/90 帧）正常。

**注意/限制**
- 前/后摄与 Hi556 共用 CSID0/VFE0；手动抓 Hi556 前需 `elish-camera-ctl stop`，抓完 `elish-camera-ctl start`，避免链路冲突
  （若 link 处于 ENABLED 状态，media-ctl 会报 EBUSY，需先把对应 link 关掉再切）；
- 当前只验证到 **Hi556 RAW 出流**；Linux 下还没有 Hi556 的 3A/彩色/深度用户态管线（Android 的深度算法属闭源 CAMX/CHI）；
- 已验证 DTB 仍保留在 boot_b；如需回滚见 §4.5。
