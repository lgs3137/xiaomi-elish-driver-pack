# 注意事项与已知问题（务必阅读）

## 0. 三条红线

1. **不要写 Android 启动槽。** 不要改 Android 侧任何分区/镜像。（本机 Android 在 `boot_a`、Linux 在 `boot_b`；
   若你的 Linux 在别的槽，以 `/boot/armbianEnv.txt` 的 `abl_boot_partition_label` 为准，脚本自动跟随）
2. 不要在传感器栈运行中执行 `echo stop > /sys/class/remoteproc/*/state`：会 RCU stall → panic。
3. 不要用 `dtc` 反编译-重编译来改 DTB：会破坏 `regulators-1/ldo10`（L10C，3.3V）的 4 字节
   `regulator-min/max-microvolt`，属于语义破坏。DTB 修改方式见 `../kernel/dtb/README.md`。

## 1. 核心不变量：内核固件路径必须是"悬空符号链接"

```
/lib/firmware/qcom/sm8250/xiaomi/elish/slpi.mbn  ->  /run/sensor-fw/slpi.mbn
```

- `/run` 是 tmpfs，**开机清空** → 内核 boot 早期看不到固件 → 不会抢先 auto_boot SLPI；
- 运行时 `slpi-sensors-start.sh` 把固件复制到 `/run/sensor-fw/slpi.mbn`，再启动 SLPI；
- 一旦 `/lib/firmware/.../slpi.mbn` 变成**普通文件**（例如重新安装 armbian-firmware-full、手工 cp、
  系统升级覆盖），下次开机会变成"内核 auto_boot → 监听器来不及就绪 → PD 看门狗 40s 打死 → SSR →
  SCM assign 不可重复 → 本次开机传感器永久不可用"。表现是 `dmesg` 里 PDM `dog_virtual_user` 崩溃、
  hexrpc 日志 attach 只读 `hw_platform` 就停住。
- `slpi-fw-guard.service`（开机早期、multi-user 之前）会检查：若是普通文件就移出并恢复符号链接，
  同时写 `/run/sensor-boot-bad` 让启动脚本快速失败并提示重启。**不要禁用该服务。**
- **升级 `armbian-firmware-full` 后必须检查这个路径**（见 INSTALL.md §6），必要时重启一次让守卫修正。
- 任何情况下**不要**把固件直接 `cp` 到该路径（`cp -f` 遇到悬空链接会把它替换成普通文件）。

## 2. 启动时序与预期日志

- `slpi-sensors.service`（`Type=exec`，由 `multi-user.target` 拉起但不阻塞桌面启动、与桌面并行；`PRE_DELAY=0`）
  按顺序：启动 warm 监听器 → 复制固件到 `/run` → `echo start` 启动 SLPI → 等设备出现 →
  `IIO_DELAY` 后拉起 iio → 轮询健康检查（gdbus 数据 + hexrpc registry 读取，最长 150s）。
- 实测开机→传感器可用 **20.9 秒**（2026-11-21 release #13：`up=20.92 sensors OK`；改造前 ~79s。PRE_DELAY=0, IIO_DELAY=8）。
  SLPI start issued 在 up=12.74s，PD registry 初始化约 8.2s。
- 每 boot 正常会看到：
  - `[start] SLPI start issued; device=yes after ...ms`
  - `[start] sensors OK (...)`，并写 `/var/log/sensor-last-boot.txt`
  - iio 日志 `No sensors found at startup; staying alive waiting for hotplug (patched)`（iio 早于
    SSC 设备被激活时）——补丁版会常驻等待热插，不影响功能；不是错误。
- 失败时 `dmesg`/日志特征与恢复见 `docs/TROUBLESHOOTING.md`。

## 3. 延迟参数（`/etc/sensor-tuning.conf`）

```
PRE_DELAY=0
IIO_DELAY=8
```

- `PRE_DELAY`：服务启动后额外等待时间。**0 经过 8 轮自动重启验证（8/8 成功）**，是当前默认。
- `IIO_DELAY`：SLPI 启动后等多久再拉起 iio 并做健康检查；8s 实测稳定。
- 如果某次开机传感器没起来：先干净重启；连续多次失败可把 `PRE_DELAY` 改成 `10` 或 `45` 再排查。
  注意失败率与延迟无关（见下条，0/10/45s 都通过过也都出现过）。

## 4. 已知残留问题

