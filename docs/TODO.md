# 整机未完成事项（TODO）

更新于 **2026-11-21**。本文件只列**仍未完成/未验证**的项与明确的“不做”结论（按难度排序）；
已完成项不再记录（历史里程碑见 [`HISTORY.md`](HISTORY.md)）。硬件/驱动的当前状态与已知限制以
[`HARDWARE-STATUS.md`](HARDWARE-STATUS.md) 为权威基线；升级影响见
[`UPGRADE-IMPACT-ALL.md`](UPGRADE-IMPACT-ALL.md)；安装/排障以各子包 README/INSTALL 为准；
总自检：`sudo ./install/check-all.sh`。

---

## 1. box86/box64 下红警 2 极慢（难）

- 目录 `~/Red Alert 2`，dxvk 2.6.1 + cnc-ddraw + box86/64。
- 排查方向：dynarec 参数（`BOX64_DYNAREC_BIGBLOCK`/`STRONGMEM`）、wine+dxvk vs cnc-ddraw 的 GDI 路径、
  `DXVK_HUD=1` 确认 GPU 加速、调度器 `conservative`→`schedutil`、
  armhf 库缺失导致 box86 回退解释执行、cnc-ddraw renderer 选择。

## 2. Linux 充电栈加固 + 基础快充（第 2 步，中）

目标：**不移植完整 Android SMB5 栈**，保留现有 mainline SMB5 + TCPM + 独立 bq2597x，
只补关键状态机，做到支持基础快充（15–27 W 档）。

- **已完成（不在第 2 步范围）**：suspend/resume 后 Type-C legacy / 100mA 卡死已由
  `kernel/patches/0004-smb5-typec-legacy-reset-resume.patch` 修复（probe/resume 的 legacy 复位 +
  重跑 APSD/AICL + 恢复 current_max；带充电器 3 轮 suspend/resume 验证）。修复记录见
  `kernel/CHARGER-RESUME.md`。
- **剩余范围（第 2 步）**：把 PD/QC 固定档（5V/9V）的 ICL/FCC 接到 TCPM 协商结果；
  目标 **15–27 W** 基础快充 + 基本 JEITA/温控。
- **不做（第 3 步）**：电荷泵 2:1、双电芯、PPS、33W+ 原厂级快充——目前没有原装充电器，暂不考虑。
- **架构差异（设计依据）**：Android 用 `qpnp-smb5.c` + `smb5-lib.c` 整合栈（SMB5 内部管 CC/角色/APSD、
  充电类型/温控/电流投票同一状态机）；Linux 是精简 SMB5（`qcom_pm8150b_charger.c`）+ 独立 TCPM
  （`qcom_pmic_typec.c`/`tcpm.c`，负责 CC/角色）+ 独立 `bq25970_charger.c`（依赖 TCPM 的 online 事件
  设置 `usb_present`，Type-C 状态卡住时快充泵一直 `present=0`）。TCPM 有 PD 能力，但未与 SMB5 的
  ICL/FCC 完整联动——第 2 步就是把两者接起来。
- **参考**：Android `qpnp-smb5.c` 的 `smb5_configure_typec()`（legacy reset）、`smb5-lib.c` 的
  `smblib_rerun_apsd_if_required()` / `smblib_set_usb_suspend()`。
- **前置条件**：当前充电器**不支持 PD**（`port0-partner/supports_usb_power_delivery=no`，仅 5V DCP，
  `tcpm-source voltage_max=5V`，`pm8150b current_max≈1.95A`）。要验证 9V/15–27W，必须换
  **USB-C PD 9V/3A（或 QC 9V）充电器**；否则只能维持 5V 基础充电。
- **DTS 方向**：`sm8250-xiaomi-elish-common.dtsi` 当前 `sink-pdos` 为 5V + `PDO_VAR(5000,12000,5000)`；
  Armbian `0044` 将其改为 `PDO_VAR(5000,9000,3000)`。拿到 PD 充电器后优先加 **9V 固定 PDO**
  并验证 TCPM 请求 9V/3A；SMB5 驱动已有 DCP 3.3A 限流路径，再看 AICL 实际值。
- **验收**：反复 suspend/resume、插拔、不同充电器；不再出现 `power_role=source`/100mA 卡死；
  电池温升/限流正常；基础快充电流/电压符合充电器档位。
