// 充电功率 — Quick Settings 实时功率显示（读写 sysfs，不需要 daemon/root）
//
// 数据源：两块 bq27z561 电量计的 current_now(µA) × voltage_now(µV) 求和；
//         状态取 bq27z561-0/status；PD 电压取 tcpm-source-psy 的 voltage_now。
// 显示：充电 20.5W / 放电 8.2W / 已充满；点击打开 设置 → 电源。
// 每 3 秒刷新；扩展是纯用户级、可随时禁用/卸载，不改系统文件。

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as QuickSettings from 'resource:///org/gnome/shell/ui/quickSettings.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const BATS = ['/sys/class/power_supply/bq27z561-0',
              '/sys/class/power_supply/bq27z561-1'];
const STATUS = '/sys/class/power_supply/bq27z561-0/status';
const CAP = '/sys/class/power_supply/bq27z561-0/capacity';
const TITLE = '充电功率';
const ONLINE = '/sys/class/power_supply/pm8150b-charger/online';

function read(path) {
    try {
        const [ok, bytes] = Gio.File.new_for_path(path).load_contents(null);
        if (!ok)
            return null;
        return new TextDecoder().decode(bytes).trim();
    } catch (e) {
        return null;
    }
}

function read_int(path) {
    const v = read(path);
    return v === null ? null : parseInt(v, 10);
}

function battery_power_w() {
    let p = 0;
    for (const b of BATS) {
        const i = read_int(`${b}/current_now`);
        const v = read_int(`${b}/voltage_now`);
        if (i !== null && v !== null)
            p += (i * v) / 1e12;  // µA * µV -> W
    }
    return p;
}

function battery_cap() {
    const c = read_int(CAP);
    return c === null ? -1 : c;
}

function battery_state() {
    return read(STATUS) ?? 'Unknown';
}

function icon_for(cap, charging) {
    const bucket = Math.max(0, Math.min(100, Math.round(cap / 10) * 10));
    if (bucket >= 100 && charging)
        return 'battery-level-100-charged-symbolic';
    return `battery-level-${bucket}${charging ? '-charging' : ''}-symbolic`;
}

const ChargeMeterToggle = GObject.registerClass(
class ChargeMeterToggle extends QuickSettings.QuickToggle {
    _init() {
        super._init({title: TITLE});

        this._timerId = 0;
        this._sync();
        this._timerId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 3, () => {
            this._sync();
            return GLib.SOURCE_CONTINUE;
        });

        // 点击打开 设置 → 电源
        this.connect('clicked', () => {
            try {
                GLib.spawn_command_line_async('gnome-control-center power');
            } catch (e) {
                logError(e, 'charge-meter: failed to open power settings');
            }
        });
    }

    _sync() {
        const cap = battery_cap();
        const state = battery_state();
        const online = (read_int(ONLINE) ?? 0) !== 0;  // SMB5 online 是 USB 类型位掩码（如 16）
        const power = battery_power_w();      // 正=充电，负=放电
        const watts = Math.abs(power);
        const charging = online || state === 'Charging' || state === 'Full';

        // 只要功率可测（>50mW）就显示，不管电量计把状态叫 Charging 还是
        // Not charging（慢充/涓流时电量计常常报 Not charging，之前就不显示 W）。
        let title;
        if (watts >= 0.05) {
            title = power > 0
                ? `充电 ${watts.toFixed(1)}W`
                : `放电 ${watts.toFixed(1)}W`;
        } else if (online && state === 'Full') {
            title = '充电 已充满';
        } else if (online) {
            title = `充电 ${watts.toFixed(1)}W`;
        } else {
            title = `电池 ${cap}%`;
        }

        if (this.title !== title)
            this.title = title;

        // 图标用电池等级 + 充电动画/插头样式
        const icon = icon_for(cap, charging);
        this.gicon = Gio.ThemedIcon.new(icon);

        // checked 只作为视觉强调：充电时为 true
        const checked = charging;
        if (this.checked !== checked)
            this.checked = checked;
    }

    destroy() {
        if (this._timerId) {
            GLib.source_remove(this._timerId);
            this._timerId = 0;
        }
        super.destroy();
    }
});

const ChargeMeterIndicator = GObject.registerClass(
class ChargeMeterIndicator extends QuickSettings.SystemIndicator {
    _init() {
        super._init();
        this._toggle = new ChargeMeterToggle();
        this.quickSettingsItems.push(this._toggle);
    }

    destroy() {
        this.quickSettingsItems.forEach(item => item.destroy());
        this.quickSettingsItems = [];
        super.destroy();
    }
});

export default class ChargeMeterExtension extends Extension {
    enable() {
        this._indicator = new ChargeMeterIndicator();
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._indicator);
    }

    disable() {
        this._indicator?.destroy();
        this._indicator = null;
    }
}
