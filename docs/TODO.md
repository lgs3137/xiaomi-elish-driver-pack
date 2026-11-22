# 整机未完成事项（TODO）

更新于 **2026-11-22**。本文件只列**仍未完成/未验证**的项与明确的“不做”结论；
已完成项见 [`HISTORY.md`](HISTORY.md)、[`../README.md`](../README.md) 与各子包 README。
硬件/驱动当前状态以 [`HARDWARE-STATUS.md`](HARDWARE-STATUS.md) 为权威；升级影响见
[`UPGRADE-IMPACT-ALL.md`](UPGRADE-IMPACT-ALL.md)；总自检：`sudo ./install/check-all.sh`。

---

## 1. Linux 充电栈：继续提高持续功率（中）

现状（2026-11-22）：PD 9V + bq2597x 双泵；低电量电池侧 **~18–20W**；可选
`pps-charger/` 用 11V keep-alive，50–56% 电量电池侧 ~20.5W（温度 ≥41.5°C 回退）；
~90% 时 SMB5 提前报 `Full`，服务退出 PPS 交给涓流/分段曲线充到 100%。

剩余：
1. **驱动层温度门控**：现在只有 PPS 服务按温度回退，SMB5 输入限流不可写、双泵仍会发热
   （约 40°C 就受限），需要内核里对泵 + FCC 做温控曲线才能更长时间高功率；
2. **5V/3A DCP 档**电流上限（目前保守 1.5A）；
3. **66W**：需要原厂 11V/6A 私有协议 + 双泵协同；标准 PPS 受充电头 ~13s 看门狗限制，
   keep-alive 能保契约但持续功率 ~20.5W。暂不投入。

验收：反复 suspend/resume、插拔、不同充电器；PD 9V 电池侧 ≥15W 稳定、温度受控；
PPS 不触发异常硬复位；高电量能正常涓流到 100%。

## 2. 原始陀螺 / 磁力计三轴 / 接近/SAR 用户态暴露（中）

- 现状：加速度/环境光/旋转矢量方向/指南针 heading 已可用；原始陀螺、磁力计三轴（μT）、
  接近/SAR 未通过 libssc/udev 暴露（`HasProximity=false`）。
- 下一步：在 libssc/udev 层补 sensor type/scale/units（非硬件驱动问题）。
- 验收：`gdbus`/iio-sensor-proxy 能读到 gyro、mag 三轴、proximity。

## 3. pogo 键盘唤醒假死：内核侧根治（暂缓 / 待评估）

- 现状：默认组件 `pogo/` 已用**用户态自动复位**兜底（唤醒后 +3s 脉冲键盘 reset GPIO）；
  根因与实测证据见 [`HARDWARE-STATUS.md`](HARDWARE-STATUS.md) §2.2 与 [`HISTORY.md`](HISTORY.md)。
- **当前方案的代价（接受后再评估是否需要内核侧）**：每次唤醒键盘重枚举 ~1–1.5s、USB Device
  号递增、input/event 节点重建；唤醒后 ~3s 内打字可能丢键；无条件复位（假死无法可靠检测）；
  长睡 + Firefox 时 `68-touch-fix` 会在唤醒 +5s 再 `rtcwake -m freeze` 一次，本 hook 的
  复位在 +3s，若那次 freeze 再次弄死键盘，本次唤醒内不会二次复位（该场景未覆盖）。
- 已知排除：卡点在**键盘 MCU/HID 侧**；关闭 host wakeup 强制
  `dwc3_core_exit()`+`dwc3_core_init_for_resume()`（实验 A）无效，`authorized`/`USBDEVFS_RESET`
  也无效；“重初始化 DWC3/PHY”方向基本排除。
- 若推进：内核在 xHCI resume 完成后按序脉冲 reset（需先评审时序/死锁风险），或进一步做
  USB 协议/电源级定位（MCU 假死原因）；成本是内核构建安装 + 多轮睡眠验证，且根因修复不确定。
- 状态：**暂缓，不在当前排期**；推进前先评审代价、收益与验证计划。

---

## 明确不做（评估过，不作为 TODO）

- **GNSS 按需启动/懒连接**：不做。`airoha-gnssd` 常开成本约 50–70 mW（≈电池 3–5%/天，实际休眠更低），
  懒连接方案约 100 行 C + 4 个 unit，收益上限仅此，且 GeoClue/gnome-shell 是否常连不确定。
- **Hi556 彩色/深度/3A 用户态**：5MP 彩色 Bayer（SGRBG10），Android 侧作 depth；分辨率/用途不适合彩色，
  驱动/RAW10 已验证（2592×1944@~30fps、节点并入 DTB），继续做需要闭源 CAMX/CHI 栈，暂不投入。
- **硬件/上游限制**（详见 [`HARDWARE-STATUS.md`](HARDWARE-STATUS.md) §2/§4）：前摄固定焦点；
  前后摄不能同时出流；PMIC RTC 无后备电池；额外霍尔不可用；5G 版本不存在；
  dmesg 噪音（DPU frame event overflow / GPU cooling）；传感器 PD 偶发静默卡死（约 1/14 开机，
  SLPI/PD 固件侧，干净重启恢复）。

---

## 维护指针

- 当前硬件/驱动状态：`docs/HARDWARE-STATUS.md`（权威）；升级影响：`docs/UPGRADE-IMPACT-ALL.md`。
- 历史里程碑：`docs/HISTORY.md`；安装/校验/排障：各子包 `README`/`INSTALL` 与 `install/check-all.sh`。
