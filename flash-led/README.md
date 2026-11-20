# flash-led — 后摄闪光灯“开机闪一下”修复（默认组件）

小米平板 5 Pro（elish）在 **Armbian** 上每次开机、Plymouth 启动画面显示期间，后摄闪光灯会
**瞬间闪一下**。本组件修复该问题；**默认安装**（`install.sh` / `turnkey.sh` 自动执行），
不修改任何 Armbian 包文件，BSP/apt 升级不会还原。

> 手电筒（把闪光灯当手电用）是**可选**的另一个组件：`torch/`（GNOME 46 控制中心开关 +
> `torch` CLI，默认不装，`--with-torch` 安装）。见 [`../torch/README.md`](../torch/README.md)。

## 根因（2026-11-20 诊断）

- Armbian 的 `armbian-led-state.service` 在开机很早的阶段（Plymouth 启动画面刚出现时）
  执行 `/usr/lib/armbian/armbian-led-state-restore.sh`，按 `/etc/armbian-leds.conf`
  恢复所有 LED 状态。
- 该脚本对 `trigger=none` 有一个 workaround：**先写 `default-on` 再写 `none`**。
- `white:flash`（PM8150L 后摄闪光灯/手电筒，`leds-qcom-flash` 驱动）也在状态文件里。
  `default-on` 触发器的 activate 是 `led_set_brightness_nosleep(max_brightness)` →
  对 flash 类 LED 就是**以最大手电电流（200 mA）点亮**，随后被 `none` 关掉，
  即“闪一下”。

现场证据（`journalctl -b -o short-precise`）：

```
14:11:37.097  Started plymouth-start.service          （启动画面出现）
14:11:37.453  Starting armbian-led-state.service      （LED 状态恢复开始）
14:11:37.469  armbian-led-state-restore.sh: warning: input11::... could not be restored
              （只有过期 input11 的警告；white:flash 无警告 = 写入成功）
14:11:37.782  Finished armbian-led-state.service
```

`/etc/armbian-leds.conf` 中相应 stanza（该文件由关机时的 save 脚本生成，**不是 conffile**，
手动改它没用）：

```ini
[/sys/class/leds/white:flash]
trigger=none
flash_strobe=0
brightness=0
flash_timeout=1280000
flash_brightness=1000000
```

## 修复方式

不复制/不修改 Armbian 的 GPL 脚本，而是用一层 wrapper：

1. `elish-led-state-restore-flash-safe.sh`（安装到
   `/usr/local/lib/elish/elish-led-state-restore-flash-safe.sh`）：
   读取 `/etc/armbian-leds.conf`，**剔除带 `flash_strobe` 属性的 flash 类 LED 的 stanza**
   （白名单式：只有 flash 类 LED 被跳过，其它 LED 原样保留），把过滤后的状态文件写到
   `mktemp` 临时文件，再调用原脚本（原脚本支持把状态文件作为 `$1`，不会碰原文件）。
2. systemd drop-in
   `/etc/systemd/system/armbian-led-state.service.d/50-elish-skip-flash.conf`：
   `ExecStart=` 清空后指向 wrapper。

两者都位于 `/usr/local` 与 `/etc`，**不属于 `armbian-bsp-cli-*` 包**，apt 升级不会覆盖；
即使以后 Armbian 更新了 restore 脚本，wrapper 仍按同样方式过滤（除非其接口不再接受 `$1`，
届时重跑安装脚本即可）。

## 安装 / 卸载 / 验证

```bash
# 安装（root；通常由 ./install.sh 或 turnkey 自动执行）
sudo ./flash-led/install.sh

# 验证（不需要 root；--live 会重启一次恢复服务并抓 udev 事件，需 root）
./flash-led/verify.sh
sudo ./flash-led/verify.sh --live

# 回滚
sudo ./flash-led/uninstall.sh
```

安装脚本自带两项自检：离线过滤自检（假 sysfs 配置，验证 flash 类 stanza 被剔除且普通
LED 保留）+ 检查 systemd 实际 `ExecStart` 已指向 wrapper。

## 实测结果（本机，2026-11-20）

| 项 | 结果 |
|---|---|
| 修复前：重启 `armbian-led-state.service` 的 `white:flash` LED 事件 | 2 条（`TRIGGER=default-on` / `TRIGGER=none`） |
| 修复后：同一操作的事件数 | **0 条**（不再触碰闪光灯） |
| 开机 logo 阶段闪光灯 | 不再闪（修复后重启验证） |
| 普通 LED 状态恢复 | 保持不变（wrapper 只剔除 flash 类 stanza） |

## 限制 / 注意

- 只处理 **Linux 用户态**这一路写入；如果闪光发生在“按电源后、开机 logo 之前”（bootloader
  阶段），则本组件无效（本机实测发生在 Plymouth 阶段，已修复）。
- 拍照用的相机闪光灯（`flash_strobe`）不受影响（本组件只影响开机状态恢复）。
- `/etc/armbian-leds.conf` 由 Armbian 的 save 脚本每次关机重新生成，本组件不需要也不修改它。
- 若以后 Armbian 修改 restore 脚本接口（不再接受 `$1` 状态文件），请重跑
  `sudo ./flash-led/install.sh`（组件会更新 wrapper / 安装方式）。
