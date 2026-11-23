# 指纹子包：Goodix GF3626ZS1（Xiaomi Mi Pad 5 Pro / elish / SM8250）

在 Armbian Linux（kernel `6.18.44-current-sm8250`）上启用侧边电容指纹：
**录入、验证、GDM 锁屏/登录解锁、sudo 指纹认证、TA 拒服务自动恢复**（均已实测）。

> 文档基线：2026-11-21。自检复核 **OK=19 / WARN=1 / FAIL=0**（`install/verify-fingerprint.sh`；
> WARN 为旧 `--pam` sudo 指纹栈未启用，当前 sudo 认证走 bioauth）；
> 功能实测与 ABI 校验基准见 `../VERSIONS.md`。历史项目记录见 `../docs/HISTORY.md`。

本子包是合并安装包的一部分：内核/DTB/boot 镜像与传感器项目**共用一次构建**，见 `../kernel/README.md`。
本包只含源码、补丁、系统配置与脚本；**不含 TA 固件、编译产物、日志、指纹模板、PAM/sudoers 备份**。

## 已验证功能

| 功能 | 状态 |
|---|---|
| `fprintd-enroll` 录入 | ✅ |
| `fprintd-verify` 验证（verify-match） | ✅ |
| GDM 锁屏/登录指纹图标与解锁 | ✅ |
| sudo 指纹（弹窗提示、8s 超时回退密码） | ✅ |
| TA "拒服务" 自动恢复（看门狗/resume 钩子重载 loader） | ✅（CMA 严重碎片时需重启） |
| 安装自检 `install/verify-fingerprint.sh` | ✅ OK=19 / WARN=1 / FAIL=0（2026-11-21 复核；WARN=旧 `--pam` 栈未启用） |

## 硬件与版本

| 项 | 值 |
|---|---|
| 芯片 | Goodix GF3626ZS1（侧边电容，SPI 由 TEE 安全世界控制） |
| GPIO | IRQ 23（高有效）、Reset 125（低有效） |
| 供电 | PM8150A LDO10（L10A）@ 3.008 V |
| TA | `gfenu`（9 个文件，约 4.8MB，ELF32，从**你自己的设备**提取，见 `extract/`） |
| qsee-supplicant | 0.1.1（含 qsee-app-loader） |
| libfprint | 1.94.100，`wrobelda/libfprint` 分支 `goodix-qsee` commit `430e24e5` + 日志补丁 |
| fprintd / libpam-fprintd | 1.94.3（Ubuntu noble） |
| 内核 | 6.18.44-current-sm8250 + QSEECOM/mdt_loader/qcom_scm/goodix 驱动（本包 `../kernel/`） |

## 架构

```
fprintd（D-Bus）
  └─ libfprint（goodixqsee）── /dev/goodix_fp + /dev/teeN ──> gfenu TA
qsee-supplicant（listener 10 FS / 28672 GPFS，文件服务）
qsee-app-loader@<TA>（udev 自动拉起，特权加载 TA 并保持会话）
fp-sudo-prompt(-done) + 用户会话 watcher（sudo 弹窗）
fp-ta-watchdog（日志检测 TA 拒服务 → 重启 loader）
内核：drivers/tee/qseecom（/dev/tee0、/dev/teepriv0）、qcom_scm QSEECOM、mdt_loader ELF64、
      goodix_fp_spi.ko（/dev/goodix_fp：L10A/复位/IRQ/netlink）
```

## 唤醒后 TA 自动恢复（2026-11-23）

s2idle 后 fprintd 可能报 `Goodix QSEE bring-up command 1005 failed ... status 1001`；
原因是 TA 会话失效，需要重载 `qsee-app-loader@gfenu`。但 TA 需要约 **9 MiB 连续 CMA**，
长时间运行后 CMA 碎片化/不可迁移页会导致 `__cma_alloc: ... ret: -16`（EBUSY），
此时 `CmaFree` 仍有 50–100 MB 也不够；严重时只能重启清 CMA。

已安装：
- `/usr/lib/systemd/system-sleep/70-goodix-fp-resume.sh`：唤醒后延迟调用 helper；
- `/usr/local/sbin/fp-resume-reset`：先 `fprintd-verify` 探测，**健康则不动 TA**；
  失败才 stop loader → 外部 drop caches/compact → reload；避免每次唤醒都重启；
- `qsee-app-loader@.service.d/60-retry-reclaim.conf`：`ProtectKernelTunables=no`，
  允许 retry wrapper 在 CMA 压力下 reclaim；
- 日志 `/var/log/fp-resume.log`；手动等价：`sudo /usr/local/sbin/fp-resume-reset`。

本机 2026-11-23 一次严重 CMA 碎片（`req-size 2244 pages, ret -16`）仍只能重启恢复；
resume 钩子用于避免“每次唤醒都坏”。

## 目录

```
README.md / INSTALL.md / NOTES.md / MANIFEST.md
src/qsee-supplicant/      supplicant + app-loader 源码（0.1.1，无二进制）
src/libfprint/            goodixqsee 驱动 + 日志补丁（相对上游 430e24e5）
system/                   pam.d、systemd、udev、bin、user-bin（安装到系统）
extract/                  gfenu TA 提取脚本与校验表（TA 不随包）
install/                  安装/自检/卸载脚本
```

## 安装顺序（详见 `INSTALL.md`）

1. 先按 `../kernel/README.md` 构建**统一内核**（两项目共用；含联合 DTB 与 boot 镜像）；
2. `extract/extract-gfenu-ta.sh --adb` 从自己的设备提取 `gfenu.*`，放入 `/lib/firmware/`；
3. 编译安装 `src/qsee-supplicant`；
4. 编译安装 libfprint（上游分支 + 补丁）；
5. 安装系统集成：`sudo install/install-fingerprint-files.sh`（可选 `--pam`、`--user`）；
6. 重启后 `install/verify-fingerprint.sh`。

## 红线

- 改内核/启动镜像前必须备份 Linux 启动槽（本机 `boot_b`，按 `/boot/armbianEnv.txt` 的 `abl_boot_partition_label`）和 DTB；**不要用 `dtc` 反编译重编译改 DTB**（会破坏 L10A 调压属性）。
- 不要启用 `edge` 内核；不要关闭 `CONFIG_DEBUG_INFO_BTF`；不要改 `CONFIG_LOCALVERSION`。
- **不要重新启用 NOPASSWD sudo**（本包不附带 `/etc/sudoers.d/020-nopasswd*`）；PAM 改动前确保能用密码/TTY 登录。
- 不要用 `fingerpr` TA（错误的 FPC/旧方案镜像），必须用 `gfenu`。
- 指纹模板（`/var/lib/fprint/...`）是用户私有数据，**不要在机器之间复制**。

## 验收

```bash
systemctl is-active qsee-supplicant 'qsee-app-loader@gfenu' fprintd fp-ta-watchdog
cat /sys/devices/platform/fingerprint/firmware_name   # gfenu
./install/verify-fingerprint.sh "$USER"               # 期望 OK=19 WARN≤1 FAIL=0
fprintd-list "$USER"                                  # 至少一个手指
fprintd-verify "$USER"                                # 按压 → verify-match
sudo true                                             # 弹窗 → 按指纹（或 8s 后回退密码）
```

故障排查见 `INSTALL.md` 与 `NOTES.md`；历史调研/交接文档已移出包（工作区历史归档，不在包内）。
