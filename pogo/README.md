# pogo 键盘唤醒自动复位（默认组件）

Pogo 键盘（磁吸键盘，USB `3206:3ffc`）在 s2idle 唤醒后可能 **HID 假死**：USB 设备还在、
`lsusb` 和标准 `GET_DESCRIPTOR` 都正常，但按键/触摸板完全没有 input 事件。本组件在每次
系统唤醒后自动脉冲键盘的 reset GPIO（TLMM 141），让它重新枚举并恢复输入。

## 现象与历史结论（2026-11-22 更新）

- **现象**：睡眠唤醒后键盘无响应；需要物理拔插键盘（或重启）才恢复。偶发 USB 每 ~7 秒
  断开重连（重启后消失）。
- **不是** DWC3/USB2 PHY fast-resume 丢状态：
  - 2026-11-12 实验 A：把 host `a800000.usb` 的 `power/wakeup` 设为 disabled，强制 DWC3
    host 走 `dwc3_core_exit()` + `dwc3_core_init_for_resume()`（完整重初始化）；唤醒后键盘仍
    无输入 → **PHY/控制器重新初始化不是充分条件**。
  - `authorized` 0→1、`USBDEVFS_RESET` 只会让主机侧重枚举，按键仍无响应。
- **卡住的是键盘 MCU/HID 侧**：设备级控制请求仍应答，HID 输入路径假死；只有**键盘 reset
  引脚**复位才会恢复。2026-11-22 两次实测（17:29、17:34）用 root 脉冲 GPIO 后，键盘立即
  `USB disconnect` → 重新枚举（Device 002→003→004），随后按键正常，且无需物理拔插。
- 旧文档里 `dwc3-qcom-legacy a6f8800.usb: port-1 HS-PHY not in L2` 主要是 Type-C/外设
  控制器（device 模式）的日志噪音；键盘在 `a8f8800.usb/a800000.usb`（host）。2026-11-22
  也曾在键盘 host 上见到同样的 L2 提示，但它只表示该次 suspend 时 PHY 未停在 L2，与
  “唤醒后 HID 假死”没有一一对应（实验 A 已排除“重初始化 PHY 即可恢复”）。

## 修复方式（用户态，不改内核）

```
systemd sleep hook (69-elish-pogo-kb.sh, post)
        │  systemd-run --on-active=3s（等 USB/xHCI resume 完成）
        ▼
/usr/local/sbin/elish-pogo-kb-reset
        │  检测 pogo 键盘 → 找到 TLMM gpiochip → 脉冲 TLMM 141 低 150ms 再拉高
        ▼
键盘 MCU 复位 → USB 重新枚举 → 输入恢复
```

- 3 秒延迟：历史上在 sleep-post 里 1 秒后直接操作曾触发硬死机；3 秒已实测安全。
- 复位脉冲：先 `echo out` 设方向，拉低 150ms，再拉高并保持导出（高电平）。
- 没有接 pogo 键盘时 hook 直接退出，不碰 GPIO；外接 USB 键鼠/蓝牙键鼠不受影响。
- 每次唤醒都会让键盘重新枚举（约 1–1.5 s，Device 号递增）：唤醒后 3 秒内打字可能丢键。

## 安装

```bash
sudo ./pogo/install.sh              # 单独安装
# 或一键安装器（默认安装；--no-pogo 跳过）
sudo ./install.sh ...
```

安装内容：

| 路径 | 说明 |
|---|---|
| `/usr/local/sbin/elish-pogo-kb-reset` | 复位脚本（root；也可手动运行） |
| `/usr/lib/systemd/system-sleep/69-elish-pogo-kb.sh` | 唤醒后 post 阶段调度复位 |
| `/etc/default/elish-pogo-kb` | 配置（已存在则不覆盖） |
| `/var/log/elish-pogo-kb.log` | 日志（>512 KiB 自动轮转 1 份） |

## 使用与配置

`/etc/default/elish-pogo-kb`：

| 键 | 默认 | 说明 |
|---|---|---|
| `ENABLED` | `1` | 0 = 停用（hook 直接退出），下次唤醒生效 |
| `DELAY_SEC` | `3` | 唤醒后延迟秒数（等 resume 完成） |
| `RST_GPIO` | `141` | 键盘 reset 使用的 TLMM 引脚号 |
| `TLMM_LABEL` | `f100000.pinctrl` | 用于定位 gpiochip base（一般不要改） |
| `PULSE_MS` | `150` | 复位脉冲宽度（20–900ms） |

手动复位 / 调试：

```bash
sudo /usr/local/sbin/elish-pogo-kb-reset          # 键盘已接时复位一次
sudo /usr/local/sbin/elish-pogo-kb-reset --force  # 跳过“键盘已枚举”检查
tail -f /var/log/elish-pogo-kb.log
```

## 验证

```bash
sudo ./pogo/verify.sh         # 或 sudo ./install/check-all.sh
```

1. 手动睡眠一次（`sudo systemctl suspend` 或合盖/电源键），用电源键/RTC 唤醒；
2. 唤醒后等 5 秒，键盘应可用；
3. `dmesg` 应出现键盘 `USB disconnect` + `new full-speed USB device number`；
4. `tail -f /var/log/elish-pogo-kb.log` 应看到 `reset start` / `pulsed` / `done`。

## 卸载

```bash
sudo ./pogo/uninstall.sh            # 移除文件（保留日志）
sudo ./pogo/uninstall.sh --purge    # 同时删除日志
```

卸载会尝试释放已导出的 GPIO；建议重启一次让 GPIO/复用状态干净。

## 注意

- **不要**再用 `authorized`/`USBDEVFS_RESET`/重绑控制器来“修”这个假死：历史上重绑
  `a8f8800.usb` 曾触发 `qcom_snps_hsphy_exit` 告警、tee 卡 D 状态、USB 子系统瘫痪。
  本组件只脉冲键盘 reset GPIO，不碰 USB 控制器/PHY。
- 本组件是键盘 MCU 侧问题的兜底；如果以后内核有正确修复（例如 host resume 后按序复位
  外设），可卸载本组件再做长睡验证。
- 若 `verify.sh` 报 `gpio… 尚未导出`：属正常，安装后至少经历一次 suspend/resume 才会导出。
- 若日志出现 `ERROR: cannot set gpio… direction`：说明该引脚被其他驱动占用/复用改了，
  先检查 DTB/pinctrl 是否有新改动。
