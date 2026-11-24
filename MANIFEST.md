# 合并包清单（MANIFEST）

合并包 = 传感器安装包（已清理）+ 指纹安装包（已清理）+ GNSS 子包 + 共享内核/DTB 资产
+ 相机/闪光灯修复（默认）、pogo 键盘唤醒自动复位（默认）、相机画质调校提取脚本、
Hi556 已合并进联合 DTB + 构建脚本 + 可选 GNOME 手电筒 / bioauth + 合并文档。
**不包含任何设备调校数据/DTB/DTS 提取物**。
**不含**固件、编译产物、日志、指纹模板、密钥/序列号、PAM/sudoers 备份。

## 顶层

```
README.md / README.en.md / QUICKSTART.md / INSTALL.md / NOTES.md / PATCHES.md / VERSIONS.md / MANIFEST.md / LICENSE / SHA256SUMS
install.sh     一键安装入口（= install/turnkey.sh 的包装）
kernel/        统一内核（详见下）
sensors/       传感器子包（自包含）
fingerprint/   指纹子包（自包含）
bioauth/       可选：通用生物认证 PAM 栈（PAM module + daemon + GTK4 helper；默认不装；
                需显式 --with-bioauth / --bioauth-sudo / --bioauth-pkexec）
gnss/          GNSS 子包：airoha_gps 驱动源码、airoha-gnssd/gps-nmea-share 用户态、systemd/gpsd 集成、
                协议与排障（gnss/docs/PROTOCOL.md）、flash 修复说明（gnss/extract/）
install/       一键安装器（turnkey/extract-all/build-userspace + lib/）、备份启动槽脚本（backup-boot.sh）、控制台静音（quiet-console.sh）
                与合并自检（check-all.sh）、文件落位表
docs/          硬件状态权威基线（HARDWARE-STATUS.md）、整机 TODO、历史记录（HISTORY.md）、
                升级影响（UPGRADE-IMPACT-ALL.md）、内核升级风险（KERNEL-UPGRADE-RISK.md）、
                设备数据/固件提取指南（DEVICE-DATA-EXTRACTION.md）、安全加固说明（HARDENING.md）
camera/        相机子包：elish-camera GPU 管线（前后摄全分辨率、GPU debayer、Venus 硬编、
                双虚拟相机、autoserve、自动对焦；LSC/CCM 仅提供本机提取脚本，不随包带调校数据）
                + 旧 OV8856 helper + install.sh + elish-camera/verify.sh
flash-led/     后摄闪光灯开机误闪修复（默认组件）：Armbian LED 状态恢复守卫（wrapper + drop-in；不改 Armbian 包文件）
pogo/          默认组件：pogo 键盘唤醒自动复位（sleep hook + 脉冲键盘 reset GPIO；用户态）
torch/         可选：GNOME 46 手电筒 Quick Settings 扩展 + torch CLI（默认不装；--with-torch 或单独 install.sh）
tablet-mode/   可选：平板模式开关（开/关/自动）+ GNOME 46 控制中心扩展；uinput helper + 键盘拔插检测 + systemd 服务
pps-charger/   可选：受控 11V PPS 快充服务（8s keep-alive、温度分档；装后默认启用；--with-pps-charger）+ 控制中心「充电功率」扩展
```

## kernel/

