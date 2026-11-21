# torch — 可选：GNOME 46 控制中心「手电筒」开关 + `torch` 命令行

> 适用包版本 **2026.11.21**。

把后摄闪光灯（`/sys/class/leds/white:flash`）当手电筒用。**可选组件，默认不装**；
需要时显式启用：`sudo ./install.sh --with-torch ...`（turnkey）或 `sudo ./torch/install.sh`。

> 开机闪光灯误闪修复是**默认组件** [`flash-led/`](../flash-led/README.md)，与本组件相互独立：
> 不装 torch 也会修复开机闪一下；装 torch 只多出手电筒功能。

## 功能

- **GNOME 46 控制中心（右上角 / `Super+S`）里的「手电筒」开关**：点亮/熄灭后摄闪光灯（手电模式）。
- **开启 5 分钟后自动关闭**（防止忘记关；`torch@elish/extension.js` 的 `AUTO_OFF_SECONDS` 可改）。
- 图标随浅色/深色主题切换（内置两个 SVG）。
- **`torch` 命令行**：`torch`（切换）、`torch on|off`、`torch set 1..255`、`torch status`。
- 不需要 root、不需要改 udev：写亮度走 systemd-logind 的
  `Session.SetBrightness("leds", "white:flash", N)`（与 GNOME 上游手电筒草稿、Phosh、
  上游 brightnessctl 同一条通道；logind 只允许**当前活动会话的所有者**调用）。

## 安装

- **随合并包**（推荐）：

  ```bash
  sudo ./install.sh --with-torch --yes          # 完整一键安装时加 --with-torch
  # 或只补装本组件：
  sudo ./install.sh --no-deps --skip-extract --skip-build --with-torch --yes
  ```

- **单独安装**：

  ```bash
  sudo ./torch/install.sh
  ```

安装会：复制扩展到 `<用户>/.local/share/gnome-shell/extensions/torch@elish`、安装
`/usr/local/bin/torch`、把 `torch@elish` 加入该用户的 `org.gnome.shell enabled-extensions`
（若用户已登录图形会话），并做一次 logind 通道自检。

> **GNOME 46 不支持热加载新扩展**：安装后当前桌面不会立刻出现开关，**注销/重新登录**后
> 才会出现在控制中心（这也是为什么安装脚本会提示重新登录）。之后可用
> `gnome-extensions enable torch@elish` / `gnome-extensions info torch@elish` 确认。

## 使用

```bash
# 控制中心：右上角 →「手电筒」开关（点一下开、再点一下关）
# 命令行（走同一条 logind 通道，普通用户即可）：
torch            # 切换
torch off        # 关
torch on         # 开（默认亮度 128/255）
torch set 64     # 自定义亮度（1..255）
torch status     # 当前亮度（0 = 关）
```

可选：把 `torch toggle` 绑到 GNOME 自定义快捷键（设置 → 键盘 → 自定义快捷键 → 命令
`/usr/local/bin/torch toggle`）。

## 实现 / 文件

```
torch@elish/            GNOME 46 扩展（QuickSettings.SystemIndicator + QuickToggle）
  metadata.json         uuid=torch@elish，shell-version=["46"]
  extension.js          开关 UI；读 sysfs 显示状态；写 logind；5 分钟自动关
  torch.js              logind/sysfs helper（无 Shell 依赖，可单独用 gjs 测）
  icons/torch-{white,black}.svg
torch                   命令行（/usr/local/bin/torch）
install.sh / uninstall.sh / verify.sh
```

安装后的路径：

| 内容 | 路径 |
|---|---|
| 扩展 | `~<user>/.local/share/gnome-shell/extensions/torch@elish/` |
| 命令行 | `/usr/local/bin/torch` |
| 启用项 | 用户 dconf `org.gnome.shell enabled-extensions` 含 `torch@elish` |

## 验证 / 卸载

```bash
sudo ./torch/verify.sh            # 文件 + dconf + Shell 加载状态 + logind 通道（未装则 SKIP）
sudo ./torch/uninstall.sh         # 移除扩展/CLI/启用项（下次登录后图标消失）
```

## 实测（本机）

- `torch on|off|set|status` 走 logind `Session.SetBrightness("leds", "white:flash", N)`，
  普通用户（当前活动会话所有者）可用；SSH/系统服务调用会被拒绝。
- 扩展在 headless Shell 测试中状态为 ACTIVE；安装后当前桌面不会热加载，
  **注销/重新登录**后出现在控制中心。
- 拍照闪光（`flash_strobe`）无软件支持，见下。

## 限制 / 注意

- 只支持**手电筒模式**（LED 的 `brightness`）；**拍照用的闪光灯**（`flash_strobe`）不支持：
  本内核 `CONFIG_V4L2_FLASH_LED_CLASS` 未启用，没有 V4L2 flash 子设备/`FLASH_*` 控件；
  `flash_strobe` 还需要 sysfs 写权限（见下），Cheese/Snapshot/guvcview/v4l2-ctl 等相机软件
  都无法驱动它（要做拍照闪光需改 `elish-camera` 或重编内核，属开发项）。
- logind 通道要求**当前活动会话的所有者**；SSH/系统服务里调用会被拒绝（相机/SSH 脚本可改用
  下面的 udev 规则直接写 sysfs）。
- 扩展只声明 `shell-version: ["46"]`（本包目标 Armbian noble / GNOME 46）；GNOME 大版本升级后
  需改 `metadata.json` 并重新安装。
- 本组件不修改 udev/权限；如果想让 `brightnessctl`、SSH 脚本或 `torch flash` 直接写 sysfs
  （例如相机闪光灯测试），可手动加一条 udev 规则（模式同本包 `camera/99-elish-vcm.rules`；
  `caitming` 已在 `video` 组）：

  ```udev
  # /etc/udev/rules.d/99-elish-flash.rules
  ACTION=="add|change", SUBSYSTEM=="leds", KERNEL=="*:flash", RUN+="/bin/chgrp video /sys%p/brightness"
  ACTION=="add|change", SUBSYSTEM=="leds", KERNEL=="*:flash", RUN+="/bin/chmod 0660 /sys%p/brightness"
  ACTION=="add|change", SUBSYSTEM=="leds", KERNEL=="*:flash", RUN+="/bin/chgrp video /sys%p/flash_strobe"
  ACTION=="add|change", SUBSYSTEM=="leds", KERNEL=="*:flash", RUN+="/bin/chmod 0660 /sys%p/flash_strobe"
  ```
  （udev 的 `GROUP=`/`MODE=` 对 sysfs 属性无效，必须用 `RUN+=`。）

## 排查

```bash
gnome-extensions info torch@elish                      # 状态应为 ACTIVE
journalctl --user -b | grep -iE 'torch|extension'      # 扩展加载/报错
torch status                                           # 读 sysfs（0 = 关）
gdbus call --system --dest org.freedesktop.login1 \
  --object-path /org/freedesktop/login1/session/auto \
  --method org.freedesktop.login1.Session.SetBrightness leds white:flash 128
```

GNOME 46 没有内置手电筒开关（上游仍是未合并的 draft），extensions.gnome.org 也没有可用扩展；
本组件即该功能的最小实现（≈100 行），不依赖 UPower（UPower 无 torch 接口）。
