# 指纹子包清单（MANIFEST）

## 包含

```
README.md / INSTALL.md / NOTES.md / MANIFEST.md
src/qsee-supplicant/      supplicant + app-loader 完整源码（0.1.1，无编译二进制、无 .git）
src/libfprint/            goodixqsee 驱动源码 + meson 选项 + 日志补丁（相对 430e24e5）
system/pam.d/             sudo（指纹优先栈，可选安装）、gdm-fingerprint（对照）
system/systemd/           qsee-supplicant.service、qsee-app-loader@.service（含 restart-limit /
                          retry-reclaim drop-in）、fp-ta-watchdog.service、fprintd drop-in、
                          用户会话 watcher unit
system/udev/60-goodix-qsee.rules
system/bin/               fp-sudo-prompt、fp-sudo-prompt-done、fp-ta-watchdog、qsee-app-loader-retry
system/user-bin/          fp-sudo-prompt-watch
extract/                  extract-gfenu-ta.sh + README（TA 提取与 sha256 校验）
install/                  install-fingerprint-files.sh、verify-fingerprint.sh、uninstall-fingerprint.sh
```

## 不包含（及原因）

| 内容 | 原因 | 获取方式 |
|---|---|---|
| `gfenu.*` TA 镜像（4.8MB 固件） | 厂商标名二进制、不适合再分发 | `extract/extract-gfenu-ta.sh` 从自己设备的 Android 固件提取 |
| `goodix_fp_spi.ko`、`libfprint-2.so.2.0.0`、DTB 二进制 | 编译产物，与内核 ABI/配置绑定 | 按 `../kernel/README.md` 与 `INSTALL.md` 编译 |
| `qsee-supplicant`/`qsee-app-loader` 二进制 | 编译产物 | `make` 生成（`src/qsee-supplicant`） |
| `logs/`（录入/验证/GDM 日志） | 本机运行记录 | — |
| `system/backup/`、`system/sudoers.d/020-nopasswd.disabled` | 含旧 PAM/NOPASSWD 安全配置，不应分发 | 回退请用你自己的备份；本包不提供免密 sudo |
| `src/tools/`（goodix-tools/harness/git 仓库） | 诊断参考实现，非安装必需 | 上游 `wrobelda/goodix-fp-spi-linux` @ `4663eb9` |
| `capture*`、`android-info-*`、`android-storage-fpdump`、`vendor-libs`、`ta-image*`、`libfprint.tar.gz` | 调研抓包/Android 私有数据/工作副本 | 归档外工作目录，不随包 |
| 指纹模板 `/var/lib/fprint/...` | 用户私有生物数据 | 本地 `fprintd-enroll` 生成 |

## 版本/来源

统一见合并包根 `../VERSIONS.md`（内核、libfprint、qsee-supplicant、fprintd 版本与安装后 sha256）；
内核构建链见 `../kernel/README.md` 与 `../kernel/ARMBIAN-BASELINE.md`。
子包特有：TA `gfenu` 从**自己设备**的 Android `/vendor/firmware_mnt/image/` 提取（9 文件），
sha256 校验表见 `extract/README.md`（TA 不随包）。
