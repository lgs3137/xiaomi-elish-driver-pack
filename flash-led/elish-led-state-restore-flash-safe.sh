#!/bin/bash
# elish — run Armbian's LED-state restore on a filtered copy of the state file,
# with flash-class LEDs (rear camera flash / torch, e.g. white:flash) removed.
#
# Why: armbian-led-state-restore.sh has a workaround for "trigger=none" that
# first writes "default-on" and then "none".  For a flash-class LED
# (LED_DEV_CAP_FLASH, PM8150L white:flash on this tablet) the default-on trigger
# sets brightness to max_brightness = max torch current, so the rear flash
# briefly lights up during every boot (while Plymouth shows the boot screen).
#
# The stock restore script accepts the state file as $1, so we pass a temporary
# filtered copy.  No file from the Armbian packages is modified; the drop-in
# installed by flash-led/install.sh points this wrapper in as ExecStart.
#
# Environment overrides are for testing only:
#   ELISH_LEDS_CONF     state file    (default /etc/armbian-leds.conf)
#   ELISH_LEDS_RESTORE  stock script  (default /usr/lib/armbian/armbian-led-state-restore.sh)
set -u

CONF=${ELISH_LEDS_CONF:-/etc/armbian-leds.conf}
ORIG=${ELISH_LEDS_RESTORE:-/usr/lib/armbian/armbian-led-state-restore.sh}

# Not Armbian / script missing: nothing to guard, keep the boot silent.
[ -x "$ORIG" ] || exit 0
# No state file (first boot, after upgrade, ...): let the stock script use defaults.
[ -r "$CONF" ] || exec "$ORIG"

TMP=$(mktemp) || exit 0
trap 'rm -f "$TMP"' EXIT

OUT=""
STANZA=""
STANZA_PATH=""

flush_stanza() {
    [ -n "$STANZA" ] || return 0
    # flash-class LED (exposes flash_strobe) = camera flash / torch: never replay
    # its saved state.  Everything else is passed through unchanged.
    if [ ! -e "$STANZA_PATH/flash_strobe" ]; then
        OUT+="$STANZA"
    fi
    STANZA=""
    STANZA_PATH=""
}

while IFS= read -r line || [ -n "$line" ]; do
    if [ "${line#\[}" != "$line" ] && [ "${line%\]}" != "$line" ]; then
        flush_stanza
        STANZA_PATH=${line#\[}
        STANZA_PATH=${STANZA_PATH%\]}
        STANZA="$line"$'\n'
    else
        STANZA+="$line"$'\n'
    fi
done < "$CONF"
flush_stanza

printf '%s' "$OUT" > "$TMP" || exit 0
"$ORIG" "$TMP"
