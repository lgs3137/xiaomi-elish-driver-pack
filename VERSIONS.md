# 版本与校验值（合并包 BOM）

> 本包不含编译产物/固件；下列 sha256/md5 用于安装后交叉核对。
> **本版基线：2026-11-22**（release 内核构建 #22 + 0009 睡眠修复 + 0010–0016 PD 快充/分段充电/bq2597x 并联泵/满电状态 + 0017 唤醒电源键抑制；联合 DTB 含 Hi556 与 PPS APDO；用户态默认组件新增 `pogo/` pogo 键盘唤醒自动复位）。
> 历史版本记录见 `docs/HISTORY.md`。

## 内核

| 项 | 值 |
|---|---|
| 运行内核 | `6.18.44-current-sm8250`（release 构建 `#22 SMP Sun Nov 22 01:52:12 CST 2026`，无诊断选项） |
| 基线源码 | Linux v6.18.44（tar.xz sha256 `0f72d938f06828e82c90405174fe572287db7bfe089e2fc46572a99a7f240d43`）+ Armbian sm8250 补丁（获取方式见 `kernel/ARMBIAN-BASELINE.md`） |
| 配置 | `kernel/config-used-6.18.44`，sha256 `5d102e999c3a6c63bc17f659361963b8`（TEE/QSEECOM/MDT/BTF/FASTRPC；LOCALVERSION=-current-sm8250） |
| 安装后 fastrpc.ko sha256 | `d8e3d3828dcfa94d514c45eca72c159205c1dc94dc98d72d2894aeff5080a94a`（含 0009） |
| 安装后 goodix_fp_spi.ko sha256 | `4951f1c00f13fe7e345dbe5a81c31dc5622ac482a2f5a630d3bac1ddc7d5471b` |
| 安装后 airoha_gps.ko sha256 | `341536a71580df93057de22a7fd0d8ba336aa73ef0fee241584ee7b28a9b92ac` |
| 传感器补丁 | `kernel/patches/0001-fastrpc-sdsp-vmid-and-sensors-pd.patch`（2 hunk） |
| LPASS pinctrl 补丁 | `kernel/patches/0002-pinctrl-lpass-lpi-defer-on-clock-timeout.patch`（1 hunk，独立问题） |
| 睡眠修复补丁 | `kernel/patches/0009-fastrpc-listener-unfreezable.patch`（fastrpc listener `PF_NOFREEZE`；s2idle 唤醒不再崩 sensor PD） |
| 快充补丁（0010） | `kernel/patches/0010-smb5-fast-charge-current-vbus.patch`（PD 9V 时 SMB5 电池充电电流 1.5A→6A；实测低电量 ~15W） |
| 充电降档（0011） | `kernel/patches/0011-charger-taper-stepdown.patch`（检测到 VBAT 偏高/终止时对半降流） |
| 分段充电（0012） | `kernel/patches/0012-charger-soc-step-charging.patch`（按电量分段：<70% 6A、70–80% 4A、80–88% 2.5A、88–93% 1.5A、93–97% 1A、≥97% 0.5A） |
| FULL_ON 误判修复（0013） | `kernel/patches/0013-charger-ignore-fullon-flag.patch`（`BATT_GT_FULL_ON` 是正常模式标志，不再触发降档） |
| bq2597x 并联泵（0014） | `kernel/patches/0014-bq2597x-probe-typec-notifier.patch`（probe 后台重试 typec psy + notifier delayed-work；修复后 master/slave `present=1`，9V 下参与充电） |
| 泵 SoC 门控（0015） | `kernel/patches/0015-bq2597x-soc-gated-charging.patch`（≥96% 关闭泵、<96% 恢复、每 30s 复查） |
| 电池状态（0016） | `kernel/patches/0016-bq27xxx-discharging-status.patch`（放电优先于 FC 满电标志；修复 100% 拔线仍显示 Full/充电） |
| 唤醒电源键（0017） | `kernel/patches/0017-pwrkey-post-resume-grace.patch`（resume 后 6s 内丢弃电源键事件，防连按反复 suspend） |
| 内核集成 | `kernel/include/`（3 头文件）+ `kernel/INTEGRATION.md`；权威系列补丁 `kernel/patches/fingerprint/qseecom-tee-series.patch`（14 文件） |
| boot hook 参考 | `kernel/boot/zz-update-abl-kernel`（系统 hook 副本）；统一用 `kernel/update-boot-image.sh` |
| QCOM_MDT_LOADER Kconfig | `kernel/patches/0003-qcom-mdt-loader-user-selectable.patch` |
| boot 镜像更新 | `kernel/update-boot-image.sh`（预检+备份+回读校验） |
| 联合 DTB（随包） | `kernel/dtb/sm8250-xiaomi-elish-csot.dtb`，sha256 `d7840b30c36290e6735d6bf96605929304e16c199a510b373782589b64234354`（模型级，无本机私有信息；含相机/OV8856/OV13B10/Hi556、GNSS QUP5 UART + bcm4775 + PMIC GPS clock、指纹节点、**PPS APDO 3.3–11V/5A**） |
| 内核 Image / boot 镜像 | `/boot/vmlinuz-6.18.44-current-sm8250` sha256 `07fedab0c36f422210b781f0f8aeb5ef795ee75985e817bb9e4c4693876ea2f0`；`/boot/armbian-kernel-csot.img` sha256 `5e042b6927d470ca890f6a9df4c35f2a14b73746a6f05a52a6d4ff82c8278bd8` |
| initramfs hook | `kernel/initramfs/hooks/xiaomi-elish-firmware`（修复版，跳过 slpi 符号链接/禁用文件） |
| DTB 关键项 | `qcom,vmids=<3 15 5 6>`；`/fingerprint` `firmware-name="gfenu"`、`compatible="goodix,gf3626"` |