- **估时**：2–4 周（仅第 2 步；完整电荷泵/第 3 步另算 4–8 周，暂缓）。

## 3. Hi556 景深用户态（RAW 已打通；待 3A/彩色/深度，中）

- **现状**：stage1 probe 成功（`21-0020` 绑定 hi556、`ldoc2` 注册）；stage2 接 camss 后 media graph
  出现 `hi556 21-0020`，按 CSIPHY0→CSID0→VFE0 RDI2 抓 2592×1944 RAW10 ~30fps，
  checker test pattern 通过，前后摄无回归；已合并进单一联合 DTB（构建/应用脚本 `kernel/dtb/hi556/`）。
- **已纠正的旧结论**：原“PM8150A L1/L2 被 USB 占用”有误——Android 相机 `pm8150a_l2` 是 RPMH
  **`ldoc2`(1.2–1.304V)**，mainline RPMH 驱动本就支持，只是 elish DTS 缺节点；纯新增 DTS 补丁：
  `ldoc2` + `cci0` + `camera@0x20(hynix,hi556)` + `camss port@0` + MCLK1/GPIO26 pinctrl。
- **接线/上电**：I2C 7bit 0x20；上电顺序 3 路供电 → MCLK → 最后释放 reset。
- **下一步（用户态）**：Hi556 3A/曝光、彩色 debayer、深度算法（Android 侧为闭源 CAMX/CHI）与
  `elish-camera` 接入；当前手动抓 RAW 需先 `elish-camera-ctl stop`。
- **验收**：`/dev/media*` 出现 Hi556 链路、可抓 raw/彩色帧。

## 4. 原始陀螺 / 磁力计三轴 / 接近/SAR 用户态暴露（中）

- 现状：加速度/环境光/旋转矢量方向/指南针 heading 已可用；原始陀螺、磁力计三轴（μT）、
  接近/SAR 未通过 libssc/udev 暴露（`HasProximity=false`）。
- 下一步：在 libssc/udev 层补 sensor type/scale/units（天级，非硬件驱动问题）。
- 验收：`gdbus`/iio-sensor-proxy 能读到 gyro、mag 三轴、proximity。

## 5. pogo 键盘 s2idle 唤醒内核修复（难）

- 现状：s2idle 唤醒后键盘可能失效/USB 反复重枚举；用户态复位已证明风险高
  （曾触发 USB/看门狗死锁），**不要再用 authorized/USBDEVFS_RESET/重绑控制器**。
- 根因：host `a800000.usb` + `88e4000.phy` 的 s2idle fast-resume 只做 PHY runtime resume，
  不重新初始化 PHY/控制器。
- 下一步：只做内核 `qcom_snps_hsphy` resume 路径/上游修复的设计与验证。
- 验收：suspend/resume 后键盘无重连、按键正常。

---

## 明确不做（评估过，不作为 TODO）

- **GNSS 按需启动/懒连接**：**结论：不做**。`airoha-gnssd` 开机自启导致 GNSS LDO 常开，实测常开成本
  约 **50–70 mW**（屏幕最亮系统 ~6.8 W 的 ~1%；24h 约 1.2–1.7 Wh ≈ 电池 3–5%/天，实际休眠/关机更低）。
  懒连接方案（bridge 有客户端才连 gpsd、空闲 120s 停止）约 100 行 C + 4 个 unit、2–4 小时，
  但省电上限仅 50–70 mW，且 GeoClue/gnome-shell 是否常连 `/run/gps-share.sock` 不确定；
  除非以后特别在意续航，不再评估。
- **硬件/上游限制（详见 [`HARDWARE-STATUS.md`](HARDWARE-STATUS.md) §2/§4）**：前摄固定焦点；
  前后摄不能同时出流；PMIC RTC 无后备电池；额外霍尔不可用；5G 版本不存在；
  dmesg 噪音（DPU frame event overflow / GPU cooling）；传感器 PD 偶发静默卡死（约 1/14 开机，
  SLPI/PD 固件侧，干净重启恢复）。

---

## 维护指针

- 当前硬件/驱动状态：`docs/HARDWARE-STATUS.md`（权威）；升级影响：`docs/UPGRADE-IMPACT-ALL.md`。
- 历史里程碑：`docs/HISTORY.md`；安装/校验/排障：各子包 `README`/`INSTALL` 与 `install/check-all.sh`。
