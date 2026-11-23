# 联合 DTB（传感器 vmids + 指纹节点 + GNSS + 相机）

统一 DTB 必须同时包含：

1. 传感器：SLPI `glink-edge/fastrpc` 的 `qcom,vmids = <3 15 5 6>`；
2. 指纹：根节点 `/fingerprint`（`compatible="goodix,gf3626"`、`firmware-name="gfenu"`、
   `interrupts=<23 1>`、`reset-gpios=<&tlmm 125 GPIO_ACTIVE_LOW>`、`vdd-supply`=PM8150A L10A、
   pinctrl IRQ gpio23）；
3. GNSS：
   - `/soc@0/geniqup@9c0000/i2c@994000`：`compatible="qcom,geni-uart"`、`status="okay"`、
     `pinctrl-0` 指向 `qup-uart5-default-state`（`/soc@0/pinctrl@f100000`，gpio12–15，function `qup5`）；
   - 根节点 `/bcm4775`：`compatible="bcm4775"`、`gps-ldo=<&tlmm 46 GPIO_ACTIVE_HIGH>`、
     `pinctrl-0`=PMIC `gps-clk-default`（`/soc@0/spmi@c440000/pmic@0/gpio@c000/gps-clk-default`）、
     `pinctrl-1/2`=`gps-enable-active`/`gps-enable-suspend`（TLMM GPIO158）；
4. 相机：前摄 OV8856/PM8008/CAMSS 节点、后摄 OV13B10/CN3927V、Hi556 景深
   （ldoc2/CCI0/CSIPHY0/MCLK1/GPIO26）节点，详见 `../../camera/README.md` 与 `hi556/README.md`。

本目录的 DTB 已包含以上全部改动：`sm8250-xiaomi-elish-csot.dtb` 为**唯一联合 DTB**
（模型级、无本机私有信息、含 Hi556），139,091 B，sha256
`6d1cb494772f78ae72ed0fefe9f9068ec7609049524a7c7d62dc9c982f055afe`。

## 传感器真正依赖的是 fastrpc reserved-memory

当前 DTB 里除了 `qcom,vmids`，还有 **`/reserved-memory/fastrpc`（32MB shared-dma-pool）** 以及
slpi/cdsp/adsp 三个 fastrpc 节点的 `memory-region = <&fastrpc>`。这些是 remote heap 必需的；
`qcom,vmids` 在打了补丁的 fastrpc 里已改用候选表，保留只为与历史 DTB 一致。
`verify-combined-dtb.sh` 会同时检查 memory-region 与 reserved-memory。

## 三种做法

1. **直接使用包内 DTB（推荐）**：只装 DTB 或同时重建 Linux 启动槽（自动检测/备份/回读校验）：
   ```bash
   sudo ./kernel/install-dtb.sh                # 更新 rootfs/boot 下的 DTB
   sudo ./kernel/install-dtb.sh --write-boot   # 另重建 Linux 启动槽（DTB 打进 boot 镜像才生效）
   ```
2. **改内核 DTS 源码重编**（干净重建才推荐）：在 elish board DTS/common dtsi 加
   `/fingerprint`、`qcom,vmids`、GNSS 与相机节点，`make dtbs`。节点参考
   `fingerprint-node-reference.txt`（含 phandle 对应关系）。前提是取得**完整的** Armbian
   sm8250 源码（见下）。
3. **二进制就地修改**：仅限已有属性/等长字符串，例如 `patch-firmware-name.py`
   （`fingerpr`→`gfenu`）。

## 重要：不要用当前内核树的 DTS 重建 DTB

`/var/tmp/kbuild-src` 的 DTS **不是**当前 DTB 的完整源：用它重编会丢 17 个节点/109 个属性
（`/reserved-memory/fastrpc` 32MB、fastrpc memory-region、lid/tablet-mode、panel/ts pinctrl、
uart16、haptics、regulator@88e7000 等），且树内只有 vmids、没有指纹与相机节点。
最小安全方案：直接使用本目录附带的已验证 DTB（或你之前备份的同一份），不要从树内 DTS 重建。
若必须从源码重建，先取得 **Armbian db44df750 的完整 sm8250 源码**并补齐这些节点，再逐属性 `dtc` diff 验证。

## 禁止 dtc 往返

`dtc -I dtb -O dts` 再 `dtc -I dts -O dtb` 会把 **`regulators-1/ldo10`（L10C，3.3V）** 的
4 字节 `regulator-min/max-microvolt`（`00 32 4b 00`）改写成 3 字节（`02 4b 00`）——语义破坏。
**L10A 是 `regulators-0/ldo10`（3.008V），不受该问题影响**；当前验证 DTB 只新增了计划内节点/属性，
没有改动任何已有属性。改属性请用等长二进制替换或完整源码重编。

## TZ / 指纹专用 reserved memory（2026-11-23）

联合 DTB 新增 32 MiB 专用 carveout，并交给 `/firmware/scm`：

```
reserved-memory {
    tz_ffi_mem: tz-ffi@93000000 {
        compatible = "shared-dma-pool";
        reg = <0x0 0x93000000 0x0 0x2000000>;
        no-map;
    };
};
firmware { scm { memory-region = <&tz_ffi_mem>; }; };
```

`qcom_scm` probe 的 `of_reserved_mem_device_init()` 会把该 region 设成 SCM 设备的
per-device coherent DMA pool；`qcom_tzmem` 的 TA（gfenu，约 9 MiB）从这里分配，
**不再从全局 CMA 抢连续块**，因此长期运行/内存压力下不会再出现
`__cma_alloc: ... req-size: 2244 pages, ret: -16`。代价是少 32 MiB RAM。

当前 DTB sha256 `6d1cb494…`；只新增 1 个节点 + 1 个属性，L10C 已还原，
`verify-combined-dtb.sh` 通过。应用：`sudo kernel/install-dtb.sh --write-boot`。

重启实测（2026-11-23 08:24）：内核创建 32 MiB DMA memory pool、`qcom_scm` 成功
`assigned reserved memory node tz-ffi`；`CmaFree` 仅 5.6 MB 时 TA `gfenu` 仍加载成功。

## Hi556 景深相机（已实测 RAW 出流）

本目录 `hi556/` 只保留 Hi556 的构建/应用脚本；Hi556 节点已经合并进包内**单一联合 DTB**：

- 不再提供 stage1/stage2 两个单独 DTB；`sm8250-xiaomi-elish-csot.dtb` 即为含 Hi556 的模型级联合 DTB；
- DTS/patch/dtso 等中间文本不随包，需要时由脚本生成到 `/tmp`；
- 2026-11-20 实机验证：`hi556 21-0020` → CSIPHY0 → CSID0 → VFE0 RDI2，RAW10 2592×1944@~30fps，
  checker test pattern 通过；前后摄无回归；
- 应用前先 dry-run；`--write-boot` 才会写 boot（自动备份 + 重建 Linux 启动槽 + 回读校验）；
- 详见 `hi556/README.md`。

## 校验

```bash
./verify-combined-dtb.sh /usr/lib/linux-image-$(uname -r)/qcom/sm8250-xiaomi-elish-csot.dtb
# 期望：vmids=3 f 5 6；/fingerprint compatible=goodix,gf3626、firmware-name=gfenu；
#       QUP5 UART compatible=qcom,geni-uart / status=okay；/bcm4775 有 gps-ldo 与 pinctrl；
#       L10A/L10C 电压仍是 4 字节原值
# Hi556（该校验器不断言相机节点）：fdtget -t s <dtb> /soc@0/cci@ac4f000/i2c-bus@1/camera@20 compatible
```
