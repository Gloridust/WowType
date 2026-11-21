// 展开面板的网格（#270）：候选框里按下键展开的 6×6 面板。
//
// Input Method Panel（kimpanel）只会画一行或一列，fcitx5 里的 WowType 插件只好把每行 6 个词拼成一项交给它，
// 光标所在的那一行整行涂绿，看不出光标在哪个词上。这个扩展在会话总线上登记 BUS_NAME，插件看到后改为把这一屏的
// 格子发过来（Show 信号），由这里画真正的网格：只有光标处那一格是绿的，鼠标点一格就选它（Select 信号）。
// 这期间插件给 kimpanel 的是一个空列表，它的候选框不画。
//
// 外观照 kimpanel 的候选框：同一套样式类（GNOME 的 popup-menu，深浅色跟着系统；绿色高亮在 stylesheet.css 里），
// 同样挂在光标下面，字体用 kimpanel 设置里的字体。
//
// 每画好一屏回插件一个 Ack；插件等不到回执就退回 kimpanel 画的列表，所以这里画出错时不能回执，
// 错误写进 journal（journalctl --user -b | grep -i wowtype）。
import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Mtk from 'gi://Mtk';
import Pango from 'gi://Pango';
import St from 'gi://St';
import * as BoxPointer from 'resource:///org/gnome/shell/ui/boxpointer.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {stageRect} from './cursor.js';

const BUS_NAME = 'io.github.gloridust.WowType.CandidateGrid';
const OBJECT_PATH = '/io/github/gloridust/WowType';
const INTERFACE = 'io.github.gloridust.WowType.Grid1';

const KIMPANEL_UUID = 'kimpanel@kde.org';
const KIMPANEL_SCHEMA = 'org.gnome.shell.extensions.kimpanel';

const clamp = (v, a, b) => Math.min(b, Math.max(a, v));

// 竖排的盒子。St.BoxLayout 在 GNOME 48 把 vertical 换成了 orientation（45–47 没有 orientation），
// 用 Clutter.BoxLayout 当布局，各个版本都一样
function column(params) {
    return new St.Widget({
        ...params,
        layout_manager: new Clutter.BoxLayout({orientation: Clutter.Orientation.VERTICAL}),
    });
}

export class CandidateGrid {
    constructor() {
        this._serial = 0;         // 正显示的这一屏的编号（点格子时带回去）
        this._sender = null;      // 插件在总线上的唯一名
        this._senderWatch = 0;
        this._shown = false;
        this._cells = [];
        this._fontStyle = '';
        this._kimpanelSettings = null;
        this._kimpanelFontId = 0;

        this._build();
        this._loadKimpanelFont();

        this._showId = Gio.DBus.session.signal_subscribe(
            null, INTERFACE, 'Show', OBJECT_PATH, null, Gio.DBusSignalFlags.NONE,
            (_conn, sender, _path, _iface, _signal, params) => this._onShow(sender, params));
        this._hideId = Gio.DBus.session.signal_subscribe(
            null, INTERFACE, 'Hide', OBJECT_PATH, null, Gio.DBusSignalFlags.NONE,
            (_conn, sender) => {
                if (sender === this._sender)
                    this._hide();
            });
        // 焦点换到别的窗口：插件也会叫收起，这里先收，免得留在屏幕上
        this._focusId = global.display.connect('notify::focus-window', () => this._hide());
        this._nameId = Gio.bus_own_name(
            Gio.BusType.SESSION, BUS_NAME, Gio.BusNameOwnerFlags.NONE, null, null, null);
    }

    destroy() {
        if (this._nameId) {
            Gio.bus_unown_name(this._nameId);
            this._nameId = 0;
        }
        for (const id of [this._showId, this._hideId]) {
            if (id)
                Gio.DBus.session.signal_unsubscribe(id);
        }
        this._showId = this._hideId = 0;
        if (this._focusId) {
            global.display.disconnect(this._focusId);
            this._focusId = 0;
        }
        this._watchSender(null);
        if (this._kimpanelFontId) {
            this._kimpanelSettings.disconnect(this._kimpanelFontId);
            this._kimpanelFontId = 0;
        }
        this._kimpanelSettings = null;
        Main.layoutManager.removeChrome(this._box);
        this._box.destroy();
        this._anchor.destroy();
        this._cells = [];
    }

