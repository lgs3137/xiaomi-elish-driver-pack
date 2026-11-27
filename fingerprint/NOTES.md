# 指纹子包注意事项 / 已知问题 / 恢复

> 与传感器子包共用的坑（固件符号链接、boot_b、内核升级、suspend）见合并包根目录 `NOTES.md`。
> 这里只列指纹特有内容。

## 0. 铁律

1. 改内核/启动镜像前备份 Linux 启动槽（本机 `boot_b`，按 armbianEnv 的 `abl_boot_partition_label`）、`/boot/armbian-kernel-csot.img`、DTB；回退用 `dd` 写回同一槽位（只写 Linux 侧）。
2. **不要升级 edge 内核**（ABL 脚本通配符会生成坏镜像）；不要关 `CONFIG_DEBUG_INFO_BTF`；不要改
   `CONFIG_LOCALVERSION`。
3. PAM 改动前确保还有 root/密码登录通道（保持一个 root TTY 或用密码 sudo），不要只留指纹一条路。
4. 不要重新启用 NOPASSWD sudo（本包不含 `020-nopasswd*`，也不建议）。
5. 不要用 `fingerpr` TA；必须是 `gfenu`。

## 1. 内核 ABI 三件套（最危险）

每次重编内核后必须检查（详见 `../kernel/README.md`），三者必须与外部模块一致：

| 检查 | 期望 |
|---|---|
| vermagic（`modinfo`/`strings vmlinux \| grep mod_unload`） | `6.18.44-current-sm8250 SMP mod_unload aarch64` |
| `pahole -C module vmlinux \| grep 'size:'` | `size: 1280` |
| `CONFIG_DEBUG_INFO_BTF` / `CONFIG_MODULE_ALLOW_BTF_MISMATCH` | 都是 `=y` |

不一致 → 所有外部模块拒绝加载 → 黑屏只剩背光。BTF 编译需要 ≥4GB swap。

## 2. CMA 连续内存分配失败（TA 加载失败头号原因）

- 加载一个 TA 需要约 9MB **物理连续**内存（`qcom_tzmem_pool_new()` →
  `dma_alloc_coherent()`，本机要 2244 pages），来自 `cma=256M` 的 CMA 区。
- 这个 CMA 区平时也当普通可移动内存用（page cache/匿名页），所以 `CmaFree`
  经常只有几 MB～几十 MB；`cma_alloc` 必须先把占用该区的页**迁移**走才能拿到
  连续块，内存压力大时迁移失败 → `-EBUSY`。
- 症状：loader 日志 `event=loader_error ... errno=12 Cannot allocate memory`，
  dmesg：`cma: __cma_alloc: reserved: alloc failed, req-size: 2244 pages, ret: -16`
  （cma bitmap 仍显示大部分 free，属误导）；随后 dma-direct 回退 buddy
  order-12 分配，但 `CONFIG_ARCH_FORCE_MAX_ZONEORDER=10` → 只会 WARN 并失败。
- **这不是 TA 堆泄漏**，也不是永久性的：内存缓过来后同一分配会成功（实测用
  `/dev/dma_heap/reserved` 分配 9MB 正常）。每次重载 loader 都要重新做这次
  9MB 分配，所以重载越频繁越容易踩中。
- 当前处理（2026-11-13 起固化）：
  - `qsee-app-loader@.service` 的 `ExecStart` 被 drop-in
    `60-retry-reclaim.conf` 换成 `/usr/local/bin/qsee-app-loader-retry`：失败时
    自动 `drop_caches` + `compact_memory` 后**退避重试**，不再要求重启系统；
    `NotifyAccess=all` + `TimeoutStartSec=0` 支持这种长时间重试。
  - `fp-ta-watchdog` 对 CMA 失败只记日志（重试由 wrapper 负责），并加了每 60s
    检查 loader 是否 inactive 的安全网；`-22`/TA 拒绝仍走“重启 loader”。
  - 正确用法仍是：**加载一次、loader 常驻**，不要频繁手动 `--load`/重载。
- 恢复：优先等 wrapper 重试成功（通常几秒内，drop_caches 后 CMA 立即有迁移目标）；
  必要时手动 `systemctl restart qsee-app-loader@gfenu`；重启系统仍是最后兜底，
  但已经不是 CMA 失败的必需操作。

## 2b. CMA 碎片 / TA 重载失败（2026-11-23）

- **现象**：s2idle 后 fprintd 报 `Goodix QSEE bring-up command 1005 failed ... status 1001`；
  重启可恢复。
