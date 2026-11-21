// Torch — a Quick Settings toggle for the rear camera flash LED.
//
// GNOME Shell 46 has no built-in flashlight toggle (the upstream feature is
// still an unmerged draft), so this adds one to the Quick Settings grid:
// it reads the sysfs brightness to show the current state and writes through
// systemd-logind's Session.SetBrightness (no root required).

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as QuickSettings from 'resource:///org/gnome/shell/ui/quickSettings.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {TORCH_LEVEL, readBrightness, setBrightness} from './torch.js';

const AUTO_OFF_SECONDS = 5 * 60;
const TITLE = '手电筒';

const TorchToggle = GObject.registerClass(
class TorchToggle extends QuickSettings.QuickToggle {
    _init(iconsDir) {
        // St.Button does not toggle `checked` by itself (toggleMode is off),
        // so a click always means "flip the hardware state" and we then sync
        // `checked` from what the kernel/logind actually did.
        super._init({
            title: TITLE,
        });

        this._iconsDir = iconsDir;
        this._autoOffId = 0;
        this._inFlight = false;

        // GNOME 46 的 Quick Settings 弹出层始终是深色背景，白色图标才可见。
        // （之前按 gtk-theme-variant 判断，浅色 GTK 主题下会选黑图标，导致看不见。）
        this._syncIcon();
        this._syncFromSysfs();

        this.connect('clicked', () => this._onClicked());
    }

    _syncIcon() {
        this.gicon = Gio.icon_new_for_string(
            this._iconsDir.get_child('torch-white.svg').get_path());
    }

    _startAutoOff() {
        if (this._autoOffId)
            return;
        this._autoOffId = GLib.timeout_add_seconds(
            GLib.PRIORITY_DEFAULT,
            AUTO_OFF_SECONDS,
            () => {
                this._autoOffId = 0;
                this._write(0);
                return GLib.SOURCE_REMOVE;
            });
    }

    _clearAutoOff() {
        if (this._autoOffId) {
            GLib.source_remove(this._autoOffId);
            this._autoOffId = 0;
        }
    }

    _syncFromSysfs() {
        const on = readBrightness() > 0;
        if (this.checked !== on)
            this.checked = on;
        if (on)
            this._startAutoOff();
        else
            this._clearAutoOff();
    }

    sync() {
        this._syncFromSysfs();
    }

    _onClicked() {
        if (this._inFlight)
            return;
        this._write(!this.checked ? TORCH_LEVEL : 0);
    }

    _write(value) {
        if (this._inFlight)
            return;
        this._inFlight = true;
        setBrightness(value)
            .then(() => {
                this._inFlight = false;
                this._syncFromSysfs();
            })
            .catch(e => {
                this._inFlight = false;
                logError(e, 'torch: Session.SetBrightness failed');
                // Revert the visual state to the actual hardware state.
                this._syncFromSysfs();
                Main.notifyError?.(TITLE, '设置失败（logind 拒绝或设备忙）');
            });
    }

    destroy() {
        this._clearAutoOff();
        super.destroy();
    }
});

const TorchIndicator = GObject.registerClass(
class TorchIndicator extends QuickSettings.SystemIndicator {
    _init(iconsDir) {
        super._init();
        this._toggle = new TorchToggle(iconsDir);
        this.quickSettingsItems.push(this._toggle);
    }

    sync() {
        this._toggle.sync();
    }

    destroy() {
        this.quickSettingsItems.forEach(item => item.destroy());
        this.quickSettingsItems = [];
        super.destroy();
    }
});

export default class TorchExtension extends Extension {
    enable() {
        this._indicator = new TorchIndicator(this.dir.get_child('icons'));
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._indicator);

        // Another process may have changed the torch (e.g. /usr/local/bin/torch,
        // or the auto-off timer of a previous session): refresh on menu open.
        this._menu = Main.panel.statusArea.quickSettings.menu;
        this._menuOpenId = this._menu.connect('open-state-changed',
            (menu, isOpen) => {
                if (isOpen)
                    this._indicator.sync();
            });
    }

    disable() {
        if (this._menuOpenId) {
            this._menu.disconnect(this._menuOpenId);
            this._menuOpenId = 0;
        }
        this._menu = null;

        this._indicator?.destroy();
        this._indicator = null;
    }
}