| 内容 | 说明 |
|---|---|
| `README.md` | 统一内核构建步骤、配置/ABI 校验、联合 DTB/boot 镜像 |
| `build-and-install.sh` | 一键补丁/配置/编译/模块/DTB/initramfs/Linux 启动槽（按 armbianEnv 自动检测；自动备份；不碰 Android 槽） |
| `compat-check.sh` | 升级前只读兼容性检查：补丁 dry-run + 整文件副本 diff + 关键符号/DTS 检查（支持 --src / --fetch-ref） |
| `patch-lib.sh` | 补丁状态判定（正向/反向 dry-run + 新增行命中 ≥70%），`build-and-install.sh` / `compat-check.sh` 共用 |
| `install-dtb.sh` | 只安装包内单一联合 DTB（`--write-boot` 才重建 Linux 槽） |
| `update-boot-image.sh` | 预检 DTB/initramfs + 备份目标 Linux 启动槽 + 重建 + 回读校验（槽位自动检测；`--slot` 断言） |
| `install-new-kernel.sh` | 安装内核并写 Linux 启动槽的脚本（自动检测；历史脚本，不推荐） |
| `qseecom/` | 指纹 QSEECOM TEE 驱动 |
| `mdt_loader.c` / `qcom_scm.c` | 指纹内核文件 |
| `goodix_fp_spi/` | 指纹传感器驱动源码（无编译产物） |
| `config-used-6.18.44` / `kernel.release` | 内核配置/版本（含 `CONFIG_ANDROID_BINDERFS=y`，Waydroid 前置；见 `kernel/README.md`「Waydroid」） |
| `ARMBIAN-BASELINE.md` | Armbian sm8250 基线获取说明（不随包补丁集） |
| `patches/0001-fastrpc-…patch`、`fastrpc.c.modified` | 传感器 fastrpc 补丁/完整文件 |
| `patches/fingerprint/` | 指纹内核补丁：**qseecom-tee-series.patch（14 文件权威系列）** + fp-spi ×4 + scm-qseecom 分片 |
| `patches/0002-pinctrl-lpass-lpi-defer-on-clock-timeout.patch`、`PINCTRL-LPASS.md` | LPASS pinctrl defer（pogo 键盘/USB，独立问题） |
| `patches/0003-qcom-mdt-loader-user-selectable.patch` | QCOM_MDT_LOADER 用户可选（TEE_QSEECOM 依赖） |
| `patches/0004-smb5-typec-legacy-reset-resume.patch`、`CHARGER-RESUME.md` | SMB5 suspend/resume 后 Type-C legacy/100mA 卡死修复 + 验证记录 |
| `patches/0005–0008-*.patch` | 相机补丁：OV8856 BGGR/VFLIP、OV13B10 供电/reset、CN3927V VCM、Hi556 OF |
| `patches/0009-fastrpc-listener-unfreezable.patch` | FastRPC listener `PF_NOFREEZE`：修复 s2idle 唤醒后 sensor PD 崩溃（睡眠死机根因） |
| `patches/0010-smb5-fast-charge-current-vbus.patch` | SMB5 快充电流：PD 9V 时电池充电电流 1.5A→6A（~15W），5V 档保持 1.5A |
| `patches/0011-charger-taper-stepdown.patch` | 高电量/异常时对半降充电电流 |
| `patches/0012-charger-soc-step-charging.patch` | 按电量分段的充电曲线（6A/4A/2.5A/1.5A/1A/0.5A） |
| `patches/0013-charger-ignore-fullon-flag.patch` | 忽略 FULL_ON 正常标志，只对真 inhibit/terminate 降档 |
| `include/` | 指纹驱动必需的 3 个内核头文件 |
| `INTEGRATION.md` | 头文件 + drivers/tee Kconfig/Makefile 集成步骤 |
| `initramfs/` | 修复版 initramfs hook + 安装脚本（防止 SLPI 固件进 initramfs） |
| `dtb/` | **单一**已验证联合 DTB（模型级，已合并相机/Hi556 + 32MiB TZ 专用 reserved-memory）+ 说明/参考/校验脚本 |
| `dtb/hi556/` | Hi556 **构建/应用方法脚本**（不再分发单独 stage1/stage2 DTB）；联合 DTB 已含 Hi556；DTS/patch 不随包 |
| `boot/` | `zz-update-abl-kernel` 系统 hook 副本（参考；统一用 update-boot-image.sh） |
| `integration/` | DTS vmids 片段（完整基线重建参考） |

