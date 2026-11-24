# utils/waydroid — Waydroid 软键盘跟随平板模式

按 elish 的虚拟 `SW_TABLET_MODE` 设置 Android 的
`Settings.Secure.SHOW_IME_WITH_HARD_KEYBOARD`：

| 平板模式 | `show_ime_with_hard_keyboard` | 效果 |
|---|---|---|
| 开（纯触摸，无键盘） | 1 | 允许软键盘弹出 |
| 关（笔记本/pogo 键盘） | 0 | 不自动弹软键盘 |

平板模式本身由 `tablet-mode/` 组件产生（`auto` 模式已改为优先按 pogo 键盘拔插，
回退霍尔，见 `tablet-mode/README.md`）。

## 依赖

- Waydroid 已安装并能启动会话（`waydroid session start`）；
- Android 侧装了输入法（如搜狗/Gboard）；
- `tablet-mode/` 组件已安装（提供 `elish-tablet-mode` 这个 evdev 设备）。

## 安装 / 卸载

```bash
sudo ./utils/waydroid/install.sh
sudo ./utils/waydroid/uninstall.sh
```

安装内容：

| 路径 | 说明 |
|---|---|
| `/usr/local/sbin/elish-waydroid-ime-watch` | watcher（每 2 秒读一次 evdev，状态变化时才调 `waydroid shell`） |
| `/etc/systemd/system/elish-waydroid-ime.service` | 开机启动 |

## 自检

```bash
./utils/waydroid/verify.sh          # 服务/设备/当前设置
```

## 资源占用（实测）

- 空闲 CPU：约 0.01% 单核（1 ms / 10 s）；
- 内存：约 11 MB；
- 只在平板模式切换时才 spawn 一次 `waydroid shell`（几毫秒）。

## 说明

Watcher 只改 Android 的 IME 策略设置，不修改 Waydroid 本体；Waydroid 的输入设备是
FIFO 模拟的（`/dev/input/wl_keyboard_events`），宿主侧无法让它“消失”，所以用这个设置来等价实现
“有键盘不弹、没键盘弹”。
