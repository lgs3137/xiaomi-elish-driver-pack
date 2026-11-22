#!/bin/bash
# Stop the on-demand GNSS chain after GNSS_IDLE_SECS without external clients.
# gps-nmea-share's internal TCP connection to gpsd is not counted as a client.
set -u
STATE=/run/gnss-idle.last
IDLE=${GNSS_IDLE_SECS:-180}
now=$(date +%s)
active=0

# 1) external gpsd clients (TCP 2947), excluding gps-nmea-share itself
if command -v ss >/dev/null 2>&1; then
    # client side only (dport=2947); exclude gps-nmea-share's internal
    # connection to gpsd, otherwise the idle timer could never fire.
    if ss -Htnp state established '( dport = :2947 )' 2>/dev/null \
       | grep -v 'gps-nmea-share' | grep -q .; then
        active=1
    fi
    # 2) clients on the Unix sockets (gpsd.sock / gps-share.sock); LISTEN is not established
    if ss -Hx state established 2>/dev/null \
       | grep -Eq '/run/(gps-share|gpsd)\.sock'; then
        active=1
    fi
fi

if [ "$active" = 1 ]; then
    echo "$now" >"$STATE"
    exit 0
fi
if [ ! -s "$STATE" ]; then
    echo "$now" >"$STATE"
    exit 0
fi
last=$(cat "$STATE" 2>/dev/null || echo "$now")
if [ $((now - last)) -ge "$IDLE" ]; then
    systemctl stop gps-nmea-share.service gpsd.service airoha-gnssd.service 2>/dev/null || true
    rm -f "$STATE"
fi
