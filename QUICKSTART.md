# 快速开始（傻瓜包版）

本包把能自动化的步骤都脚本化了：apt 依赖、设备数据提取、补丁应用、用户态编译安装、
系统集成、子系统安装、合并自检。你只需要提供 **2 个设备文件**，其余命令自动完成；
最后重启一次即可。

> 本文件是一键安装与手动事项的**唯一权威**；根 README/INSTALL 只做摘要与链接。

## 1. 准备（仅需两个文件）

| 文件 | 用途 | 来源 |
|---|---|---|
| Android vendor 镜像（如 `vendor_a.img`） | 传感器 proto/hals 等 `/etc/sensors` 数据 | 从**你自己的设备**只读 dump vendor 分区（`docs/DEVICE-DATA-EXTRACTION.md` §1） |
| pMOS SLPI 固件包 `firmware-xiaomi-elish-slpi-*.apk` | 单文件 `slpi.mbn` | postmarketOS 的 firmware-xiaomi-elish-slpi 子包 |

放到任意目录即可；脚本也会自动在 `./`、`~/`、`~/Downloads/`、`/root/` 查找同名文件。
指纹 TA 可选：若系统已装 `/lib/firmware/gfenu.*` 会自动复用；否则用
`--fingerprint-adb`（需 adb root）或 `--fingerprint <目录|firmware_mnt.img>`。

## 2. 一键安装

```bash
cd ~/xiaomi-elish-linux-v1-final

# 先看会做什么（不写系统）：
./install.sh --dry-run --android /path/vendor_a.img --pmos /path/firmware-xiaomi-elish-slpi-*.apk

# 正式安装（自动：依赖→提取→数据母本→补丁+编译用户态→系统集成→自检）：
sudo ./install.sh --android /path/vendor_a.img --pmos /path/firmware-xiaomi-elish-slpi-*.apk --yes

# 相机调校（LSC/CCM）会自动从 --android 的 vendor 调校 bin 里提取，
# 生成 src/tuning_data.h 后再编译相机；不想用本机数据可加 --no-camera-tuning。
# 也可单独给调校 bin 目录：
#   sudo ./camera/install.sh --tuning-bins /path/to/com.qti.tuned.*.bin/dir

# 只安装包内单一联合 DTB（已合并 Hi556；不重编内核，--write-boot 才重建 Linux 槽）：
sudo ./install.sh --with-dtb --write-boot --yes

# 或全量内核（也会安装同一份联合 DTB）：
sudo ./install.sh --with-kernel --kernel-src /var/tmp/kbuild-src --write-boot --yes
```

> **内核/DTB 是硬依赖**：sensor/fastrpc/fingerprint/GNSS/相机等驱动都依赖已打补丁的内核 + 联合 DTB。
> `--with-kernel` 是显式 opt-in（避免自动写 boot + 需自备同版本源码），**不是可跳过项**；
> 只有已运行本包完整内核+DTB 时才可跳过，一键器会预检 DTB/模块并警告。
> `--with-dtb` 只更新 DTB，不编译内核模块；全新系统请用 `--with-kernel`。

> 默认组件还包含**后摄闪光灯“开机闪一下”修复**（`flash-led/`，自动安装）；**GNOME 手电筒**
> （`torch/`）是可选组件、默认不装：完整安装加 `--with-torch`，或单独 `sudo ./torch/install.sh`
> （装好后注销/重新登录，控制中心出现「手电筒」开关）。

## 3. 重启并验证

```bash
sudo reboot
sudo ./install/check-all.sh
sensor-status
```

预期（M2 可写 registry 后）：**开机 ~22s 传感器可用、桌面 ~38s、休眠唤醒 ~10s**。

## 仍需手动的事（很少）

1. **提供上面两个设备文件**（本包不含，避免分发厂商数据；获取方法见 `docs/DEVICE-DATA-EXTRACTION.md`）。
2. **重启一次**（内核/服务/固件路径生效必需）。
3. **内核**：本包不附带内核源码；若未加 `--with-kernel`，从 Armbian 6.18.44 源码树执行
   `sudo ./kernel/build-and-install.sh --kernel-src <源码> --write-boot`（详见 `kernel/README.md`）。
4. 指纹录入：`fprintd-enroll -f left-index-finger "$USER"`（可选）。
5. sudo 指纹 PAM（可选，安全敏感，旧指纹栈）：
   `sudo ./install.sh --pam --no-deps --skip-extract --skip-build --yes`
   （脚本会备份原 `/etc/pam.d/sudo`；先确认能用密码回退）。
6. bioauth 生物认证 PAM（可选，默认不装；新栈，推荐）：
   - 只装：`sudo ./install.sh --no-deps --skip-extract --skip-build --with-bioauth --yes`
   - 接 sudo/pkexec：加 `--bioauth-sudo` / `--bioauth-pkexec`
   - 先读 `bioauth/INSTALL.md`；不要和上面第 5 条的 `--pam` 同时启用；
     回滚：`sudo ./bioauth/scripts/install-bioauth.sh --rollback`。
7. GNOME 手电筒（可选，默认不装）：
   - `sudo ./install.sh --no-deps --skip-extract --skip-build --with-torch --yes`（或 `sudo ./torch/install.sh`）
   - 装好后注销/重新登录，控制中心（右上角或 Super+S）出现「手电筒」开关；`torch on/off` 命令行同样可用。
   （开机闪光灯误闪修复已由默认组件 `flash-led/` 自动安装，无需手动操作。）

## 常用分阶段命令

| 目的 | 命令 |
|---|---|
| 只提取数据/固件 | `sudo ./install/extract-all.sh --android ... --pmos ...` |
| 安装可选 bioauth（不改 PAM） | `sudo ./install.sh --no-deps --skip-extract --skip-build --with-bioauth --yes` |
| bioauth 接入 sudo / pkexec | 加 `--bioauth-sudo` / `--bioauth-pkexec`（见 `bioauth/INSTALL.md`） |
| 只编译用户态 | `sudo ./install/build-userspace.sh` |
| 只装系统集成 | `sudo ./install.sh --no-deps --skip-extract --skip-build` |
| 只自检 | `sudo ./install/check-all.sh` |
| 内核 | `sudo ./kernel/build-and-install.sh --kernel-src <源码> --write-boot` |
| 相机 | `sudo ./camera/install.sh` |
| 传感器 | `sudo ./sensors/install/install-system-files.sh`（+ `install-data.sh`） |
| 指纹 | `sudo ./fingerprint/install/install-fingerprint-files.sh [--pam --user]` |
| GNSS | `sudo ./gnss/install/install.sh` |
| 后摄闪光灯开机误闪修复 | `sudo ./flash-led/install.sh`（默认组件，turnkey 已自动装） |
| GNOME 手电筒（可选） | `sudo ./torch/install.sh`（装完注销/重新登录） |

所有脚本支持 `--help` 与 `--dry-run`；已安装的组件会自动跳过（`--force` 可强制重编）。
