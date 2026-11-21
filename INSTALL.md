# 合并安装文档（传感器 + 指纹 + GNSS + 相机/闪光灯，一次内核）

> 先读根 `README.md` 的红线与 `NOTES.md`。所有命令在设备本机 aarch64 执行，除注明外需要 root。
> 各子包完整细节：`sensors/INSTALL.md`、`fingerprint/INSTALL.md`、`gnss/INSTALL.md`、`kernel/README.md`。

## 一键安装（推荐）

**内核/DTB 是硬依赖**：传感器、指纹、GNSS、相机等驱动都依赖已打补丁的内核 + 联合 DTB。
一键器的 `--with-kernel` 是显式 opt-in（避免自动写 boot，且需自备同版本内核源码），
不是可跳过项；只有当你已运行本包的完整内核+DTB 时才可以跳过（脚本会预检 DTB 与模块）。

完整一键流程见 [`QUICKSTART.md`](QUICKSTART.md)（唯一权威）；下文是等价的手动分步安装，
便于排障、审计或自定义（如只装某一个子系统）。

一键安装现在还会：
- 从 `--android` 的 vendor 调校 bin 自动提取并生成相机 LSC/CCM（`--no-camera-tuning` 可关）；
- 可选 `--with-dtb [--write-boot]` 只安装包内单一联合 DTB（含 Hi556），无需重编内核。

> 默认组件还包括**后摄闪光灯开机误闪修复**（`flash-led/`，系统集成阶段自动安装）；
> **GNOME 手电筒**（`torch/`）是**可选**组件，默认不装：一键安装加 `--with-torch`，
> 或单独 `sudo ./torch/install.sh`（装好后注销/重新登录，控制中心出现「手电筒」开关）。

## 0. 安全前置与备份

1. **不要写 Android 启动槽**；只操作 rootfs 与 **Linux 启动槽**。槽位不写死：以
   `/boot/armbianEnv.txt` 的 `abl_boot_partition_label` 为准（本机 `boot_b`；别人的安装可能是 `boot_a`）。
2. 备份 Linux 启动槽 / boot 镜像 / DTB / PAM（一条命令，槽位自动检测）：
   ```bash
   sudo ./install/backup-boot.sh --pam
   ```
3. 备份传感器数据（若系统已有配置）：
   ```bash
   sudo tar -czf /root/sensor-data-backup-$(date +%Y%m%d).tar.gz /usr/share/qcom-ssc-elish 2>/dev/null || true
   ```
4. 临时禁用传感器：`sudo touch /etc/disable-sensors`（安装后生效，开机即跳过传感器链）。

## 1. 依赖（合并）

```bash
sudo apt update
sudo apt install -y build-essential gcc make git meson ninja-build pkg-config \
  libglib2.0-dev libgudev-1.0-dev libpolkit-gobject-1-dev libqmi-glib-dev libqrtr-glib-dev \
  libprotobuf-c-dev protobuf-c-compiler e2fsprogs \
  libgusb-dev libusb-1.0-0-dev libpixman-1-dev libcairo2-dev libgirepository1.0-dev \
  libssl-dev pahole dtc mkbootimg python3 fdtget gpsd gpsd-clients
# 若提取稀疏 Android 镜像： sudo apt install -y android-sdk-libsparse-utils
```

- 内核源码：与运行内核同版本（`6.18.44-current-sm8250`）的 Armbian sm8250 源码树（如 `/var/tmp/kbuild-src`）。
- BTF 编译需 ≥4GB swap。

## 2. 提取设备数据/固件（本包不附带）

> 完整清单与提取步骤见 **`docs/DEVICE-DATA-EXTRACTION.md`**（传感器/指纹/GNSS/相机 EEPROM/用户态二进制编译）。

### 2.1 传感器侧

| 数据 | 来源 | 脚本 |
|---|---|---|
| registry/config/socinfo | 已安装的 `armbian-firmware-full` 包 | `sensors/extract/extract-from-armbian-firmware.sh` |
| proto/hals/calibratedCheck/…（+ 可选 acdb） | 你自己的 Android vendor 镜像 `/etc/sensors`、`/etc/acdbdata` | `sensors/extract/extract-from-android-vendor-img.sh` |
| SLPI 单文件固件 `slpi.mbn` | pMOS `firmware-xiaomi-elish-slpi-*.apk` | `sensors/extract/extract-pmos-slpi-mbn.sh` |

