// Torch helper: control the rear camera flash LED (torch mode) without root.
//
// The LED class device is `/sys/class/leds/white:flash` (mainline
// `leds-qcom-flash`, PM8150L).  Unprivileged brightness writes are done
// through systemd-logind's Session.SetBrightness("leds", <name>, <0..255>),
// which is the same interface GNOME's upstream flashlight draft uses (and
// Phosh / upstream brightnessctl).  It deliberately refuses non-foreground
// sessions, so it also acts as a safety gate.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

export const LED_NAME = 'white:flash';

// 1..255 (255 = max torch current, 200 mA on this device); 128 is bright
// enough for use as a torch and gentler on the LED/battery.
export const TORCH_LEVEL = 128;

const LOGIN_DEST = 'org.freedesktop.login1';
const LOGIN_PATH = '/org/freedesktop/login1/session/auto';
const LOGIN_IFACE = 'org.freedesktop.login1.Session';
const SYSFS_PATH = `/sys/class/leds/${LED_NAME}/brightness`;

/** @returns {number} current torch brightness, 0 when off/unknown */
export function readBrightness() {
    try {
        const [, bytes] = GLib.file_get_contents(SYSFS_PATH);
        const value = parseInt(new TextDecoder().decode(bytes).trim(), 10);
        return Number.isFinite(value) ? value : 0;
    } catch (e) {
        logError(e, `torch: cannot read ${SYSFS_PATH}`);
        return 0;
    }
}

/**
 * Set the torch brightness (0 = off, 1..255 = on).
 * @param {number} value
 * @returns {Promise<void>}
 */
export function setBrightness(value) {
    return new Promise((resolve, reject) => {
        Gio.DBus.system.call(
            LOGIN_DEST,
            LOGIN_PATH,
            LOGIN_IFACE,
            'SetBrightness',
            new GLib.Variant('(ssu)', ['leds', LED_NAME, value]),
            null,
            Gio.DBusCallFlags.NONE,
            -1,
            null,
            (connection, res) => {
                try {
                    connection.call_finish(res);
                    resolve();
                } catch (e) {
                    reject(e);
                }
            });
    });
}
