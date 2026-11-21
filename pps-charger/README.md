# pps-charger（可选安装，默认启用）：受控 11V PPS 快充

插上支持 PPS 的 PD 充电器后，把设备从 9V/3A 固定契约（27W）切到 **11V PPS**，
用 8 秒一次 **keep-alive** 维持契约，并按电池温度分档限流。实测（50–56% 电量）：

| 模式 | 电池侧功率 | 备注 |
|---|---|---|
| 9V/3A 固定（不装/未启用本组件） | ~18.9W | 稳定，SMB5 + bq2597x 双泵 |
| PPS 9V keep-alive（4.5A→3.35A 分档） | ~20.5W | 契约稳定，无 hard reset |
| **PPS 11V keep-alive（4.5A→3.375A 分档）** | **~20.5W 持续；短测 11V/4A 可到 23.5W+** | 温度约 40°C，41.5°C 回退 |

> 关键发现：本机 100W PD 头的 PPS 有 **~13 秒看门狗**——建立契约后不再发请求就会
> **充电器主动 Hard Reset**（TCPM 日志 `Received hard reset`）。每隔 ≤8 秒重发一次
> 当前 PPS 请求即可稳定保持；每次重协商后还要重设 SMB5 输入限流（ICL），否则充电会掉。
> 源 PPS 能力随充电器端口变化（3.3–11V/2.75A 或 3.3–21V/5A），服务从 TCPM debugfs 读取。

## 策略

- 仅当 PD 源支持 PPS、电量 < 90%、温度 < 41.5°C 时启用 11V；
- 请求电流 = min(源 PPS 上限, **4.5A**) 再按温度分档：**100% / 75% / 55%**
  （11V 下约 4.5A/3.375A/2.475A，输入上限约 49.5W）；
- 每 **8 秒** keep-alive 重发当前请求，并重设 SMB5 ICL=3A；
- 温度 ≥41.5°C 或电量 ≥90% → 退回 9V 固定档；降到 ≤38.5°C 再尝试；
- PPS 掉线自动检测并退避重试（30s 起，最长 5 分钟）；拔线/停服务自动回退固定档。

## 安装 / 使用

```bash
sudo ./pps-charger/install.sh        # 安装并启用（开机自启）
sudo ./pps-charger/verify.sh         # 自检（未安装则 SKIP）
journalctl -u elish-pps-charger -f   # 日志
sudo /usr/local/sbin/elish-pps-charger --revert   # 手动回退 9V
sudo systemctl disable --now elish-pps-charger    # 临时停用
sudo ./pps-charger/uninstall.sh      # 卸载并回退 9V
```

一键安装器里是可选组件：`sudo ./install.sh ... --with-pps-charger`（默认不装）。

## 注意

- **只适用于稳定支持 PPS 的充电器**；本机 100W 头靠 keep-alive 才能稳住，其他充电器行为可能不同；
- 温度到 41.5°C 会退回固定档，但 SMB5 输入限流不可写、双泵仍发热，强散热（不盖保护套）很重要；
- 本组件不改变 SMB5 `soc-step` 曲线和 bq2597x 满电保护；
- 原厂 66W 是 11V/6A 私有协议；本组件是标准 PPS 路线，实测 ~20.5W 持续（比固定档 +8%）。