```bash
cd sensors
./extract/extract-from-armbian-firmware.sh ./extracted/armbian
./extract/extract-from-android-vendor-img.sh /path/android-vendor.img ./extracted/android
./extract/extract-pmos-slpi-mbn.sh /path/firmware-xiaomi-elish-slpi-*.apk ./extracted/pmos
cd ..
```

（完整提取说明与校验见 `sensors/extract/README.md`。）

### 2.2 指纹侧（TA）

```bash
cd fingerprint
./extract/extract-gfenu-ta.sh --adb ./extracted/fingerprint-ta
# 或从 firmware_mnt.img： ./extract/extract-gfenu-ta.sh /path/firmware_mnt.img ./extracted/fingerprint-ta
cd ..
```

得到 9 个 `gfenu.*`（脚本会核对 sha256）。**不要用 `fingerpr.*`**。

## 3. 内核（一次构建；GNSS 复用同一 DTB + 独立模块）

**详细步骤与校验见 `kernel/README.md`**，摘要：

```bash
cd <内核源码树>   # 6.18.44 + Armbian sm8250 补丁（从零重建见 kernel/ARMBIAN-BASELINE.md）
# 指纹头文件 + drivers/tee 集成点（缺了会编译失败；详见 kernel/INTEGRATION.md）
cp <包>/kernel/include/linux/firmware/qcom/qcom_scm.h include/linux/firmware/qcom/qcom_scm.h
cp <包>/kernel/include/linux/soc/qcom/mdt_loader.h   include/linux/soc/qcom/mdt_loader.h
cp <包>/kernel/include/uapi/linux/tee.h              include/uapi/linux/tee.h
grep -q 'drivers/tee/qseecom/Kconfig' drivers/tee/Kconfig || printf '\nsource "drivers/tee/qseecom/Kconfig"\n' >> drivers/tee/Kconfig
grep -q 'CONFIG_TEE_QSEECOM' drivers/tee/Makefile || printf 'obj-$(CONFIG_TEE_QSEECOM) += qseecom/\n' >> drivers/tee/Makefile
# 指纹内核文件
cp -a <包>/kernel/qseecom drivers/tee/qseecom
cp -a <包>/kernel/mdt_loader.c drivers/soc/qcom/mdt_loader.c
cp -a <包>/kernel/qcom_scm.c drivers/firmware/qcom/qcom_scm.c
# 内核补丁：0001 fastrpc（传感器）、0002 LPASS pinctrl、0004 SMB5 充电、
#           0005–0008 相机、0009 睡眠修复（清单与说明见 kernel/README.md、PATCHES.md）
for p in 0001-fastrpc-sdsp-vmid-and-sensors-pd 0002-pinctrl-lpass-lpi-defer-on-clock-timeout \
         0004-smb5-typec-legacy-reset-resume 0005-ov8856-bggr-vflip 0006-ov13b10-of-supplies-reset \
         0007-cn3927v 0008-hi556-of 0009-fastrpc-listener-unfreezable; do
  patch -p1 < <包>/kernel/patches/$p.patch
done
# 配置 + 恢复 q6v5_pas auto_boot=true + 编译
cp <包>/kernel/config-used-6.18.44 .config
make ARCH=arm64 olddefconfig
# （按 kernel/README.md 检查 q6v5_pas auto_boot、配置项、ABI 三件套）
make ARCH=arm64 -j$(nproc) Image modules
```

> GNSS 不引入内核源码补丁：只需要 DTB 里的 QUP5 UART + `/bcm4775` 节点（本包 DTB 已含），
> 以及独立模块 `airoha_gps.ko`（`gnss/kernel/`，编译见 `gnss/INSTALL.md` 第 0 节）。

安装模块：

```bash
sudo cp drivers/misc/fastrpc.ko /lib/modules/$(uname -r)/kernel/drivers/misc/fastrpc.ko
cd <包>/kernel/goodix_fp_spi && make -C <内核源码树> M=$PWD ARCH=arm64 modules
sudo install -D -m 0644 goodix_fp_spi.ko /lib/modules/$(uname -r)/extra/goodix_fp_spi.ko
echo goodix_fp_spi | sudo tee /etc/modules-load.d/goodix-fp.conf
sudo depmod -a
# 若改动/重建了 initramfs 内模块（含 pinctrl-lpass-lpi），先更新 initramfs 再重建 boot 镜像：
sudo update-initramfs -u -k $(uname -r)
```

