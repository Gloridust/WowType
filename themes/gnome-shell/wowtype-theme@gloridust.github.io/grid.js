// 展开 6×6 候选面板浮窗：按向下键展开面板时由扩展自绘网格，
// 仅对当前选中的单个候选词使用绿色高亮背景（#0EAF76），避免 kimpanel 整行变绿。
import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Mtk from 'gi://Mtk';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const OBJECT_PATH = '/io/github/gloridust/WowType';
const INTERFACE = 'io.github.gloridust.WowType.Grid1';
const GRID_COLS = 6;
const GRID_ROWS = 6;

const clamp = (v, a, b) => Math.min(b, Math.max(a, v));

export class GridOverlay {
    constructor() {
        this._shown = false;
        this._rect = null;
        this._build();

        this._signalId = Gio.DBus.session.signal_subscribe(
            null, INTERFACE, 'State', OBJECT_PATH, null, Gio.DBusSignalFlags.NONE,
            (_conn, _sender, _path, _iface, _signal, params) => this._onSignal(params));
    }

    destroy() {
        if (this._signalId) {
            Gio.DBus.session.signal_unsubscribe(this._signalId);
            this._signalId = 0;
        }
        this._card.destroy();
    }

    _build() {
        this._card = new St.BoxLayout({
            style_class: 'wowtype-grid-card',
            orientation: Clutter.Orientation.VERTICAL,
            reactive: true,
            visible: false,
        });

        this._header = new St.BoxLayout({
            style_class: 'wowtype-grid-header',
            x_expand: true,
        });
        this._preeditLabel = new St.Label({
            style_class: 'wowtype-grid-preedit',
            x_expand: true,
            y_align: Clutter.ActorAlign.CENTER,
        });
        this._pagerBox = new St.BoxLayout({
            style_class: 'wowtype-grid-pager',
            y_align: Clutter.ActorAlign.CENTER,
        });
        this._prevBtn = new St.Button({
            style_class: 'wowtype-grid-page-btn',
            label: '‹',
            reactive: true,
            can_focus: false,
        });
        this._prevBtn.connect('clicked', () => this._emitAction('prev', 0));
        this._pageLabel = new St.Label({
            style_class: 'wowtype-grid-page-text',
            y_align: Clutter.ActorAlign.CENTER,
        });
        this._nextBtn = new St.Button({
            style_class: 'wowtype-grid-page-btn',
            label: '›',
            reactive: true,
            can_focus: false,
        });
        this._nextBtn.connect('clicked', () => this._emitAction('next', 0));

        this._pagerBox.add_child(this._prevBtn);
        this._pagerBox.add_child(this._pageLabel);
        this._pagerBox.add_child(this._nextBtn);
        this._header.add_child(this._preeditLabel);
        this._header.add_child(this._pagerBox);
        this._card.add_child(this._header);

        this._gridLayout = new Clutter.GridLayout({
            column_spacing: 4,
            row_spacing: 3,
            column_homogeneous: true,
        });
        this._rowsBox = new St.Widget({
            style_class: 'wowtype-grid-rows',
            layout_manager: this._gridLayout,
        });
        this._cells = [];
        for (let r = 0; r < GRID_ROWS; r++) {
            for (let c = 0; c < GRID_COLS; c++) {
                const idx = r * GRID_COLS + c;
                const num = new St.Label({
                    style_class: 'wowtype-grid-num',
                    text: `${c + 1}.`,
                    y_align: Clutter.ActorAlign.CENTER,
                });
                const text = new St.Label({
                    style_class: 'wowtype-grid-text',
                    x_expand: true,
                    x_align: Clutter.ActorAlign.START,
                    y_align: Clutter.ActorAlign.CENTER,
                });
                const inner = new St.BoxLayout({
                    x_expand: true,
                    x_align: Clutter.ActorAlign.FILL,
                });
                inner.add_child(num);
                inner.add_child(text);

                const btn = new St.Button({
                    style_class: 'wowtype-grid-cell',
                    child: inner,
                    x_expand: true,
                    x_align: Clutter.ActorAlign.FILL,
                    reactive: true,
                    can_focus: false,
                    visible: false,
                });
                btn.connect('clicked', () => this._emitAction('select', idx));
                this._gridLayout.attach(btn, c, r, 1, 1);
                this._cells.push({btn, num, text});
            }
        }
        this._card.add_child(this._rowsBox);
        Main.layoutManager.uiGroup.add_child(this._card);
    }

