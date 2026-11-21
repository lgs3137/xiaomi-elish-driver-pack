// 平板模式 — Quick Settings 开关（开 / 关 / 自动）
//
// 平板模式（SW_TABLET_MODE）决定 mutter 是否启用自动旋转：on = 总是平板模式
// （自动旋转开），off = 总是笔记本模式（自动旋转关），auto = 跟随磁吸保护套的
// 霍尔开关。
//
// 这个扩展只是把模式写进 /etc/elish-orientation.conf（该文件由安装脚本设为
// root:<用户组> 0664，普通用户可写，无需每次 sudo）；真正的开关由
// elish-tablet-mode.service（uinput 虚拟开关）在 1 秒内应用。
//
// 状态来源：/etc/elish-orientation.conf（用 elish-camera-ctl orientation 修改也会同步）。

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as QuickSettings from 'resource:///org/gnome/shell/ui/quickSettings.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const CONFIG_PATH = '/etc/elish-orientation.conf';
const CTL = 'elish-camera-ctl';
const TITLE = '平板模式';

// 点击循环顺序：自动 -> 开 -> 关 -> 自动
const MODES = ['auto', 'on', 'off'];
const LABELS = {
    auto: '自动（跟随保护套）',
    on: '开（始终平板模式）',
    off: '关（始终笔记本模式）',
};

function readMode() {
    let mode = 'auto';
    try {
        const [ok, bytes] = Gio.File.new_for_path(CONFIG_PATH).load_contents(null);
        if (!ok)
            return mode;
        const text = new TextDecoder().decode(bytes);
        for (const line of text.split('\n')) {
            const m = /^\s*tablet_mode\s*=\s*(\S+)\s*$/.exec(line);
            if (m)
                mode = m[1];
        }
    } catch (e) {
        // 文件不存在时按 auto 处理
    }
    return MODES.includes(mode) ? mode : 'auto';
}

function nextMode(mode) {
    const i = MODES.indexOf(mode);
    return MODES[(i + 1) % MODES.length];
}

const TabletToggle = GObject.registerClass(
class TabletToggle extends QuickSettings.QuickToggle {
    _init() {
        super._init({title: TITLE});

        this._mode = readMode();
        this._menu = null;
        this._monitorId = 0;
        this._pollId = 0;

        this.connect('clicked', () => this._onClicked());
        this._syncUI();

        // /etc/elish-orientation.conf 可能被 CLI/设置面板修改
        try {
            const file = Gio.File.new_for_path(CONFIG_PATH);
            this._monitor = file.monitor_file(Gio.FileMonitorFlags.NONE, null);
            this._monitorId = this._monitor.connect('changed', () => this._syncFromConfig());
        } catch (e) {
            // 没有 file monitor 时靠下面的轮询
        }
        this._pollId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 5, () => {
            this._syncFromConfig();
            return GLib.SOURCE_CONTINUE;
        });
    }

    _syncFromConfig() {
        const mode = readMode();
        if (mode === this._mode)
            return;
        this._mode = mode;
        this._syncUI();
    }

    _syncUI() {
        const label = LABELS[this._mode] ?? LABELS.auto;
        this.title = `${TITLE}：${label}`;
        // checked 只表示“自动旋转不再被强制关闭”；具体模式看标题
        this.checked = this._mode !== 'off';

        let icon;
        if (this._mode === 'on')
            icon = 'tablet-symbolic';
        else if (this._mode === 'off')
            icon = 'computer-symbolic';
        else
            icon = 'rotation-allowed-symbolic';
        this.gicon = Gio.ThemedIcon.new(icon);
    }

    _onClicked() {
        const target = nextMode(this._mode);
        try {
            GLib.spawn_command_line_async(`${CTL} orientation tablet ${target}`);
        } catch (e) {
            logError(e, 'tablet-mode: failed to run elish-camera-ctl');
            Main.notifyError?.(TITLE, '切换失败：缺少 elish-camera-ctl（安装相机组件）');
            return;
        }
        // 等 helper/脚本写完后同步（同时 file monitor 也会触发）
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 400, () => {
            this._syncFromConfig();
            return GLib.SOURCE_REMOVE;
        });
    }

    destroy() {
        if (this._pollId) {
            GLib.source_remove(this._pollId);
            this._pollId = 0;
        }
        if (this._monitorId) {
            this._monitor.disconnect(this._monitorId);
            this._monitorId = 0;
        }
        if (this._monitor) {
            this._monitor.cancel();
            this._monitor = null;
        }
        super.destroy();
    }
});

const TabletIndicator = GObject.registerClass(
class TabletIndicator extends QuickSettings.SystemIndicator {
    _init() {
        super._init();
        this._toggle = new TabletToggle();
        this.quickSettingsItems.push(this._toggle);
    }

    destroy() {
        this.quickSettingsItems.forEach(item => item.destroy());
        this.quickSettingsItems = [];
        super.destroy();
    }
});

export default class TabletModeExtension extends Extension {
    enable() {
        this._indicator = new TabletIndicator();
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._indicator);
    }

    disable() {
        this._indicator?.destroy();
        this._indicator = null;
    }
}