**联合 DTB**：直接使用包内已验证 DTB（不要用当前树 DTS 重建，会丢节点/属性）：

```bash
sudo cp kernel/dtb/sm8250-xiaomi-elish-csot.dtb \
  /usr/lib/linux-image-$(uname -r)/qcom/sm8250-xiaomi-elish-csot.dtb
sudo mkdir -p /boot/dtb-$(uname -r)/qcom
sudo cp kernel/dtb/sm8250-xiaomi-elish-csot.dtb \
  /boot/dtb-$(uname -r)/qcom/sm8250-xiaomi-elish-csot.dtb
./kernel/dtb/verify-combined-dtb.sh /usr/lib/linux-image-$(uname -r)/qcom/sm8250-xiaomi-elish-csot.dtb
```

**initramfs 修复 hook（必须先做）**：原 Armbian hook 会把 slpi 符号链接解析成真固件打进 initramfs：

```bash
sudo ./kernel/initramfs/install-hook.sh    # 安装修复版 hook + update-initramfs
# 验证无输出：lsinitramfs /boot/initrd.img-$(uname -r) | grep slpi
```

**重建 boot 镜像并写入 Linux 启动槽**（推荐系统 hook，使用新 initrd；槽位自动检测）：

```bash
sudo ./install/backup-boot.sh         # 已备份过可跳过
sudo /etc/kernel/postinst.d/zz-update-abl-kernel
```

`kernel/install-new-kernel.sh` 是历史脚本（复用旧 ramdisk、不使用更新后的 initrd），initramfs 更新后不要用；
统一用 `kernel/update-boot-image.sh`（详见 `kernel/README.md`）。

## 4. 重启并验证内核层

```bash
sudo reboot
# 传感器内核
dmesg -k | grep -E 'SDSP assign|remoteproc2.*slpi|Direct firmware load'
ls -l /dev/fastrpc-sdsp
# 指纹内核
dmesg -k | grep -i qseecom
ls -l /dev/tee0 /dev/teepriv0 /dev/goodix_fp
cat /sys/devices/platform/fingerprint/firmware_name    # 需先放 TA，见下
# GNSS 内核
ls /proc/device-tree/bcm4775
ls -l /dev/ttyHS1 /dev/airoha_gps
kernel/dtb/verify-combined-dtb.sh
```

## 5. 传感器用户态

```bash
cd sensors
# 按 sensors/INSTALL.md 第 2–5 步：
#   组装数据：sudo ./install/install-data.sh --android ./extracted/android --armbian ./extracted/armbian --firmware ./extracted/pmos
#   安装系统文件：sudo ./install/install-system-files.sh
#   重启后： ./install/verify.sh
cd ..
```

传感器开机链路约 **21 秒**（2026-11-21 实测；改造前 ~79s）；`sensor-status` 可随时诊断。延迟参数在 `/etc/sensor-tuning.conf`（默认 0/8）。

## 6. 指纹用户态

```bash
# TA
sudo cp fingerprint/extracted/fingerprint-ta/gfenu.* /lib/firmware/ && sudo chmod 0644 /lib/firmware/gfenu.*
# qsee-supplicant
cd fingerprint/src/qsee-supplicant && make && sudo make install-bin install-systemd install-doc
sudo systemctl daemon-reload && sudo systemctl enable --now qsee-supplicant.service
# libfprint（按 fingerprint/INSTALL.md 第 5 节：clone wrobelda/libfprint goodix-qsee @430e24e5 + 补丁 + meson）
# fprintd + drop-in + udev + 脚本
cd ..
sudo ./fingerprint/install/install-fingerprint-files.sh
# 可选：sudo ./fingerprint/install/install-fingerprint-files.sh --pam --user（sudo 指纹/弹窗；先确保能回退密码）
```

逐项验证：`sudo ./fingerprint/install/verify-fingerprint.sh $USER`；录入/验证见 `fingerprint/INSTALL.md`。

## 6b. GNSS 用户态

```bash
cd gnss
# 0) 编译安装 airoha_gps.ko（与运行内核同版本源码树；详见 gnss/kernel/README.md）
# 1) 安装 airoha-gnssd + systemd + gpsd 配置
sudo ./install/install.sh
# 2) 验证
sudo ./install/verify.sh
gpspipe -w -n 5        # 室内无星 mode=1 正常；室外应出现 mode:2/3 与经纬度
```