    _emitAck(visible) {
        try {
            Gio.DBus.session.emit_signal(
                null, OBJECT_PATH, INTERFACE, 'Ack',
                new GLib.Variant('(b)', [visible]));
        } catch (_e) {
            // ignore
        }
    }

    _emitAction(kind, index) {
        try {
            Gio.DBus.session.emit_signal(
                null, OBJECT_PATH, INTERFACE, 'Action',
                new GLib.Variant('(si)', [kind, index]));
        } catch (_e) {
            // ignore
        }
    }

    _onSignal(params) {
        const [visible, preedit, aux, items, cursorInPage, cursorRow, page, totalPages, x, y, w, h, rel, scale] =
            params.deepUnpack();

        if (!visible || items.length === 0) {
            this._hide();
            this._emitAck(false);
            return;
        }

        const head = aux ? (preedit ? `${preedit}  ·  ${aux}` : aux) : preedit;
        this._preeditLabel.text = head;
        this._header.visible = Boolean(head || totalPages > 1);
        this._pagerBox.visible = totalPages > 1;
        this._pageLabel.text = `${page + 1}/${Math.max(1, totalPages)}`;
        this._prevBtn.reactive = page > 0;
        this._prevBtn.opacity = page > 0 ? 255 : 90;
        this._nextBtn.reactive = page + 1 < totalPages;
        this._nextBtn.opacity = page + 1 < totalPages ? 255 : 90;

        for (let i = 0; i < GRID_ROWS * GRID_COLS; i++) {
            const cell = this._cells[i];
            if (i < items.length) {
                const r = Math.floor(i / GRID_COLS);
                const c = i % GRID_COLS;
                const active = i === cursorInPage;
                const showNum = r === cursorRow;
                cell.num.opacity = showNum ? 255 : 0;
                cell.text.text = items[i];
                cell.btn.style_class = active
                    ? 'wowtype-grid-cell wowtype-grid-cell-active'
                    : 'wowtype-grid-cell';
                cell.btn.visible = true;
            } else {
                cell.btn.visible = false;
            }
        }

        const rect = this._stageRect(x, y, w, h, rel, scale);
        if (rect)
            this._rect = rect;

        this._shown = true;
        Main.layoutManager.uiGroup.set_child_above_sibling(this._card, null);
        this._card.show();
        this._place();
        this._emitAck(true);
    }

    _hide() {
        if (!this._shown)
            return;
        this._shown = false;
        this._card.hide();
    }

    _stageRect(x, y, w, h, relative, scale) {
        if (!x && !y && !w && !h)
            return null;
        const focus = global.display.focus_window;
        const toStage = r => focus && typeof focus.protocol_to_stage_rect === 'function'
            ? focus.protocol_to_stage_rect(r) : r;
        let rect;
        if (relative && focus) {
            const k = St.ThemeContext.get_for_stage(global.stage).scale_factor / (scale || 1);
            rect = toStage(new Mtk.Rectangle({x: x * k, y: y * k, width: w * k, height: h * k}));
            const actor = focus.get_compositor_private();
            if (actor) {
                rect.x += actor.x;
                rect.y += actor.y;
            }
        } else {
            rect = toStage(new Mtk.Rectangle({x, y, width: w, height: h}));
        }
        return {x: rect.x, y: rect.y, w: rect.width, h: rect.height};
    }

    _place() {
        const [, cardW] = this._card.get_preferred_width(-1);
        const [, cardH] = this._card.get_preferred_height(-1);
        const s = St.ThemeContext.get_for_stage(global.stage).scale_factor;
        const rect = this._rect;
        const monitors = Main.layoutManager.monitors;
        let monitor = Main.layoutManager.primaryMonitor;
        if (rect) {
            const index = global.display.get_monitor_index_for_rect(
                new Mtk.Rectangle({x: rect.x, y: rect.y, width: Math.max(1, rect.w), height: Math.max(1, rect.h)}));
            if (index >= 0 && index < monitors.length)
                monitor = monitors[index];
        }
        if (!monitor)
            return;
        let x, y;
        if (!rect) {
            x = monitor.x + (monitor.width - cardW) / 2;
            y = monitor.y + (monitor.height - cardH) / 2;
        } else {
            x = rect.x;
            y = rect.y + rect.h + 8 * s;
            if (y + cardH > monitor.y + monitor.height)
                y = rect.y - cardH - 8 * s;
        }
        x = Math.round(clamp(x, monitor.x + 8 * s, monitor.x + monitor.width - cardW - 8 * s));
        y = Math.round(clamp(y, monitor.y + 8 * s, monitor.y + monitor.height - cardH - 8 * s));
        this._card.set_position(x, y);
    }
}
