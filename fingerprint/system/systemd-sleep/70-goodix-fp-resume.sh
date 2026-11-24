#!/bin/bash
# Post-resume recovery.
#
# 1) fprintd keeps its QSEE TEE / Goodix netlink session open across suspend; after
#    s2idle that session goes stale: the first verify fails with
#    "Cannot run while suspended" and the SPI driver floods dmesg with
#    "goodix_fp_spi: failed to send netlink event to user space: -11".
#    Restart it synchronously (before the lock screen arms fingerprint auth) so it
#    reopens the device and drains the netlink queue.  Compact first: qseecom_tee
#    needs an order-7 (512 KiB contiguous) pool allocation.
# 2) Schedule the TA reload check in its own transient unit (survives systemd-sleep).
# Manual equivalent: sudo /usr/local/sbin/fp-resume-reset
[ "${1:-}" = "post" ] || exit 0
LOG=/var/log/fp-resume.log
log() { echo "$(date -Is) [fp-resume] $*" >>"$LOG" 2>/dev/null || true; }

sleep 1
sync
echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true
systemctl restart fprintd >>"$LOG" 2>&1 && log "fprintd restarted after resume" \
    || log "fprintd restart failed"

command -v systemd-run >/dev/null 2>&1 || exit 0
unit="fp-resume-$(date +%s)"
systemd-run --collect --unit="$unit" --on-active=4s \
    --description="Reload Goodix TA after resume" \
    /usr/local/sbin/fp-resume-reset --ensure-loader >>"$LOG" 2>&1 || {
    log "systemd-run failed"
}
exit 0