## bioauth（可选组件，默认不装）

| 项 | 值 |
|---|---|
| 组件 | 通用生物认证 PAM 栈（PAM module + root daemon + GTK4 单窗口 helper） |
| 源码 | `bioauth/`（同源快照；含 tests / doctor / install脚本） |
| 安装 | 默认不装；`--with-bioauth`，PAM 接入用 `--bioauth-sudo` / `--bioauth-pkexec` |
| 依赖 | fprintd/libfprint（本包指纹栈）；构建需 libpam0g-dev、python3-gi、gir1.2-gtk-4.0 |
| 验证 | `bioauth-doctor` 31 项；`make check` / `check-tty` / `check-gui` |
| 回滚 | `sudo bioauth/scripts/install-bioauth.sh --rollback`（PAM 备份在 `/root/bioauth-sudo-backup-*`） |

## flash-led（默认组件）

| 项 | 值 |
|---|---|
| 组件 | 后摄闪光灯开机误闪修复（Armbian LED 状态恢复守卫） |
| 文件 | `flash-led/`（wrapper + systemd drop-in 的安装/卸载/验证脚本） |
| 安装 | 默认安装（`install.sh` / turnkey 系统集成阶段）；单独：`sudo ./flash-led/install.sh` |
| 安装路径 | `/usr/local/lib/elish/elish-led-state-restore-flash-safe.sh`；`/etc/systemd/system/armbian-led-state.service.d/50-elish-skip-flash.conf` |
| 验证 | `./flash-led/verify.sh`；`--live`（root）重启恢复服务并抓 udev，应为 0 条 `white:flash` 事件 |
| 回滚 | `sudo ./flash-led/uninstall.sh` |

## pogo（默认组件，用户态）

| 项 | 值 |
|---|---|
| 组件 | pogo 键盘唤醒自动复位（修复唤醒后键盘 HID 假死；不改内核） |
| 文件 | `pogo/`（复位脚本 + systemd sleep hook + 默认配置 + install/uninstall/verify + README） |
| 安装 | 默认安装（turnkey 系统集成阶段；`--no-pogo` 跳过）；单独：`sudo ./pogo/install.sh` |
| 安装路径 | `/usr/local/sbin/elish-pogo-kb-reset`；`/usr/lib/systemd/system-sleep/69-elish-pogo-kb.sh`；`/etc/default/elish-pogo-kb`；日志 `/var/log/elish-pogo-kb.log` |
| 行为 | 唤醒后 +3s（systemd-run 延迟）检测到键盘则脉冲 TLMM 141（低 150ms 再高），键盘重枚举 ~1–1.5s 后恢复；每次唤醒 Device 号递增 |
| 验证 | `sudo ./pogo/verify.sh`；实机：手动睡/醒 + 3 轮 `systemctl suspend`+RTC 自动唤醒，hook 均按 +3s 触发、无死机 |
| 回滚 | `sudo ./pogo/uninstall.sh`（`--purge` 连日志删除；建议重启一次） |

## torch（可选组件，默认不装）

| 项 | 值 |
|---|---|
| 组件 | GNOME 46 手电筒 Quick Settings 扩展 + `torch` CLI |
| 文件 | `torch/`（`torch@elish/` 扩展、`torch` CLI、install/uninstall/verify） |
| 安装 | 默认不装；turnkey 加 `--with-torch`，或单独 `sudo ./torch/install.sh` |
| 安装路径 | `~<user>/.local/share/gnome-shell/extensions/torch@elish/`；`/usr/local/bin/torch`；用户 dconf `enabled-extensions` |
| 依赖 | GNOME Shell 46（`shell-version: ["46"]`）、systemd-logind `Session.SetBrightness("leds", ...)` |
| 验证 | `sudo ./torch/verify.sh`；`gnome-extensions info torch@elish`（ACTIVE；新装需注销/重新登录） |
| 回滚 | `sudo ./torch/uninstall.sh` |