- **根因**：TA 会话失效需要重载 `qsee-app-loader@gfenu`，但 TA 需要约 **9 MiB 连续 CMA**；
  长时间运行后 CMA 碎片化，CmaFree 虽有 50–100 MB 仍 `Cannot allocate memory`。
  `qsee-app-loader-retry` 的 drop_caches/compact 之前被服务单元 `ProtectKernelTunables=yes`
  限制（只读 `/proc/sys/vm`）；已改为 `ProtectKernelTunables=no`，并在 resume helper 中
  先做外部 reclaim。
- **已从根上绕开并验证（2026-11-23）**：联合 DTB 给 `/firmware/scm` 加了 32 MiB 专用
  `shared-dma-pool`（`tz-ffi@93000000`），TA 的 9 MiB 走该池，不再依赖全局 CMA。
  仍安装 `70-goodix-fp-resume.sh` + `fp-resume-reset`，但自动钩子只做 `--ensure-loader`
  （重启 watchdog + 确保 loader 在），**不跑 fprintd 探测**：2026-11-23 实例证明自动探测
  会抢 GDM 锁屏指纹解锁的 claim，导致 “device still busy”、退回密码解锁。真正的 TA 失效
  由 `fp-ta-watchdog` 重载 loader；需要手动深查时再跑 `fp-resume-reset`（probe 模式）。
- **20 秒“假死”**（2026-11-23 13:47）：长睡唤醒后 Firefox `touch-fix` 的 rtcwake freeze
  撞上正在进行的指纹认证；freeze 冻结 qsee-supplicant 后，fprintd 的 TEE 请求卡在 D 状态，
  内核等待 `pm_freeze_timeout` 20s 才放弃。系统级 `68-touch-fix.sh` 已改为由
  `/usr/local/sbin/touch-fix-run` 先等解锁后再 freeze；本包不包含该 workaround。
- 手动恢复（不需要重启整个系统时先试）：`sudo /usr/local/sbin/fp-resume-reset`；
  日志 `/var/log/fp-resume.log`。仍失败则重启。

## 3. TA "拒服务"（1062 / `scm call failed -22`）

- **2026-11-27 根因确认**：`AUTHENTICATE` 是一次性命令，mismatch 也必须用
  `CANCEL` 收尾；旧驱动在 mismatch 分支直接 `armed = FALSE`，既不发
  `AUTHENTICATE_FINISH` 也不发 `CANCEL`，TA 留在 armed 状态。bioauth 每 ~3 s
  自动重试，下一次 verify 撞上未清状态，TZ 对整个 app 返回 `-22`，只能重载
  loader。驱动已改为 mismatch/质量错误后显式 `cancel_armed()`，并上报
  `FP_FINGER_STATUS_NEEDED` 供 fprintd 暴露 `finger-needed`。
- 错误日志现在带命令号：`QSEE invoke cmd 1016: ...`、`cmd 1086`、`cmd 1010`，
  可直接区分 IRQ / FINISH / AUTHENTICATE 哪一步失败。
- **首批失败的另一半根因（2026-11-27 实测）**：用户在传感器 bring-up 期间就按下
  手指时，IRQ 边沿会被 GPIO 锁存；AUTHENTICATE 后一开中断就对这个“旧边沿”发
  `IRQ 1016`，TA 认为它不属于本次 capture，返回 `-22`。驱动现在在 AUTHENTICATE
  之前 `drain_pending_irq()`（短暂开中断、丢弃 netlink 事件、再关中断），把早按
  的边沿吃掉；本次扫描会等下一次按压，而不是把 TA 打坏。bioauthd 对首次
  device-error 还会在 watchdog 重载后静默重试一次，避免直接弹“指纹不可用”。
- 旧现象：短时间内并发/连续多个 verify（脚本连测）会把 TA 留在 armed 状态。
- **GDM 锁屏“失败一次就不能用”**：`pam_fprintd` 默认 `max-tries=3
  timeout=30`，一次 mismatch 后 worker 仍占着 fprintd；GDM 再起一个
  fingerprint worker 时报 `Device was already claimed`。`gdm-fingerprint` 已改
  为 `max-tries=1 timeout=10`，失败/超时后尽快 Release。
- 恢复（不重启）：`sudo systemctl restart qsee-app-loader@gfenu`；
  已部署 `fp-ta-watchdog` 自动做（依赖 libfprint 日志补丁）。
