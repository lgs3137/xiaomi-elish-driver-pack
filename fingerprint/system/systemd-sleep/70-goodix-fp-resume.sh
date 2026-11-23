#!/bin/bash
# Post-resume recovery: schedule Goodix TA reload (own transient unit, so it
# survives systemd-sleep exiting).  Manual equivalent:
#   sudo /usr/local/sbin/fp-resume-reset
[ "${1:-}" = "post" ] || exit 0
LOG=/var/log/fp-resume.log
command -v systemd-run >/dev/null 2>&1 || exit 0
unit="fp-resume-$(date +%s)"
systemd-run --collect --unit="$unit" --on-active=4s \
    --description="Reload Goodix TA after resume" \
    /usr/local/sbin/fp-resume-reset >>"$LOG" 2>&1 || {
    echo "$(date -Is) [fp-resume] systemd-run failed" >>"$LOG" 2>/dev/null || true
}
exit 0