- DTB/内核模块前提见 `gnss/INSTALL.md`；**不要重刷 GNSS flash**。
- 详细协议/排障：`gnss/README.md`、`gnss/NOTES.md`。
- 与传感器（含罗盘）可同时使用：GNSS 走 QUP5 UART，传感器走 SLPI，互不冲突。
- `install.sh` 会同时安装 `gps-nmea-share` 并配置 GeoClue2（`/run/gps-share.sock`），
  GNOME Maps 等标准地图应用可直接通过 GeoClue 取位置（指南针 heading 见 `gnss/NOTES.md`）。

## 6c. bioauth 生物认证 PAM（可选，默认不装）

bioauth 是通用 PAM 生物认证栈（PAM module + root daemon + 单窗口 GTK4 全屏 UI），复用本包
的 fprintd 指纹后端。**合并包默认不安装、不改 PAM**；需要时显式启用：

```bash
# 只装文件与测试服务（sudo/pkexec 保持原样）
sudo ./install.sh --no-deps --skip-extract --skip-build --with-bioauth --yes
# 接入 sudo（PAM_IGNORE 时回落到密码；会备份 /etc/pam.d/sudo）
sudo ./install.sh --no-deps --skip-extract --skip-build --bioauth-sudo --yes
# 接入 pkexec/polkit（取消时回落到 GNOME 密码框；会备份 /etc/pam.d/polkit-1）
sudo ./install.sh --no-deps --skip-extract --skip-build --bioauth-pkexec --yes

# 验证 / 回滚 / 卸载
bioauth-doctor
sudo ./bioauth/scripts/install-bioauth.sh --rollback
sudo ./bioauth/scripts/install-bioauth.sh --uninstall
```
不要与旧指纹栈的 `--pam` 同时启用；完整安全说明见 `bioauth/INSTALL.md`。

## 6d. 后摄闪光灯开机误闪修复（默认组件）

每次开机 Plymouth 启动画面阶段后摄闪光灯会闪一下：Armbian 的
`armbian-led-state-restore.sh` 对 `trigger=none` 的 workaround 会经 `default-on`
把 flash 类 LED（`white:flash`）以最大手电电流点亮一瞬。本组件用 wrapper 过滤
`/etc/armbian-leds.conf` 中 flash 类 LED 的 stanza 后调用原脚本，并用 systemd drop-in
指向 wrapper；**不修改 Armbian 包文件**，BSP/apt 升级不会还原。

```bash
sudo ./flash-led/install.sh     # 默认组件（turnkey 已自动装）
./flash-led/verify.sh           # 静态 + 离线过滤自检（--live 额外重启服务抓 udev 事件）
sudo ./flash-led/uninstall.sh   # 回滚（回滚后开机又会闪，属 Armbian 原版行为）
```
根因/证据/升级注意见 `flash-led/README.md`。

## 6e. GNOME 手电筒（可选，默认不装）

在 GNOME 46 控制中心（右上角 / `Super+S`）增加「手电筒」开关，并提供 `torch` CLI；
走 logind `Session.SetBrightness("leds","white:flash",N)`，普通用户可用、无需 root/udev。

```bash
sudo ./torch/install.sh         # 装扩展 + CLI，并在用户 dconf 启用（旧会话不热加载）
torch / torch off / torch set 64
sudo ./torch/verify.sh          # 未安装则 SKIP
sudo ./torch/uninstall.sh
```
装好后需**注销/重新登录**才会出现在控制中心；拍照闪光（`flash_strobe`）仍不支持。

## 6f. 平板模式开关（可选，默认不装）

没有磁吸保护套（或霍尔失效）时，用控制中心开关在「自动 / 开 / 关」之间切换平板模式：
`on` = 总是平板模式（自动旋转开），`off` = 总是笔记本模式（自动旋转关），
`auto` = 跟随保护套霍尔。实现为 uinput 虚拟 `SW_TABLET_MODE` + GNOME 46 Quick Settings 扩展。

```bash
sudo ./tablet-mode/install.sh      # 编译 helper + systemd 服务 + 用户扩展（可 --dry-run）
sudo ./tablet-mode/verify.sh       # 未安装则 SKIP
sudo ./tablet-mode/uninstall.sh
```
装好后需**注销/重新登录**才出现控制中心开关；命令行等价：
`elish-camera-ctl orientation tablet auto|on|off`。详见 `tablet-mode/README.md`。

## 6g. PPS 快充服务（可选，默认不装；装后启用）