    // ── 控件 ────────────────────────────────────────────────────────────
    // 和 kimpanel 的候选框一样：BoxPointer + popup-menu 的样式类，深浅色、圆角、阴影都跟着 GNOME 的主题走
    _build() {
        this._anchor = new St.Widget({reactive: false});   // 光标矩形，网格挂在它下面
        this._box = new BoxPointer.BoxPointer(St.Side.TOP, {x_align: Clutter.ActorAlign.START});
        this._box.style_class = 'popup-menu-boxpointer';
        for (const name of ['popup-menu', 'minwidth-zero', 'kimpanel-popup-boxpointer', 'wowtype-grid-boxpointer'])
            this._box.add_style_class_name(name);

        this._content = column({style_class: 'popup-menu-content kimpanel-popup-content wowtype-grid-content'});
        this._header = new St.Label({style_class: 'kimpanel-label wowtype-grid-header', visible: false});
        this._layout = new Clutter.GridLayout({column_spacing: 0, row_spacing: 0});
        this._grid = new St.Widget({style_class: 'wowtype-grid', layout_manager: this._layout});
        this._page = new St.Label({
            style_class: 'wowtype-grid-page',
            x_align: Clutter.ActorAlign.END,
            visible: false,
        });
        this._content.add_child(this._header);
        this._content.add_child(this._grid);
        this._content.add_child(this._page);
        this._box.bin.set_child(this._content);

        // addChrome：X11 下点得到（输入区域），和 kimpanel 一样
        Main.layoutManager.addChrome(this._box, {});
        Main.uiGroup.add_child(this._anchor);
        this._box.hide();
    }

    // 第 i 格（行优先，按需要建）
    _cell(i, cols) {
        while (this._cells.length <= i) {
            const cell = new St.BoxLayout({
                style_class: 'popup-menu-item kimpanel-label kimpanel-candidate-item wowtype-grid-cell',
                reactive: true,
                track_hover: true,
            });
            cell._label = new St.Label({style_class: 'wowtype-grid-label', y_align: Clutter.ActorAlign.CENTER});
            cell._text = new St.Label({style_class: 'wowtype-grid-text', y_align: Clutter.ActorAlign.CENTER});
            cell.add_child(cell._label);
            cell.add_child(cell._text);
            cell._index = -1;
            cell.connect('button-release-event', (actor, event) => {
                if (event.get_button() === Clutter.BUTTON_PRIMARY)
                    this._select(actor._index);
                return Clutter.EVENT_STOP;
            });
            this._cells.push(cell);
        }
        const cell = this._cells[i];
        if (cell._cols !== cols) {
            // 列数变了（插件只发 6 列，留着以防万一）：重新排
            if (cell.get_parent())
                this._grid.remove_child(cell);
            this._layout.attach(cell, i % cols, Math.floor(i / cols), 1, 1);
            cell._cols = cols;
        }
        return cell;
    }

    // ── 信号 ────────────────────────────────────────────────────────────
    _onShow(sender, params) {
        let serial = 0;
        try {
            const args = params.deepUnpack();
            serial = args[0];
            this._watchSender(sender);
            this._update(args);
        } catch (e) {
            console.error(`WowType 展开面板的网格画不出来（第 ${serial} 屏）：`, e);
            this._hide();
            return;
        }
        if (!this._box.visible)
            return;
        try {
            Gio.DBus.session.emit_signal(sender, OBJECT_PATH, INTERFACE, 'Ack',
                new GLib.Variant('(u)', [serial]));
        } catch (e) {
            console.error('WowType 展开面板的网格回执发不出去：', e);
        }
    }

    _select(index) {
        if (!this._shown || !this._sender || index < 0)
            return;
        try {
            Gio.DBus.session.emit_signal(this._sender, OBJECT_PATH, INTERFACE, 'Select',
                new GLib.Variant('(uu)', [this._serial, index]));
        } catch (e) {
            console.error('WowType 展开面板选词发不出去：', e);
        }
    }

    // 插件退出、崩溃时自己收起
    _watchSender(sender) {
        if (sender === this._sender && (this._senderWatch || !sender))
            return;
        if (this._senderWatch) {
            Gio.bus_unwatch_name(this._senderWatch);
            this._senderWatch = 0;
        }
        this._sender = sender;
        if (sender) {
            this._senderWatch = Gio.bus_watch_name_on_connection(
                Gio.DBus.session, sender, Gio.BusNameWatcherFlags.NONE, null, () => this._hide());
        }
    }

