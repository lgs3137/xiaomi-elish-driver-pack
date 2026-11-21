# 安装 / 自动化脚本说明（合并包）

> 适用包版本 **2026.11.21**。完整流程与前置条件以 [`../QUICKSTART.md`](../QUICKSTART.md)
> 与 [`../INSTALL.md`](../INSTALL.md) 为准；本文件只列脚本入口、分步顺序与回滚要点。

## 一键安装

`./install.sh` = `install/turnkey.sh` 的包装，按顺序自动完成：

apt 依赖（`--no-deps` 跳过）→ 设备数据/固件提取 → 数据母本（含固件路径不变量）→
用户态补丁+编译 → 系统集成 →（可选内核）→ 自检。

- 常用参数：`--dry-run`、`--yes`、`--skip-*`；
- 常用开关：`--no-fingerprint`、`--no-gnss`、`--no-camera`、`--no-camera-tuning`、
  `--with-dtb`、`--with-torch`（可选 GNOME 手电筒，默认不装）、
  `--android <vendor.img|dir>`、`--pmos <apk|dir>`；
- 默认组件还包括后摄闪光灯“开机闪一下”修复（`flash-led/`，系统集成阶段自动安装）；
- 安装完成后跑合并自检：`sudo ./install/check-all.sh`。

## 分步脚本

| 脚本 | 作用 |
|---|---|
| `install/turnkey.sh` | 全流程编排（`install.sh` 调用它） |
| `install/extract-all.sh` | 设备数据/固件提取（本包不附带这些文件） |
| `install/build-userspace.sh` | 打补丁 + 编译 + 安装用户态组件（源码缓存在 `/var/tmp/elish-build`） |
| `install/check-all.sh` | 合并自检（内核/传感器/GNSS/指纹/相机/apt 状态） |
| `install/backup-boot.sh` | 备份 Linux 启动槽 / boot 镜像 / DTB（`--pam` 另备份 `/etc/pam.d/sudo`） |
| `sensors/install/install-data.sh` | 组装 `/usr/share/qcom-ssc-elish` + 固件符号链接不变量 |
| `sensors/install/install-system-files.sh` | 传感器 systemd/udev/D-Bus/脚本/调参 |
| `fingerprint/install/install-fingerprint-files.sh` | 指纹 udev/systemd/脚本（`--pam --user` 可选） |
| `gnss/install/install.sh` | GNSS 守护进程 + gpsd/GeoClue 集成 |
| `camera/install.sh` | 相机后端/脚本/udev/虚拟相机/自启/休眠唤醒恢复（`--tuning-bins <dir>` 可选） |
| `flash-led/install.sh` | 后摄闪光灯开机误闪修复（默认组件；Armbian LED 状态恢复守卫） |
| `torch/install.sh` | 可选 GNOME 46 手电筒（控制中心开关 + `torch` CLI；默认不装） |
| `kernel/build-and-install.sh` | 内核补丁/配置/编译/模块/DTB/initramfs/Linux 启动槽（自动检测；自动备份） |

各脚本都支持 `--help` 与 `--dry-run`；除特别说明外需 `sudo`。

## 回滚要点

- **内核 / boot / DTB**：升级前先用 `install/backup-boot.sh` 备份；回滚时把备份镜像写回
  Linux 启动槽（脚本结束会打印 `dd` 命令；槽位标签按 `/boot/armbianEnv.txt` 自动检测）。
- **单组件卸载**：`flash-led/uninstall.sh`、`torch/uninstall.sh`、`sensors/install/uninstall.sh`
  （`--purge-data` 连数据母本一起删）、`gnss/install/uninstall.sh`（保留内核模块，不碰 GNSS flash）、
  `fingerprint/install/uninstall-fingerprint.sh`（保留模块/TA/libfprint）。
- **传感器临时禁用**：`sudo touch /etc/disable-sensors && sudo reboot`，恢复删掉该文件。
- **bioauth（可选）**：`sudo bioauth/scripts/install-bioauth.sh --rollback`（PAM 备份在
  `/root/bioauth-sudo-backup-*`）；改 PAM 前确保仍有密码/TTY 通道。
- 其余（apt hold 项、固件覆盖、内核升级影响）见 [`../INSTALL.md`](../INSTALL.md) §8 与
  [`../docs/UPGRADE-IMPACT-ALL.md`](../docs/UPGRADE-IMPACT-ALL.md)。

## 仍需手动

见 [`../QUICKSTART.md`](../QUICKSTART.md)「仍需手动的事」与 `../INSTALL.md` 分步说明。