## sensors/

原传感器安装包的用户态部分：`README/INSTALL/NOTES`、`userspace/`（hexrpc/iio/libssc）、
`systemd/`、`scripts/`、`install/`、`extract/`、`docs/`（TROUBLESHOOTING、IIO-FIX、UPGRADE-IMPACT）。
子包版本/补丁/清单信息已合并进 `README.md` / `NOTES.md`，避免与根 `VERSIONS.md` / `PATCHES.md` 重复；
内核资产统一在顶层 `kernel/`（不在 `sensors/` 内重复）。

## fingerprint/

| 内容 | 说明 |
|---|---|
| `README/INSTALL/NOTES/MANIFEST` | 指纹子包文档（安装指向 `../kernel/`） |
| `src/qsee-supplicant/` | supplicant + app-loader 源码（0.1.1，无二进制/.git） |
| `src/libfprint/` | goodixqsee 驱动 + 日志补丁（相对 430e24e5） |
| `system/` | pam.d、systemd、udev、bin、user-bin 配置/脚本 |
| `extract/` | `extract-gfenu-ta.sh` + TA 来源与 sha256 |
| `install/` | 安装/自检/卸载脚本 |

## bioauth/（可选，默认不装）

通用（不绑定 Goodix/TA）的生物认证 PAM 栈，复用本包 fprintd/libfprint 后端。合并包默认
**不安装**；只有 `./install.sh --with-bioauth`（或 `--bioauth-sudo` / `--bioauth-pkexec`）
才会安装，单独安装/回滚见 `bioauth/INSTALL.md`。安全边界、PAM 审计与验证结论已并入 `bioauth/README.md`。

| 内容 | 说明 |
|---|---|
| `README.md` / `INSTALL.md` | 组件说明、安全边界/审计结论、安装/回滚/安全红线 |
| `daemon/bioauthd.py` | root daemon：状态/锁定/密码校验/fprintd 后端/session 级 cancel |
| `pam/pam_bioauth.c` | PAM 模块（TTY + GUI 单窗口，req-scoped cancel，超时不计数） |
| `gui/bioauth-ui` | 单窗口全屏 GTK4 “安全屏幕” helper（ready 握手 / attempt id / 日志脱敏） |
| `gui/tests/helper_driver.py` | helper 独立驱动（截图/几何/AT-SPI 交互验证） |
| `config/` `systemd/` `pam.d/` | 默认配置、systemd 单元、测试服务与 pkexec/polkit PAM |
| `scripts/` | `install-bioauth.sh`（安装/接 sudo/接 pkexec/回滚/卸载/--dry-run）、`bioauth-doctor`、fprintd-verify 队列 |
| `tests/` | daemon 单测 + TTY/GUI 端到端（无需 root，不碰系统 PAM） |

## gnss/

Airoha AG3335 GNSS 子包（2026-11-12 打通，2026-11-13 室外真实定位验证）：

| 内容 | 说明 |
|---|---|
| `README.md` / `INSTALL.md` / `NOTES.md` | 子包说明、安装、限制与排障 |
| `docs/PROTOCOL.md` | 主机协议（PAIR ASCII）、启动链/波特率、anld 下载流程与镜像表（仅修复 flash 用） |
| `kernel/` | `airoha_gps_driver.c` + Makefile：`/dev/airoha_gps` 的 OPEN/CLOSE/DF/DI（电源/时钟/pinctrl），无内核源码补丁 |
| `userspace/` | `airoha-gnssd.c`：上电 + PAIR 运行时初始化 + NMEA→pty + 自愈；`gps-nmea-share.c`：gpsd NMEA → GeoClue socket（均为纯 C，无第三方依赖） |
| `systemd/` | `airoha-gnssd.service`（Type=notify）、`gps-nmea-share.service`、gpsd/geoclue drop-in |
| `polkit/` | `49-iio-sensor-proxy-geoclue.rules`：放行 geoclue 用户 claim iio 传感器（GeoClue compass heading 必需） |
| `install/` | `install.sh`（含 gpsd 配置）、`verify.sh`、`uninstall.sh` |
| `extract/` | 仅当 GNSS flash 损坏需重刷时的厂商文件提取说明（正常使用不需要） |