    _update([serial, cells, first, cursor, cols, page, pages, header, x, y, w, h, relative, scale]) {
        cols = Math.max(1, cols);
        this._serial = serial;
        this._header.text = header || '';
        this._header.visible = !!header;
        this._page.text = `${page + 1}/${pages}`;
        this._page.visible = pages > 1;

        const cursorRow = Math.floor((cursor - first) / cols);
        for (let i = 0; i < Math.max(cells.length, this._cells.length); i++) {
            if (i >= cells.length) {
                this._cells[i].hide();
                continue;
            }
            const cell = this._cell(i, cols);
            const row = Math.floor(i / cols);
            cell._index = first + i;
            // 光标所在的那一行标 1–6（数字选这一行），别的行留出同样的宽度，上下对齐
            cell._label.text = `${i % cols + 1}`;
            cell._label.opacity = row === cursorRow ? 255 : 0;
            cell._text.text = cells[i];
            cell.set_style(this._fontStyle || null);
            if (first + i === cursor)
                cell.add_style_pseudo_class('active');
            else
                cell.remove_style_pseudo_class('active');
            cell.show();
        }
        this._header.set_style(this._fontStyle || null);

        this._place(stageRect(x, y, w, h, relative, scale));
    }

    // ── 位置：照 kimpanel 的 updatePosition ────────────────────────────────
    _place(rect) {
        const w = rect.w;
        let {x, y, h} = rect;
        if (h === 0) {
            h = 20;
            y -= 20;
        }
        const monitor = this._monitorFor({x, y, w, h});
        if (monitor) {
            if (y + h >= monitor.y + monitor.height) {
                y = monitor.y + monitor.height - 1;
                h = 1;
            }
            x = clamp(x, monitor.x, monitor.x + monitor.width - 1);
        }
        this._anchor.set_position(Math.round(x), Math.round(y));
        this._anchor.set_size(Math.max(1, Math.round(w)), Math.max(1, Math.round(h)));
        // 放不下时 BoxPointer 自己翻到光标上面、挪进屏幕里
        this._box.setPosition(this._anchor, 0.0);
        if (!this._box.visible)
            this._box.open(BoxPointer.PopupAnimation.NONE);
        this._box.get_parent()?.set_child_above_sibling(this._box, null);
        this._shown = true;
    }

    _monitorFor(rect) {
        const monitors = Main.layoutManager.monitors;
        const index = global.display.get_monitor_index_for_rect(
            new Mtk.Rectangle({
                x: Math.round(rect.x), y: Math.round(rect.y),
                width: Math.max(1, Math.round(rect.w)), height: Math.max(1, Math.round(rect.h)),
            }));
        if (index >= 0 && index < monitors.length)
            return monitors[index];
        return Main.layoutManager.primaryMonitor;
    }

    _hide() {
        if (!this._shown)
            return;
        this._shown = false;
        this._box.close(BoxPointer.PopupAnimation.NONE);
        for (const cell of this._cells)
            cell.remove_style_pseudo_class('hover');
    }

    // ── 字体：和 kimpanel 候选框一样（它设置里的「字体」，默认 Sans 11）────────────
    _loadKimpanelFont() {
        try {
            let schema = Gio.SettingsSchemaSource.get_default()?.lookup(KIMPANEL_SCHEMA, true) ?? null;
            if (!schema) {
                const dir = Main.extensionManager.lookup(KIMPANEL_UUID)?.dir?.get_child('schemas');
                if (dir?.query_exists(null)) {
                    const source = Gio.SettingsSchemaSource.new_from_directory(
                        dir.get_path(), Gio.SettingsSchemaSource.get_default(), false);
                    schema = source.lookup(KIMPANEL_SCHEMA, false);
                }
            }
            if (!schema || !schema.has_key('font'))
                return;
            this._kimpanelSettings = new Gio.Settings({settings_schema: schema});
            this._kimpanelFontId = this._kimpanelSettings.connect('changed::font', () => this._readFont());
            this._readFont();
        } catch (e) {
            console.warn('WowType 展开面板读不到 Input Method Panel 的字体，用主题的：', e);
        }
    }

    _readFont() {
        const desc = Pango.FontDescription.from_string(this._kimpanelSettings.get_string('font') || 'Sans 11');
        const parts = [];
        const family = desc.get_family();
        if (family)
            parts.push(`font-family: '${family.replace(/'/g, '')}'`);
        if (desc.get_size() > 0)
            parts.push(`font-size: ${desc.get_size() / Pango.SCALE}pt`);
        const style = {[Pango.Style.ITALIC]: 'italic', [Pango.Style.OBLIQUE]: 'oblique'}[desc.get_style()];
        if (style)
            parts.push(`font-style: ${style}`);
        try {
            const weight = desc.get_weight();
            if (weight !== Pango.Weight.NORMAL)
                parts.push(`font-weight: ${weight}`);
        } catch {
            // 和 kimpanel 一样：权重不在枚举里时不管它
        }
        this._fontStyle = parts.join('; ');
    }
}
