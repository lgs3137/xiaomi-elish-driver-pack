# 版本与校验值（合并包 BOM）

> 本包不含编译产物/固件；下列 sha256/md5 用于安装后交叉核对。
> **本版基线：2026-11-21**（release 内核构建 #13 + 0009 睡眠修复 + 联合 DTB 含 Hi556）。
> 历史版本记录见 `docs/HISTORY.md`。

## 内核

| 项 | 值 |
|---|---|
| 运行内核 | `6.18.44-current-sm8250`（release 构建 `#13 SMP Sat Nov 21 10:38:33 CST 2026`，无诊断选项） |
| 基线源码 | Linux v6.18.44（tar.xz sha256 `0f72d938f06828e82c90405174fe572287db7bfe089e2fc46572a99a7f240d43`）+ Armbian sm8250 补丁（获取方式见 `kernel/ARMBIAN-BASELINE.md`） |
| 配置 | `kernel/config-used-6.18.44`，sha256 `5d102e999c3a6c63bc17f659361963b8`（TEE/QSEECOM/MDT/BTF/FASTRPC；LOCALVERSION=-current-sm8250） |
| 安装后 fastrpc.ko sha256 | `f5851cb19e78eea6ffad790605859f339f29d1de17b3f6aa12ae676181f05875`（含 0009） |
| 安装后 goodix_fp_spi.ko sha256 | `1862e80e303529ab9a1463d841591722a1fadd284e7feb58ef8459b1f386b041` |
| 传感器补丁 | `kernel/patches/0001-fastrpc-sdsp-vmid-and-sensors-pd.patch`（2 hunk） |
| LPASS pinctrl 补丁 | `kernel/patches/0002-pinctrl-lpass-lpi-defer-on-clock-timeout.patch`（1 hunk，独立问题） |
| 睡眠修复补丁 | `kernel/patches/0009-fastrpc-listener-unfreezable.patch`（fastrpc listener `PF_NOFREEZE`；s2idle 唤醒不再崩 sensor PD） |
| 内核集成 | `kernel/include/`（3 头文件）+ `kernel/INTEGRATION.md`；权威系列补丁 `kernel/patches/fingerprint/qseecom-tee-series.patch`（14 文件） |
| boot hook 参考 | `kernel/boot/zz-update-abl-kernel`（系统 hook 副本）；统一用 `kernel/update-boot-image.sh` |
| QCOM_MDT_LOADER Kconfig | `kernel/patches/0003-qcom-mdt-loader-user-selectable.patch` |
| boot 镜像更新 | `kernel/update-boot-image.sh`（预检+备份+回读校验） |
| 联合 DTB（随包） | `kernel/dtb/sm8250-xiaomi-elish-csot.dtb`，sha256 `0d639355650ad34ef3a03ed6af44f4fd2e1ec287aadd543a7c707238f8b544e8`（139,091 B；模型级，无本机私有信息；含相机/OV8856/OV13B10/Hi556、GNSS QUP5 UART + bcm4775 + PMIC GPS clock、指纹节点） |
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

- release #13 干净启动：`Startup finished 21.42 s`（kernel 3.16 + userspace 18.26）；传感器可用 20.92 s；
  PD registry 8.2 s；iio NRestarts=0。
- s2idle：打补丁内核自 11-19 起共 20 次（含 10h47m / 5h50m 长睡）0 次 PDM/崩溃；release #13 当日 4 次 0 崩溃。
- `install/check-all.sh`：DTB ✅、传感器 14 OK/0 FAIL、指纹 19 OK/1 WARN/0 FAIL、GNSS ✅、相机 23 OK/0 FAIL、
  闪光灯修复 ✅、initramfs ✅、apt hold ✅。

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