### 4.1 偶发 PD 静默卡死（约 1/14 次干净开机）
- 现象：`dmesg` **无** PDM 崩溃、无 `assign -22`；hexrpc attach 只读到 `hw_platform` 后停住；
  iio 反复 `'registry' sensor timed out`；start 脚本 150s 后判 `sensors FAILED`。
- 原因：PD 初始化阶段的偶发静默卡死（与延迟无关；0/10/45s 都通过过，也都出现过）。
- 恢复：**干净重启**（`sudo reboot`）。同 boot 内重启服务无效（SCM assign 不可重复）。

### 4.2 suspend/resume
- 合盖 suspend 会断开 fastrpc 会话。**s2idle 唤醒后 sensor PD 崩溃已由 0009 修复**（2026-11-19 起
  20 次 s2idle、含 10h47m 长睡，0 次 PDM/crash；release #13 当日 4 次 0 崩溃）。
- `60-sensors-suspend.sh` pre 停 iio、post 在监听器缺失时兜底拉起并重启 iio；唤醒后传感器恢复实测
  **3.3 s / 6.0 s**（`journalctl -t elish-sensors-resume`；iio 未运行时 worker 会拉起它）。若唤醒后仍缺失，
  干净重启（同 boot 内 SCM assign 不可重复）。
- 不要在 suspend 前留下"定时关机/重启"（已有 `40-cancel-scheduled-shutdown.sh` 守卫会在
  suspend 前取消 pending shutdown，避免"半关机+休眠"导致锁屏无法解锁）。

### 4.3 iio-sensor-proxy 相关（已在补丁中修，但升级会丢）
- 必须保持：D-Bus service 文件含 `SystemdService=iio-sensor-proxy.service`；
  drop-in 用 `Restart=on-failure`（**不能** `Restart=always`）；
  iio 源码带三处补丁（claim→polling、无传感器常驻、无条件连接 uevent）。
- 若看到 iio `NRestarts` 持续增长/多实例/重启风暴：检查上述三点（尤其 D-Bus service 文件）。
- 若 `LightLevel=0`/`orientation=undefined` 但 iio 正常：多为 claim 竞态，重启 iio
  （`sudo systemctl restart iio-sensor-proxy`）可恢复；并检查 `journalctl -b | grep Claim`。
- apt 升级 `iio-sensor-proxy` 包会覆盖自定义二进制 → 需重新 `ninja -C build install`。

### 4.4 其他
- 陀螺仪原始数据未提供（只有融合后的 rotv）；proximity 默认未启用（可按 accel 的方式加 `ssc-proximity`）。
- 固件 mount matrix 全 0 → iio identity；方向依赖 `81-libssc-xiaomi-elish.rules` 的矩阵，如方向不对改矩阵即可。
- 母本 registry 里的 `*.fac_cal*` 是**发行包默认值**（与 armbian-firmware-full 一致），不是本机工厂校准。

## 5. 常用命令

```bash
sensor-status                              # 总览（固件路径/AUTO_BOOT/PDM/attach/iio/数值）
sudo sensor-status
sudo journalctl -b -u slpi-sensors iio-sensor-proxy --no-pager
sudo dmesg | grep -E 'PDM|SDSP assign|Direct firmware load|Booting fw image.*slpi'
sudo tail -50 /var/log/hexrpc-boot.log
sudo cat /var/log/sensor-boot-report.txt
sudo touch /etc/disable-sensors && sudo reboot   # 临时禁用
sudo rm /etc/disable-sensors && sudo reboot      # 恢复
```

## 6. 升级前必读

软件包或内核升级对传感器栈的影响差异很大（内核/DTB/boot 镜像是最高危；固件包中危；
iio/hexrpc/libssc 非 dpkg 管理但不要误装发行版包）。完整评估、每项"可修补 vs 必须保持原样"、
升级前后检查清单见 **`docs/UPGRADE-IMPACT.md`**，升级后运行 `install/check-upgrade.sh`。

## 7. 升级/回滚速查

| 场景 | 操作 |
|---|---|
| 升级内核 | 重编 fastrpc.ko（同版本源码 + 补丁）；可能需重编 iio；重启验证 |
| 升级 armbian-firmware-full | 检查固件路径不变量；必要时恢复链接后重启 |
| 升级 iio-sensor-proxy 包 | 重新应用补丁并 `ninja install`；恢复 D-Bus service/drop-in |
| 传感器长期不稳 | `touch /etc/disable-sensors` 保系统正常；按 `docs/TROUBLESHOOTING.md` 排查 |
| 完全卸载 | `sudo ./install/uninstall.sh --purge-data`，再按需恢复内核模块等 |