## camera/

| 内容 | 说明 |
|---|---|
| `README.md` | 当前状态、限制、安装/自检入口 |
| `elish-camera/` | C 源码（capture/gpu_debayer/venus_enc/loopback/main）、tools、`docs/architecture.md`、`docs/interface.md`、`verify.sh` |
| `elish-camera-*` | 辅助脚本：ctl/scan/init/color/rear-*/vcam/autostart/switch/check-usb/gui |
| `install.sh` | 一键安装（编译 + 脚本/udev/自启/休眠恢复 + orientation 权限 + 可选调校提取） |
| `system/` | 休眠唤醒恢复（worker / sleep hook / oneshot service） |
| `99-elish-vcm.rules` / `99-elish-dma-heap.rules` | VCM focus sysfs video 组可写 / DMA heap 权限 |
| `elish-vcam.modprobe.conf` / `elish-vcam.modules-load.conf` | 两个 v4l2loopback 设备（/dev/video2 前 + /dev/video20 后，NV12 全分辨率） |

## flash-led/（默认组件）

| 内容 | 说明 |
|---|---|
| `README.md` | 根因/证据、修复方式、升级注意、实测结果 |
| `elish-led-state-restore-flash-safe.sh` | wrapper：过滤 `/etc/armbian-leds.conf` 中 flash 类 LED 的 stanza 后调用 Armbian 原 restore 脚本 |
| `install.sh` / `uninstall.sh` | 安装/回滚（wrapper + systemd drop-in；自带离线过滤自检与 `ExecStart` 检查） |
| `verify.sh` | 静态检查 + 离线过滤自检；`--live` 重启恢复服务并抓 udev 事件（应为 0 条 `white:flash`） |

## pogo/（默认组件）

| 内容 | 说明 |
|---|---|
| `README.md` | 现象/根因修正（键盘 MCU 侧，非 DWC3 PHY）、修复方式、安装/配置/验证/卸载、安全注意 |
| `elish-pogo-kb-reset` | 复位脚本：定位 TLMM gpiochip（label `f100000.pinctrl`）→ 脉冲 TLMM 141 低 150ms 再拉高；带 flock 与日志轮转 |
| `system-sleep/69-elish-pogo-kb.sh` | 唤醒 post 阶段 `systemd-run --on-active=3s` 调度复位（等 USB/xHCI resume 完成）；未接键盘则跳过 |
| `elish-pogo-kb.conf` | 默认配置：`ENABLED` / `DELAY_SEC=3` / `RST_GPIO=141` / `TLMM_LABEL` / `PULSE_MS=150` |
| `install.sh` / `uninstall.sh` / `verify.sh` | 安装（脚本 + hook + 配置 + 日志）/卸载（可 `--purge`）/自检（未安装则 SKIP） |

## torch/（可选组件，默认不装）

| 内容 | 说明 |
|---|---|
| `README.md` | 功能、安装/卸载/验证、logind 原理、限制、可选 raw-sysfs udev 规则 |
| `torch@elish/` | GNOME 46 Quick Settings 扩展（metadata/extension.js/torch.js/图标；开启 5 分钟自动关） |
| `torch` | CLI：`torch on|off|toggle|set N|status`（安装到 `/usr/local/bin/torch`） |
| `install.sh` / `uninstall.sh` / `verify.sh` | 安装（用户级扩展 + 用户 dconf 启用）/卸载/验证 |

## tablet-mode/（可选组件，默认不装）

