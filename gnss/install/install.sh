#!/bin/bash
# 安装 airoha-gnssd + gpsd 集成（在 elish 本机执行）
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
GDIR=$(cd "$HERE/.." && pwd)
BIN=/usr/local/sbin/airoha-gnssd
UNIT=/etc/systemd/system/airoha-gnssd.service
DROPIN_DIR=/etc/systemd/system/gpsd.service.d
DROPIN=$DROPIN_DIR/airoha-gnssd.conf
GPSD_DEFAULT=/etc/default/gpsd

[ "$(id -u)" -eq 0 ] || { echo "需要 root: sudo $0"; exit 1; }

echo "== 编译 airoha-gnssd"
make -C "$GDIR/userspace"

echo "== 安装二进制 / systemd 单元 / 文档"
install -D -m 755 "$GDIR/userspace/airoha-gnssd" "$BIN"
install -D -m 755 "$GDIR/userspace/gps-nmea-share" /usr/local/sbin/gps-nmea-share
install -D -m 644 "$GDIR/systemd/airoha-gnssd.service" "$UNIT"
install -D -m 644 "$GDIR/systemd/gps-nmea-share.service" /etc/systemd/system/gps-nmea-share.service
install -D -m 644 "$GDIR/systemd/gps-nmea-share.socket" /etc/systemd/system/gps-nmea-share.socket
install -D -m 644 "$GDIR/systemd/gnss-idle.service" /etc/systemd/system/gnss-idle.service
install -D -m 644 "$GDIR/systemd/gnss-idle.timer" /etc/systemd/system/gnss-idle.timer
install -D -m 755 "$GDIR/systemd/gnss-idle-check.sh" /usr/local/sbin/gnss-idle-check
install -D -m 644 "$GDIR/README.md" /usr/local/share/doc/airoha-gnssd/README.md
install -D -m 644 "$GDIR/polkit/49-iio-sensor-proxy-geoclue.rules" \
    /etc/polkit-1/rules.d/49-iio-sensor-proxy-geoclue.rules

echo "== 内核模块 airoha_gps"
if [ -f "/lib/modules/$(uname -r)/extra/airoha_gps.ko" ]; then
    echo airoha_gps > /etc/modules-load.d/airoha-gps.conf
    modprobe airoha_gps 2>/dev/null || true
    echo "  OK  /dev/airoha_gps = $( [ -c /dev/airoha_gps ] && echo present || echo MISSING )"
else
    echo "  WARN 未找到 /lib/modules/$(uname -r)/extra/airoha_gps.ko"
    echo "       按 gnss/kernel/README.md 编译安装，否则无法控制 GNSS 供电"
fi

echo "== gpsd 配置"
if command -v gpsd >/dev/null 2>&1; then
    if [ -f "$GPSD_DEFAULT" ] && [ ! -f "$GPSD_DEFAULT.bak-airoha" ]; then
        cp -a "$GPSD_DEFAULT" "$GPSD_DEFAULT.bak-airoha"
        echo "  已备份原 gpsd 配置 -> $GPSD_DEFAULT.bak-airoha"
    fi
    cat > "$GPSD_DEFAULT" <<'EOC'
# 由 airoha-gnssd 安装脚本管理：gpsd 读取 airoha-gnssd 发布的 NMEA pty。
# 原文件备份：/etc/default/gpsd.bak-airoha
START_DAEMON="true"
USBAUTO="false"
DEVICES="/dev/ttyGNSS0"
GPSD_OPTIONS="-n"
EOC
    install -D -m 644 "$GDIR/systemd/gpsd.service.d-airoha-gnssd.conf" "$DROPIN"
else
    echo "  WARN 未安装 gpsd（sudo apt install gpsd gpsd-clients），跳过 gpsd 集成"
fi

echo "== GeoClue 标准 API（network-nmea）"
if command -v geoclue >/dev/null 2>&1 || systemctl cat geoclue.service >/dev/null 2>&1; then
    GCONF=/etc/geoclue/geoclue.conf
    if [ -f "$GCONF" ]; then
        [ -f "$GCONF.bak-airoha" ] || cp -a "$GCONF" "$GCONF.bak-airoha"
        # 使用本地 Unix socket，而不是 Avahi 发现
        sed -i -E 's|^#?\s*nmea-socket=.*|nmea-socket=/run/gps-share.sock|' "$GCONF"
        grep -q '^nmea-socket=/run/gps-share.sock' "$GCONF" || \
            printf 'nmea-socket=/run/gps-share.sock\n' >> "$GCONF"
        echo "  已配置 geoclue.conf nmea-socket=/run/gps-share.sock（原文件备份 .bak-airoha）"
    fi
    install -D -m 644 "$GDIR/systemd/geoclue.service.d-airoha-gnssd.conf" \
        /etc/systemd/system/geoclue.service.d/airoha-gnssd.conf
    echo "  已安装 geoclue 排序 drop-in"
else
    echo "  WARN 未安装 geoclue-2.0；地图类应用的标准 API 不可用（sudo apt install geoclue-2.0）"
fi

echo "== 切换为按需启动（socket 激活 + 空闲停止）"
systemctl daemon-reload
# 旧版本是常驻服务；先停掉并禁止开机启动，改由 socket 触发。
systemctl stop gps-nmea-share.service gpsd.service airoha-gnssd.service 2>/dev/null || true
systemctl disable airoha-gnssd.service gps-nmea-share.service 2>/dev/null || true
systemctl disable gpsd.service 2>/dev/null || true
# gpsd.socket 由发行版提供；GeoClue 走 gps-nmea-share.socket
systemctl enable gpsd.socket >/dev/null 2>&1 || true
systemctl enable gps-nmea-share.socket >/dev/null
systemctl enable gnss-idle.timer >/dev/null
systemctl start gpsd.socket gps-nmea-share.socket gnss-idle.timer
echo "  已启用：gpsd.socket / gps-nmea-share.socket / gnss-idle.timer"
echo "  GNSS 不会开机常驻；gpsd 客户端或 GeoClue 请求时自动启动，空闲后自动停止。"
if systemctl cat geoclue.service >/dev/null 2>&1; then
    # 让 polkit 重新读取规则（rules.d 一般会自动 reload，重启最稳）
    systemctl restart polkit 2>/dev/null || true
    systemctl restart geoclue.service 2>/dev/null || true
fi

echo
echo "== 完成。验证： sudo $HERE/verify.sh"
