# Android Chromatix 提取（仅限你自己的设备，只提供方法与脚本）

本目录**不含任何设备数据**：没有 `.bin`、没有解析出的 JSON/CSV、没有 `tuning_data.h`。
这里只有只读提取/生成脚本，用于在你自己的 Xiaomi Pad 5 Pro (elish) 上，
从你自己的 Android vendor 分区里提取 LSC（镜头阴影）、CCM（颜色矩阵）等调校参数，
生成本机使用的 `src/tuning_data.h`。

> 请仅处理你拥有的设备与你自己备份的数据；生成物不要提交、不要分发。

## 步骤

1. **只读取得 vendor 调校 bin**（从你自己的设备，不刷写、不分发）：
   需要以下文件（通常位于 Android vendor 分区的 `lib64/camera/`，
   实际路径以你自己的镜像为准）：
   - `com.qti.tuned.elish_ofilm_ov13b10_wide.bin`
   - `com.qti.tuned.elish_aac_ov8856_front.bin`
   - `com.qti.tuned.elish_qtech_hi556_depth.bin`
   - `com.qti.tuned.default.bin`
   把它们放到一个本机临时目录，例如 `~/android-tuned/`（不要放进本仓库）。

2. **解析 bin**（只读；输出只写到你指定的临时目录）：
   ```bash
   tools/android_tuning/chromatix_extract.py \
       --bins ~/android-tuned --out /tmp/elish-tuning
   ```
   会得到 locals 的 `lsc_*.json`、`ccm_*.json`、`gamma_*.json`、`awb_*.json` 等。

3. **整理成 Linux 参数包**：
   ```bash
   tools/android_tuning/build_linux_params.py \
       --data /tmp/elish-tuning \
       --out /tmp/elish-tuning/linux-recommended-params.json
   ```

4. **生成 C 头文件**（只写到源码树，不提交）：
   ```bash
   tools/android_tuning/gen_tuning_data.py \
       --json /tmp/elish-tuning/linux-recommended-params.json \
       --out src/tuning_data.h
   ```

5. **重编译**：
   ```bash
   make -j4
   ```
   有 `src/tuning_data.h` 时 LSC/CCM 默认开启；没有时使用中性（identity）
   LSC/CCM 且默认关闭，源码仍可正常编译/运行。

## 开关

- `ELISH_LSC=0` / `ELISH_CCM=0` 关闭对应处理；
- `ELISH_LSC_FRONT=1` 开启前摄 LSC（前摄只有模板数据，默认关）。

## 注意

- `src/tuning_data.h` 已加入本目录 `.gitignore`；不要把它提交到任何仓库；
- 本目录脚本通过解析你自己设备的数据得到调校参数，不包含任何预提取结果；
- 若 `com.qti.tuned.*.bin` 文件名/路径因版本不同，请按脚本里的 `--bins` 目录调整或修改脚本内的文件映射。