- `fp-ta-watchdog` 现在区分：`-22`/QSEE refusal → 重载 loader；只有真正的
  `Cannot allocate memory`/CMA 碎片才停止 loader 并提示重启。
- `qsee-app-loader@.service` 增加了 restart limit drop-in（3 次/5 分钟、
  `RestartSec=10s`），避免 TA 失败时每 2 秒无限重载。
- 日常：**不要并发跑指纹操作**，上一个结束后再发下一个。

## 4. TA / mdt_loader

- `gfenu.mdt` 是 ELF32（原生支持）；`fingerpr.mdt` 是 ELF64（本包 mdt_loader 已加 ELF64 支持）。
- Android 里两套 TA：`gfenu` 正确、`fingerpr` 错误（FPC/旧方案）；用错时命令返回 `0xFFFFFFFF`。
- `/lib/firmware/fingerpr.*` 是历史工作副本，本项目最终不需要。

## 5. libfprint 会被 apt 覆盖

- 自编译 libfprint 1.94.100（`wrobelda/libfprint` goodix-qsee 分支 `430e24e5` + 日志补丁）会覆盖发行版 `libfprint-2-2`。
- **建议 `sudo apt-mark hold libfprint-2-2`**，防止 `apt upgrade` 自动覆盖；确需升级时 `apt-mark unhold`，
  升级后重新 `ninja -C build install && sudo ldconfig`，然后 `systemctl restart fprintd`。
- fprintd 的 systemd 沙箱默认 DeviceAllow 不含指纹/TEE 设备 → 必须保留
  `/etc/systemd/system/fprintd.service.d/60-goodix-qsee.conf`（`/dev/goodix_fp` + `/dev/tee0..3`）。

## 6. sudo 指纹 / PAM 坑

- 本版 PAM 不认 `success=end`，会丢弃整行；必须 `success=done`。
- `pam_exec` 默认以**登录用户**身份运行，触发文件必须放 `/run/user/<uid>/`。
- PAM 上下文里不能直接弹窗；必须"hook 写文件 + 用户会话 watcher 弹窗"。
- zenity 默认解析 Pango markup，命令含 `<>&` 会坏 → 必须 `--no-markup`。
- 认证成功关闭弹窗靠 PAM **session** hook；`sudo -v` 不建 session → 靠 12s 超时关闭。
- 指纹与密码不能真正并行：指纹优先、8s 超时回退密码；等待期间输入的密码会缓冲。
- 从无终端环境（后台/服务）触发 sudo 不会弹密码提示，8s 不按指纹就失败，属预期。
- 回退：恢复 `/root/fp-pam-backup-*/sudo`；不要依赖本包附带备份（本包**不含** PAM 备份和 NOPASSWD 文件）。

## 7. DTB 与 `firmware-name`

- 联合 DTB 需要：指纹 `/fingerprint` 节点（`compatible="goodix,gf3626"`、`firmware-name="gfenu"`、
  GPIO 23/125、L10A 供电）+ 传感器 `qcom,vmids=<3 15 5 6>`。
- **不要用 dtc 反编译重编译改属性**：会把 `regulators-1/ldo10` 的 4 字节电压属性改坏。
  用内核 DTS 源码重编，或按 `../kernel/dtb/README.md` 的就地脚本（保持长度）。
- 升级内核会覆盖 DTB 并重建 boot_b（`zz-update-abl-kernel` 用包内 DTB）→ 指纹和传感器同时失效，
  必须重做联合 DTB（见 `../kernel/README.md`）。

## 8. 识别率

- `fprintd-verify` 的 `verify-no-match` 是**真识别失败**（160×36 侧边小面积，对位置/干湿/按压力度敏感）；
  `verify-retry-scan` 等是图像质量问题，不是驱动故障。
- 建议：录入/验证时手指干燥、位置一致、力度稳定；多录几根手指。

## 9. 其他

- `gjs` 不要卸（GNOME 通知依赖）；`apt autoremove` 会带走。
- `/etc/dpkg/dpkg.cfg.d/10-firmware-trim` 会让 `dpkg -V` 报大量 missing，属正常噪音。
- 指纹模板在 `/var/lib/fprint/...`（用户私有），**不要**拷贝到别的机器/进安装包。
- 升级影响（内核/固件/libfprint/PAM/fprintd）见合并包根目录 `../docs/UPGRADE-IMPACT-ALL.md`
  与 `../sensors/docs/UPGRADE-IMPACT.md`。
