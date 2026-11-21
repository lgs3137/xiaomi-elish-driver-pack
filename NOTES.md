# 合并包注意事项（传感器 + 指纹 + GNSS + 相机共同必读）

> 子包细节：`sensors/NOTES.md`、`fingerprint/NOTES.md`、`gnss/NOTES.md`。
> 升级影响：`docs/UPGRADE-IMPACT-ALL.md`。
> **硬件驱动状态以 `docs/HARDWARE-STATUS.md` 为权威基线**（2026-11-21：传感器/指纹/GNSS/相机/闪光灯均已打通；
> s2idle 睡眠死机已由 0009 修复；剩余限制见该文件）。

## 0. 红线

1. **boot_a 是 Android 启动分区，绝对不要写**。只操作 rootfs 和 Linux 启动槽（按 armbianEnv 自动检测）。
2. 改内核/启动镜像/DTB 前必须备份 Linux 启动槽、`/boot/armbian-kernel-csot.img`、DTB
   （`install/backup-boot.sh` 或 `kernel/update-boot-image.sh` 会自动备份）。
3. **不要用 `dtc` 反编译-重编译改 DTB**：会破坏 `regulators-1/ldo10`（L10C 3.3V）的 4 字节调压属性；
   L10A 是 `regulators-0/ldo10`（3.008V，指纹供电），不在该问题范围。改 DTB 请用等长二进制替换或完整源码重编。
4. **不要用当前 `/var/tmp/kbuild-src` 的 DTS 重建 DTB**：该树不完整（会丢 17 节点/109 属性）；
   直接用包内已验证 DTB（`kernel/dtb/`）。
5. 不要用 edge 内核；不要关 `CONFIG_DEBUG_INFO_BTF`；不要改 `CONFIG_LOCALVERSION`；
   不要用实验性的 `qcom_q6v5_pas auto_boot=false`（必须 upstream `true`）。
6. 指纹 PAM 改动前确保还有密码/TTY 登录通道；**不要重新启用 NOPASSWD sudo**。
7. 不要用 `fingerpr` TA（错误），必须 `gfenu`。
8. 本机若存在 `/etc/sudoers.d/*nopasswd*`，sudo 指纹会被绕过；要真正启用指纹 sudo，请先停用 NOPASSWD（本包不附带该文件）。
9. **GNSS：不要为了定位重刷 GNSS flash**。芯片从 flash 自行启动；串口必须 **921600**，
   上电后 **~1 秒内**必须发 `$PAIR002`。刷写流程仅用于修复 flash（风险高，见 `gnss/extract/README.md`）。
10. **不要尝试用户态复位 pogo 键盘 USB**（`authorized` 0→1 / `USBDEVFS_RESET` / 重绑控制器）：
    曾触发 `qcom_snps_hsphy_exit` 死锁、USB 瘫痪；唤醒后键盘失效请重启或物理重插。

## 1. 统一内核/DTB/boot 是各功能的共同基础

- 内核需同时满足：传感器 fastrpc 两处补丁（SDSP VMID `{3,5}` + sensors-PD remote heap）与
  `0009` listener `PF_NOFREEZE`；指纹 QSEECOM/mdt_loader(ELF64)/qcom_scm + goodix_fp_spi；
  GNSS 的 `airoha_gps.ko`（独立模块，不涉及内核源码补丁）；相机 sensor 驱动补丁（0005–0008）。
- 联合 DTB 需同时含：SLPI fastrpc 节点 `qcom,vmids=<3 15 5 6>` + fastrpc reserved-memory；
  根 `/fingerprint` 节点（`goodix,gf3626`、`firmware-name="gfenu"`、GPIO 23/125、L10A）；
  GNSS QUP5 UART（`i2c@994000` → `qcom,geni-uart`）与根 `/bcm4775`；
  相机 OV8856/OV13B10/CN3927V/Hi556 节点。
- 一次构建、一次写 Linux 启动槽（自动检测）。校验：`kernel/dtb/verify-combined-dtb.sh`。
- **内核升级会覆盖全部改动**（模块、DTB、boot 镜像），传感器/指纹/GNSS/相机会同时失效；详见升级文档。
- `zz-update-abl-kernel` 会用**包内 DTB**（不是你的修改版）重建 Linux 槽；内核升级后必须手动重做联合 DTB。

## 2. 传感器核心不变量