| 内容 | 说明 |
|---|---|
| `README.md` | 用途、三种模式、安装/使用/卸载、安全与依赖 |
| `install.sh` / `uninstall.sh` | 安装/卸载（编译 uinput helper、装 systemd 服务、装 GNOME 扩展并写 dconf） |
| `verify.sh` | 自检（未安装则 SKIP）：helper、服务、配置可写、扩展与加载状态 |
| `systemd/elish-tablet-mode.service` | 开机启动 helper（`/usr/local/bin/elish-tablet-mode-switch`） |
| `elish-keyboard-detect.py` | 读 GPIO83 脉冲（pogo 键盘拔插）→ `/run/elish-keyboard-present` |
| `systemd/elish-keyboard-detect.service` | 键盘检测服务（开机启动） |
| `tablet-mode@elish/` | GNOME 46 Quick Settings 扩展（开/关/自动循环；读 `/etc/elish-orientation.conf`） |

helper 源码复用 `camera/elish-camera/tools/tablet_mode_switch.c`（uinput 虚拟 `SW_TABLET_MODE`，不碰真实 lid）。

## pps-charger/（可选组件，默认不启用）

| 内容 | 说明 |
|---|---|
| `README.md` | 实测结论（本机 100W 头 PPS 13s 看门狗，8s keep-alive 稳定；11V ~20.5W）、策略、安装/使用、安全注意 |
| `elish-pps-charger` | Python 服务：PPS 11V + 8s keep-alive，按电池温度 100%/75%/55% 分档（上限 4.5A）；≥41.5°C 或 ≥90% 回 9V，失败退避 |
| `systemd/elish-pps-charger.service` | root 服务（enabled + active，开机自启） |
| `install.sh` / `uninstall.sh` / `verify.sh` | 安装并启用（含扩展）/ 卸载并回 9V、移除扩展 / 自检（未装 SKIP） |
| `charge-meter@elish/` | 控制中心「充电功率」GNOME 46 扩展：3 秒刷新，显示 充电 XX.XW / 放电 -X.XW / 已充满；点击打开设置→电源（纯用户级） |

## 明确不包含 / 需现场获取

| 内容 | 原因 | 获取方式 |
|---|---|---|
| SLPI 单文件固件 `slpi.mbn` | 厂商固件二进制 | `sensors/extract/extract-pmos-slpi-mbn.sh`（pMOS APK） |
| sensors registry/config/socinfo、proto/hals、acdb | 设备型号数据 | `sensors/extract/`（armbian-firmware + Android vendor 镜像） |
| 指纹 TA `gfenu.*`（4.8MB） | 厂商签名固件 | `fingerprint/extract/extract-gfenu-ta.sh`（自己设备） |
| GNSS 厂商镜像（`ag3335_bootloader.bin` 等 5 个） | 已在设备 GNSS flash 内且能正常启动；**正常使用不需要** | 仅 flash 损坏时：`gnss/extract/README.md` |
| `fastrpc.ko`、`goodix_fp_spi.ko`、`airoha_gps.ko` | 与内核 ABI 绑定 | 按 `kernel/README.md` / `gnss/kernel/README.md` 编译 |
| 后摄 EEPROM 校准 dump（24c64，8KB） | 单机工厂校准数据（本机私有） | 从自己设备 at24 sysfs 读取：`docs/DEVICE-DATA-EXTRACTION.md` |
| hexagonrpcd/libssc/iio/libfprint/qsee 二进制 | 编译产物（本包不附带任何预编译） | 按各子包 README 编译 |
| 日志、指纹模板、PAM/sudoers 备份、Android 抓包/工具 | 运行记录/私有/非安装必需 | 不随包 |

## 统计

**345 个文件；源文件合计约 5.2 MB**（不含 `SHA256SUMS`）。**无 ELF/固件/日志/TA/指纹模板/单机校准 dump**；
唯一二进制是已合并 Hi556 的模型级联合 DTB；`SHA256SUMS` 已按最终树生成（345 条，`sha256sum -c` 通过）。
