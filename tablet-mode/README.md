# 平板模式（可选组件）：开 / 关 / 自动 + GNOME 46 控制中心开关

小米平板 5 Pro 的「平板模式」来自磁吸保护套的霍尔开关（`SW_TABLET_MODE`）；mutter 只有在
平板模式时才会启用**自动旋转**。没有保护套、或保护套霍尔不灵的人，没法通过桌面开关控制它。

本组件提供：

- **uinput helper**（`elish-tablet-mode-switch` + systemd 服务）：按配置发布一个虚拟
  `SW_TABLET_MODE`，不碰真实 `SW_LID`（合盖休眠不受影响）；
- **GNOME 46 控制中心开关**：点击在「自动 → 开 → 关」之间循环，标题显示当前模式；
- 配置文件 `tablet_mode = auto | on | off`，`elish-camera-ctl orientation` 与开关共用。

> 默认**不安装**；需要时显式启用：`sudo ./tablet-mode/install.sh`，或一键安装器加
> `--with-tablet-mode`。只想要命令行（不装 GNOME 扩展）也可以直接装 helper 后使用
> `elish-camera-ctl orientation tablet on|off|auto`。

## 三种模式

| 模式 | 效果 |
|---|---|
| `auto`（默认） | **优先按 pogo 键盘拔插**（GPIO83，`elish-keyboard-detect`）；检测服务不在时退回霍尔 |
| `on` | **总是平板模式**：自动旋转始终开启（适合没有保护套、或霍尔失效的人） |
| `off` | **总是笔记本模式**：自动旋转关闭（当普通平板横屏用） |

### 键盘检测（GPIO83）

厂商 DTS 里 pogo 键盘带一个插入检测引脚：`xiaomi-keyboard,in-irq-gpio = <&tlmm 83>`。
实测该引脚平时为高，**拔插瞬间产生一个 ~1ms 的低脉冲**（打字/空闲不产生脉冲），
`elish-keyboard-detect` 用 `gpiomon` 捕获脉冲并翻转状态，结果写到
`/run/elish-keyboard-present`（键盘在=1，拔出=0），状态持久化在 `/var/lib/elish-keyboard-present`。

- **初始状态**：冷启动默认“未连接”(0)（配置 `/etc/default/elish-keyboard-detect`
  的 `COLD_BOOT_STATE=detached|attached`）；运行中重启服务沿用 `/var/lib/elish-keyboard-present`。
  开机前 10 秒忽略 USB 重枚举脉冲（避免幻影设备误翻状态）。
  本机实测 USB 始终枚举、GPIO83 电平恒高、霍尔不随拔插变化，没有绝对电平信号（厂商驱动也只是
  IRQ 翻转，见 `docs/HISTORY.md`）；
- **输入校准**：监听 pogo 键盘自身的 evdev 键盘节点（`Xiaomi Pad Keyboard`），**任何按键输入都强制
  校准为“已连接”**；本机键盘没有触摸板，`Xiaomi Pad Mouse`/`Xiaomi Pad` 是幻影接口，不参与校准；
- 手动校准：`elish-keyboard-detect --set 0|1`，查看 `--status`；
- 手动校准：`elish-keyboard-detect --set 0|1`；查看：`elish-keyboard-detect --status`
  （服务停过且期间拔插过、或唤醒复位导致错位时用）

`auto` 模式下：

- 键盘在 → 笔记本模式（`SW_TABLET_MODE=0`：关自动旋转、软键盘不弹）
- 键盘拔出 → 平板模式（`SW_TABLET_MODE=1`：开自动旋转、软键盘允许弹）
- 检测服务不在 → 退回霍尔（兼容旧行为）

服务只把该引脚当**输入**读取，不触碰键盘供电（gpio127）和复位（gpio141）。

`rebuild_mode`（相机流在旋转时如何重建）不受影响，仍由 `elish-camera-ctl orientation` 管理。

## 安装

```bash
# 需要相机组件（提供 elish-camera-ctl 与 /etc/elish-orientation.conf）
sudo ./tablet-mode/install.sh          # 可加 --dry-run / --user <用户名>
```

安装内容：

| 路径 | 说明 |
|---|---|
| `/usr/local/bin/elish-tablet-mode-switch` | uinput 虚拟 `SW_TABLET_MODE`（编译自 `camera/elish-camera/tools/tablet_mode_switch.c`） |
| `/etc/systemd/system/elish-tablet-mode.service` | 开机启动、1 秒内响应配置变化 |
| `/usr/local/sbin/elish-keyboard-detect` | 读 GPIO83（键盘插入检测）→ `/run/elish-keyboard-present` |
| `/etc/systemd/system/elish-keyboard-detect.service` | 键盘检测服务（开机启动、0.5 秒轮询） |
| `~<user>/.local/share/gnome-shell/extensions/tablet-mode@elish/` | GNOME 46 Quick Settings 开关 |
| `/etc/elish-orientation.conf` | 调整为 `root:<用户组> 0664`，普通用户可写（切换不需 sudo） |

> GNOME 46 **不支持热加载新扩展**：装完注销/重新登录，控制中心（右上角或 `Super+S`）
> 才会出现「平板模式」开关。

## 使用

- 控制中心：点「平板模式」在 自动 → 开 → 关 之间循环；标题显示当前模式；
- 命令行：`elish-camera-ctl orientation`（查看）/ `elish-camera-ctl orientation tablet on|off|auto`；
- 临时验证（root）：`systemctl status elish-tablet-mode`；`journalctl -u elish-tablet-mode -b`。

## 卸载

```bash
sudo ./tablet-mode/uninstall.sh
```

移除 helper、服务与扩展；保留 `/etc/elish-orientation.conf`。卸载后 `auto` 行为仍由内核霍尔提供。

## 安全/依赖

- helper 以 root 运行（创建 `/dev/uinput` 设备）；只读取 `/etc/elish-orientation.conf`，
  该文件按用户组可写，但最坏情况只是切换屏幕方向/自动旋转，不涉及提权。
- 依赖：`gcc`（编译 helper）、GNOME Shell 46（扩展声明 `shell-version: ["46"]`）、
  相机组件里的 `elish-camera-ctl`（扩展用它写配置；helper 不依赖它）。
- 升级 GNOME Shell 大版本后需更新 `metadata.json` 的 `shell-version` 并重装。