## tablet-mode（可选组件，默认不装）

| 项 | 值 |
|---|---|
| 组件 | 平板模式开关（开/关/自动）+ GNOME 46 控制中心扩展；uinput 虚拟 `SW_TABLET_MODE` |
| 文件 | `tablet-mode/`（install/uninstall/verify、systemd 单元、`tablet-mode@elish/` 扩展） |
| 安装 | 默认不装；turnkey 加 `--with-tablet-mode`，或单独 `sudo ./tablet-mode/install.sh` |
| 安装路径 | `/usr/local/bin/elish-tablet-mode-switch`；`/etc/systemd/system/elish-tablet-mode.service`；`~<user>/.local/share/gnome-shell/extensions/tablet-mode@elish/` |
| 配置 | `/etc/elish-orientation.conf` 的 `tablet_mode=on|off|auto`（安装后设为 root:<用户组> 0664，普通用户可写） |
| 依赖 | gcc（编译 helper）、GNOME Shell 46、相机组件的 `elish-camera-ctl`（写配置） |
| 验证 | `sudo ./tablet-mode/verify.sh`；`systemctl status elish-tablet-mode`；`gnome-extensions info tablet-mode@elish` |
| 回滚 | `sudo ./tablet-mode/uninstall.sh` |

## pps-charger（可选组件，默认不启用）

| 项 | 值 |
|---|---|
| 组件 | 受控 11V PPS 快充服务（8s keep-alive + 温度分档；本机充电头 PPS 有 ~13s 看门狗） |
| 文件 | `pps-charger/`（Python 服务、systemd unit、`charge-meter@elish` 充电功率扩展、install/uninstall/verify、README） |
| 安装 | 可选组件；`sudo ./pps-charger/install.sh` 安装并启用（turnkey: `--with-pps-charger`） |
| 安装路径 | `/usr/local/sbin/elish-pps-charger`、`/etc/systemd/system/elish-pps-charger.service` |
| 策略 | 电量<88% 且温度<41.5°C 时切 PPS 11V，电流 = min(源上限, 4.5A) 按温度 100%/75%/55% 分档；每 8s 重发请求并重设 SMB5 ICL=3A；≥41.5°C、≥88% 或 SMB5 报 Full（提前浮充）回 9V 固定档交给涓流，≤38.5°C 再试；失败退避 30s–5min |
| 依赖 | `kernel/dtb` 的 sink PDO 含 PPS APDO；GNOME/TCPM sysfs 可写（root） |
| 验证 | `sudo ./pps-charger/verify.sh`；`journalctl -u elish-pps-charger` |
| 回滚 | `sudo ./pps-charger/uninstall.sh`（并退回 9V 固定档） |

## 传感器用户态

| 组件 | 版本/来源 | 安装后 sha256（参考） |
|---|---|---|
| hexagonrpc | tag v0.3.2（commit `b7eff23`）+ warm-attach 补丁 + M2 可写 registry 补丁 | `/opt/hexrpc-032b/bin/hexagonrpcd` = `ec9c370e4ddb95196e4bf56a5001a93aad67381d56e1eccc935b90fe54ea6312` |
| libssc | 0.4.4（`v0.4.4-9-g4e4c6c8`） | `/usr/local/lib/aarch64-linux-gnu/libssc.so.2` = `a46d9ca7878ea7d58f4de382b4f58f323d97cb3f4c5ec7fef5e74f91e27fe944`（见 `sensors/userspace/libssc/README.md`） |
| iio-sensor-proxy | commit `ca0d5b0`（3.9-1）+ 三处补丁 | `/usr/libexec/iio-sensor-proxy` = `c6e707c4e01d2461ce182e5bc5b69c17a1449b77def5939eb2a21e5cb306d49d` |

传感器数据（不随包）：registry 155 / config 40 / proto 79 / socinfo 6 / SLPI `slpi.mbn`
md5 `51c3b3bef20a76d386a516dfbcc72b68`（7,633,828 B）。

## GNSS 用户态