插上支持 PPS 的 PD 充电器后，自动把契约从 9V/3A 切到 **11V PPS keep-alive**（每 8 秒重发请求，
对付充电头的 ~13s PPS 看门狗），并按电池温度分档限流；温度 ≥41.5°C 或电量 ≥90% 回退 9V 固定档。

```bash
sudo ./pps-charger/install.sh      # 安装并启用（systemctl enable --now）
sudo ./pps-charger/verify.sh       # 未安装则 SKIP
journalctl -u elish-pps-charger -f
sudo ./pps-charger/uninstall.sh    # 卸载并回退 9V
```
实测：50–56% 电量电池侧 ~20.5W（固定 9V 约 18.9W）；短测 11V/4A 可到 23.5W+。
详见 `pps-charger/README.md`。

## 7. 合并自检

```bash
./install/check-all.sh
```

包含：联合 DTB、传感器 `sensors/install/verify.sh`、GNSS `gnss/install/verify.sh`、指纹 `fingerprint/install/verify-fingerprint.sh`、
相机 `camera/elish-camera/verify.sh`、闪光灯修复 `flash-led/verify.sh`、可选手电筒 `torch/verify.sh`、可选平板模式开关 `tablet-mode/verify.sh`、可选 PPS 快充 `pps-charger/verify.sh`（未装则 SKIP）。

## 8. 日常 / 禁用 / 回滚

- 传感器禁用：`sudo touch /etc/disable-sensors && sudo reboot`；恢复删掉该文件。
- 指纹服务：`systemctl status qsee-supplicant qsee-app-loader@gfenu fprintd fp-ta-watchdog`；
  TA 拒服务：`sudo systemctl restart qsee-app-loader@gfenu`。
- 指纹禁用：`sudo ./fingerprint/install/uninstall-fingerprint.sh`（保留模块/TA/libfprint）。
- 传感器卸载：`cd sensors && sudo ./install/uninstall.sh [--purge-data]`。
- GNSS 卸载：`cd gnss && sudo ./install/uninstall.sh`（保留内核模块；GNSS flash 不动）。
- 闪光灯修复回滚：`sudo ./flash-led/uninstall.sh`（回滚后下次开机又会闪，属 Armbian 原版行为）。
- 手电筒（可选）卸载：`sudo ./torch/uninstall.sh`（移除扩展/CLI/启用项；下次登录后图标消失）。
- 平板模式开关（可选）卸载：`sudo ./tablet-mode/uninstall.sh`（移除 helper/服务/扩展；`auto` 行为仍由内核霍尔提供）。
- PPS 快充服务（可选）卸载：`sudo ./pps-charger/uninstall.sh`（停服务并回退 9V 固定档）。
- 内核回退：`LABEL=$(sed -n "s/^abl_boot_partition_label=//p" /boot/armbianEnv.txt); sudo dd if=/root/${LABEL}-backup-*.img of=/dev/disk/by-partlabel/$LABEL`（旧备份名可能是 `boot_b-backup-*`）。
- 升级影响：**先读 `docs/UPGRADE-IMPACT-ALL.md`**（内核/固件升级会同时破坏传感器/指纹/GNSS）。

## 9. 升级/重建提示

- 内核/DTB/boot 重建后，传感器/指纹/GNSS 都依赖它；重做后先跑 `kernel/dtb/verify-combined-dtb.sh`。
- `armbian-firmware-full` 升级会把传感器固件符号链接换回普通文件（启动脚本会自愈，但建议升级后
  立即检查并恢复；指纹不受影响）。
- `libfprint-2-2` 升级会覆盖自编译库 → 指纹消失；重编安装即可。
- GNSS：内核/DTB 升级会覆盖 QUP5 UART/`bcm4775` 节点，需用本包 DTB 重建；`airoha_gps.ko` 需重编；
  `airoha-gnssd`/gpsd 为用户态，不受内核升级影响。
- 闪光灯修复：wrapper 在 `/usr/local`、drop-in 在 `/etc/systemd`，不属于 Armbian 包，
  `armbian-bsp-cli-*`/内核升级不会覆盖；若上游 restore 脚本接口变化，重跑 `sudo ./flash-led/install.sh`。
- GNOME 手电筒扩展：`metadata.json` 只声明 `shell-version: ["46"]`；GNOME Shell 大版本升级后需
  修改并重装（`sudo ./torch/install.sh`）。
- 细节见 `docs/UPGRADE-IMPACT-ALL.md` 与 `sensors/docs/UPGRADE-IMPACT.md`。