- `/lib/firmware/qcom/sm8250/xiaomi/elish/slpi.mbn` 必须是**悬空符号链接** →
  `/run/sensor-fw/slpi.mbn`（`/run` 是 tmpfs，开机清空）。若变成普通文件，内核 boot+5s 会抢先
  auto_boot SLPI → 监听器来不及 → PD 看门狗崩溃 → 本次开机传感器永久失效。
- `slpi-fw-guard.service` 必须启用；`armbian-firmware-full` 升级后立即检查/恢复该链接。
- `PRE_DELAY=0`、`IIO_DELAY=8`（开机传感器 ~21 s 可用）；异常时可回退 10/45。
- iio 由 `slpi-sensors-start.sh` 在 `IIO_DELAY` 后拉起；补丁版 iio 常驻等待热插
  （日志 `staying alive ... (patched)`），已无旧的 warm-restart 兜底。
- 偶发 PD 静默卡死（约 1/14 干净开机）：干净重启恢复；同 boot 内重启服务无效。
- suspend/resume 后 PD 崩溃：**已由 `kernel/patches/0009` 修复**（fastrpc listener `PF_NOFREEZE`）；
  打补丁内核 20 次 s2idle（含 10h+）0 崩溃。

## 3. 指纹核心坑

- **ABI 三件套**：vermagic=`6.18.44-current-sm8250 SMP mod_unload aarch64`、
  `pahole -C module vmlinux` size=1280、BTF 两项 =y；不一致会黑屏只剩背光。
- **CMA**：加载 TA 约需 9MB 连续 CMA；不要并发/反复加载；ENOMEM 时重启或重启 loader。
- **TA 拒服务（1062 / scm -22）**：`sudo systemctl restart qsee-app-loader@gfenu`；
  watchdog 自动处理；不要并发 verify。
- **libfprint 被 apt 覆盖**：升级 `libfprint-2-2` 后重编安装；否则指纹设备消失（建议 hold）。
- **fprintd 沙箱**：保留 `/etc/systemd/system/fprintd.service.d/60-goodix-qsee.conf`。
- **PAM**：`success=done`（不是 end）；触发文件在 `/run/user/<uid>`；弹窗只能由用户会话 watcher 做；
  zenity 要 `--no-markup`；`sudo -v` 不建 session（弹窗靠 12s 超时）。
- 指纹模板在 `/var/lib/fprint/...`，用户私有，不要复制/进包。

## 4. 数据与固件（本包不附带）

| 内容 | 获取方式 |
|---|---|
| SLPI 单文件固件 + sensors registry/config/socinfo + vendor proto/hals/acdb | 见 `sensors/extract/README.md` |
| 指纹 TA `gfenu.*`（9 文件） | 见 `fingerprint/extract/README.md`（从自己设备 Android 固件提取） |
| 内核 Armbian 基线 | 不随包；获取方式见 `kernel/ARMBIAN-BASELINE.md` |
| libfprint / qsee-supplicant 源码 | 随包；libfprint 上游分支+补丁说明见 `fingerprint/src/libfprint/` |

## 5. 升级/回滚速查

| 场景 | 操作 |
|---|---|
| 内核升级 | 重做统一内核 + 联合 DTB + boot 镜像；备份 Linux 启动槽；参考 `kernel/README.md` |
| `armbian-firmware-full` 升级 | 检查/恢复 SLPI 符号链接（或让启动脚本自愈后重启一次） |
| `libfprint-2-2` 升级 | 重编安装 libfprint + `ldconfig` + 重启 fprintd |
| 指纹 PAM 出问题 | 恢复 `/root/fp-pam-backup-*/sudo`；确保有密码登录 |
| 传感器长期不稳 | `sudo touch /etc/disable-sensors` 保系统正常，再排查 |
| 完全卸载 | `sensors/install/uninstall.sh --purge-data` + `fingerprint/install/uninstall-fingerprint.sh` |

## 6. 日志/诊断

```bash
# 传感器
sensor-status
sudo journalctl -b -u slpi-sensors -u iio-sensor-proxy --no-pager
sudo tail -50 /var/log/hexrpc-boot.log
# 睡眠/唤醒
journalctl -k -b --no-pager | grep -E 'PM: suspend|unfreezable'
journalctl -t elish-sensors-resume -b --no-pager
# 指纹
sudo dmesg | grep -iE 'qseecom|goodix|loaded .gfenu'
journalctl -b -u qsee-supplicant -u fprintd -u fp-ta-watchdog --no-pager
fprintd-list "$USER"
cat /sys/devices/platform/fingerprint/firmware_name
# 合并自检
./install/check-all.sh
```