| 组件 | 版本/来源 | 说明 |
|---|---|---|
| airoha-gnssd | 本包 `gnss/userspace/`（C，无第三方依赖） | 上电 + PAIR 运行时初始化 + NMEA→pty + 自愈；安装后 `/usr/local/sbin/airoha-gnssd` |
| gps-nmea-share | 本包 `gnss/userspace/`（C，无第三方依赖） | gpsd NMEA → GeoClue2 network-nmea Unix socket；安装后 `/usr/local/sbin/gps-nmea-share` |
| airoha_gps.ko | 本包 `gnss/kernel/`（从 Android 下游移植到主线 6.18） | `/dev/airoha_gps` 的 OPEN/CLOSE/DF/DI；与内核 ABI 绑定，需按 `gnss/kernel/README.md` 重编 |
| gpsd | Ubuntu noble 3.25 | 读取 `/dev/ttyGNSS0`（NMEA0183） |
| AG3335 固件 | 设备 GNSS flash 内已有 | **不随包**；正常使用不需要重刷 |

## 指纹用户态

| 组件 | 版本/来源 | 安装后 sha256（参考） |
|---|---|---|
| qsee-supplicant / app-loader | 0.1.1（wrobelda/qsee-supplicant，commit `36e06680`） | `/usr/sbin/qsee-supplicant` = `c81bb42eacee195a80c983d36b9464aadcc00b135a2ec3f6b05d401589fd5371`；`/usr/sbin/qsee-app-loader` = `2d0703086862f04ceb008d0eaf02efffb3cf307fb1b17665a953da62522c92a3` |
| libfprint | wrobelda/libfprint `goodix-qsee`（1.94.100，文档基准 commit `430e24e5`；归档为 tarball，本地以版本+补丁 sha256 锁定）+ 日志补丁 | `/usr/lib/aarch64-linux-gnu/libfprint-2.so.2.0.0` = `614e4194cf7e5723d2b1d9d4e8ac03c121e3647f89d32530b23358ba77251525` |
| fprintd / libpam-fprintd | Ubuntu noble 1.94.3 | — |
| TA gfenu | 从**你自己设备** Android 固件提取（9 文件，约 4.8 MB） | 见 `fingerprint/extract/README.md`（脚本自动校验） |
| 驱动源码 | `kernel/qseecom/`、`kernel/mdt_loader.c`、`kernel/qcom_scm.c`、`kernel/goodix_fp_spi/` | 编译验证 |

## 本版验证摘要（2026-11-21）

- release #18 干净启动：`Startup finished 21.9 s`（kernel 3.1 + userspace 18.8）；传感器栈、指纹 19 OK/1 WARN、
  GNSS、相机 23 OK 自检通过（个别启动会命中已知的传感器偶发问题，见 `docs/HARDWARE-STATUS.md`）。
- s2idle：0009 已合入；打补丁内核自 11-19 起共 20 次（含 10h47m / 5h50m 长睡）0 次 PDM/崩溃。
- 快充（0010+0012–0015）：PD 9V/PPS 充电器下，低电量（55–66%）电池侧 **~18–20W**（SMB5 单路 ~15W + bq2597x 双泵并联）；可选 `pps-charger/` 用 11V keep-alive 到 **~20.5W（+8%）**（50–56% 电量，41.5°C 回退）；
  高电量按分段曲线降档（90% 时约 1.5A→0.75A），**不再在 83% 提前报 Full**，可继续充到高电量；
  充电中电池温度 ≤40°C。11V/27W 档（bq2597x 泵）仍未接。
- pogo 键盘（2026-11-22）：`pogo/` 默认组件；唤醒后 +3s 脉冲 TLMM 141 复位键盘，实测手动 2 次恢复
  （Device 002→003、003→004）+ 3 轮 `systemctl suspend`/RTC 自动唤醒 hook 全部按 +3s 触发、无死机；
  每次唤醒键盘重枚举 ~1–1.5s。

## 数据/固件校验（安装后）

```bash
# 传感器
md5sum /usr/share/qcom-ssc-elish/slpi.mbn                         # 51c3b3bef20a76d386a516dfbcc72b68
find /usr/share/qcom-ssc-elish/sensors/registry -type f | wc -l   # 155
find /usr/share/qcom-ssc-elish/sensors/config -type f | wc -l     # 40
find /usr/share/qcom-ssc-elish/sensors/proto -type f | wc -l      # 79
find /usr/share/qcom-ssc-elish/socinfo -type f | wc -l            # 6
# 指纹
ls /lib/firmware/gfenu.* | wc -l                                  # 9
# 联合 DTB
./kernel/dtb/verify-combined-dtb.sh
```

## 已安装二进制对照（可选）

```bash
sha256sum /lib/modules/$(uname -r)/kernel/drivers/misc/fastrpc.ko \
          /lib/modules/$(uname -r)/extra/goodix_fp_spi.ko \
          /usr/libexec/iio-sensor-proxy \
          /usr/lib/aarch64-linux-gnu/libfprint-2.so.2.0.0 \
          /usr/sbin/qsee-supplicant /usr/sbin/qsee-app-loader
```
