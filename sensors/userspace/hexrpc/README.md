# hexagonrpcd（hexagonrpc 0.3.2 + warm-attach / M2 可写 registry 补丁）

## 为什么必须 0.3.x

- 0.3.x 使用 `-s`（INIT_ATTACH_SNS）与 `-R <hexagonfs root>` 的行为与本项目内核 fastrpc 匹配；
- 0.5.0 在 attach 时返回 `Unsupported handle: 0xffffffff`，无法使用。

## 补丁（必须/默认）

### 0001 — warm-attach（必须）

`patches/0001-hexrpc-0.3.2-warm-attach.patch` 对应 `hexagonrpcd/rpcd.c`：

1. `HEXAGONRPC_WARM_ATTACH=1` 时，open `/dev/fastrpc-sdsp` 采用**预热式重试**（20µs 级别），
   保证在设备出现的极短窗口内立即打开；
2. `FASTRPC_IOCTL_INIT_ATTACH_SNS` 遇到 `EPERM` 时毫秒级重试（50µs × 2000）。

原因：attach 必须发生在设备出现后的约 5–20ms 窗口内（延迟矩阵实验：0ms 成功，≥50ms 全部失败），
太早 attach 返回 EPERM，太晚 PD 走错误初始化路径并崩溃。补丁把这个窗口稳定命中。

### 0003/0004/0005 — M2 可写 sensor registry（默认部署）

社区补丁（Armada OS / SteamOS-ARM 打包记录，原始作者 suckbluefrog）适配本机 v0.3.2：

- `patches/0003-hexagonrpcd-add-writable-hexagonfs.patch`：HexagonFS 增加 flag-aware open、write、truncate；
- `patches/0004-hexagonrpcd-support-writable-sensor-registry.patch`：apps_std 增加
  fwrite/fsync/fremove/ftruncate/frename，把 `/mnt/vendor/persist/sensors` 映射为可写树
  （只允许写 sensor persist 树），并修正 fflush 签名；`rpcd.c`/`rpcd_builder.c` 两处 hunk
  已按本机 v0.3.2 base 适配（本机 `fastrpc_apps_std_init` 在 `start_reverse_tunnel()` 内）；
- `patches/0005-hexagonrpcd-support-large-and-extended-callbacks.patch`：listener input cache
  256B→1MB，并解码 QAIC method 31 转义（fwrite/rename 载荷与大 method 号需要）。

效果：PD 的 `temp.json`/registry 写回成功（此前每次 attach 约 1570 次写被拒），
**PD registry 初始化由 ~35 s 降到 8.2 s**，开机传感器可用 20.9 s（2026-11-21 release #13），
iio `NRestarts=0`。可写落盘只到 `/run/sensors-rootsvc`（tmpfs，每次启动从母本重建），
不污染 `/usr/share/qcom-ssc-elish`。

### 0002 — sns_reg_version 只读映射（回退方案，默认不应用）

`patches/0002-hexrpc-0.3.2-registry-version.patch` 只是 0004 之前的过渡方案：在虚拟 persist 目录里补
`sns_reg_version` 文件映射，减少 PD 版本读取失败。它不解决 `temp.json` 写回问题；
**可写构建已替代它**，因此默认构建顺序为 `0001` → `0003` → `0004` → `0005`，**不要**再叠 0002。

## 编译

依赖（Debian/Ubuntu）：`build-essential meson ninja-build pkg-config`（该版本无其它外部库依赖）。

默认（M2 可写 registry，推荐）：

```bash
git clone https://github.com/linux-msm/hexagonrpc
cd hexagonrpc
git checkout v0.3.2
git apply .../patches/0001-hexrpc-0.3.2-warm-attach.patch
git apply .../patches/0003-hexagonrpcd-add-writable-hexagonfs.patch
git apply .../patches/0004-hexagonrpcd-support-writable-sensor-registry.patch
git apply .../patches/0005-hexagonrpcd-support-large-and-extended-callbacks.patch
meson setup build --prefix=/opt/hexrpc-032b
ninja -C build
sudo ninja -C build install
sudo install -m 0755 build/hexagonrpcd/hexagonrpcd /opt/hexrpc-032b/bin/hexagonrpcd.writable-v1
```

安装后布局（本项目脚本依赖这个路径）：

```
/opt/hexrpc-032b/bin/hexagonrpcd           # 构建产物（上面的 ninja install）
/opt/hexrpc-032b/bin/hexagonrpcd.writable-v1  # M2 构建（默认优先使用）
/opt/hexrpc-032b/lib/aarch64-linux-gnu/libhexagonrpc.so
/opt/hexrpc-032b/libexec/hexagonrpc/chrecd
```

`bin/hexagonrpcd` 依赖 `libhexagonrpc.so`，运行时通过
`LD_LIBRARY_PATH=/opt/hexrpc-032b/lib/aarch64-linux-gnu` 提供（启动脚本已设置）。

不要把它装到 `/usr/local` 覆盖系统里的其它 hexagonrpc 版本；本项目固定使用 `/opt/hexrpc-032b`。
**本包不附带预编译二进制**；安装后 sha256 参考值见根 `../../../VERSIONS.md`
（`hexrpc-sdsp-service.sh` 选择顺序：`hexagonrpcd.writable-v1` → `hexagonrpcd.regver-v1` → 原厂）。

## 运行方式（由 `slpi-sensors-start.sh` 调用）

```
LD_LIBRARY_PATH=/opt/hexrpc-032b/lib/aarch64-linux-gnu \
HEXAGONRPC_WARM_ATTACH=1 \
/opt/hexrpc-032b/bin/hexagonrpcd -f /dev/fastrpc-sdsp -d sdsp -s -R /run/sensors-rootsvc
```

验证 attach 成功：`/var/log/hexrpc-boot.log` 中 attach 段应出现
`stat(/vendor/etc/sensors/sns_reg_config)`、`sensors/registry` 等大量文件访问；
失败时通常只有一条 `/sys/devices/soc0/hw_platform` 就停止。

## 回滚

删除 `/opt/hexrpc-032b/bin/hexagonrpcd.writable-v1` 并重启，脚本会回退到 `hexagonrpcd.regver-v1`
（若存在），否则原厂 `hexagonrpcd`。
