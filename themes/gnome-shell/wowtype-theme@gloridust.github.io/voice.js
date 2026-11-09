// 语音浮条：按住语音键说话时，在光标下面画一条白色浮条——
// 左边绿色话筒（外圈跟着音量呼吸）、「正在听… 离线」、右边 24 根跟着真实音量跳的竖条；
// 光标右边再画 5 根绿色竖条，像光标裂成了声波。
//
// 数据来自 fcitx5 里的 WowType 插件：插件发现这个扩展注册了 BUS_NAME，就不再在候选框里
// 写文字提示，改为每 50 毫秒发一次 State 信号（状态、文字、音量、光标矩形）。
import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Mtk from 'gi://Mtk';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const BUS_NAME = 'io.github.gloridust.WowType.VoiceOverlay';
const OBJECT_PATH = '/io/github/gloridust/WowType';
const INTERFACE = 'io.github.gloridust.WowType.Voice1';

const STATE_HIDE = 0;
const STATE_LISTENING = 1;
const STATE_RECOGNIZING = 2;
const STATE_DONE = 3;
const STATE_ERROR = 4;

const GREEN = [14 / 255, 175 / 255, 118 / 255];

// 浮条里的尺寸（逻辑像素，跟着 GNOME 的缩放走）
const MIC_SIZE = 46;          // 话筒那块的宽高
const MIC_R = 15;             // 绿圆半径
const HALO_R0 = 16;           // 光晕半径：安静时
const HALO_R1 = 22.5;         //           大声时
const BAR_COUNT = 24;
const BAR_W = 3;
const BAR_PITCH = 5.5;
const BAR_MIN = 4;
const BAR_MAX = 30;
const BARS_W = (BAR_COUNT - 1) * BAR_PITCH + BAR_W;
const BARS_H = 34;

const POP_MS = 320;           // 弹出
const HIDE_MS = 250;          // 淡出
const DONE_HOLD_MS = 350;     // 「识别完成」停留
const CARET_MS = 200;         // 光标变声波 / 收回
const STALE_US = 1500 * 1000; // 这么久没收到信号（插件没了）就收起

const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
const mix = (a, b, k) => a + (b - a) * k;
const follow = (cur, target, rate, dt) => cur + (target - cur) * (1 - Math.exp(-rate * dt));

// 插件给的音量 0–100（-60 dB 到 -10 dB），安静房间大概 20 以下。
// 说话时整体在 0.5–1 之间，乘个增益让波形像宣传片里那样站得起来。
const levelToVoice = level => clamp(1.6 * Math.pow(clamp((level - 20) / 60, 0, 1), 0.9), 0, 1);

function roundedRect(cr, x, y, w, h, r) {
    r = Math.min(r, w / 2, h / 2);
    cr.newSubPath();
    cr.arc(x + w - r, y + r, r, -Math.PI / 2, 0);
    cr.arc(x + w - r, y + h - r, r, 0, Math.PI / 2);
    cr.arc(x + r, y + h - r, r, Math.PI / 2, Math.PI);
    cr.arc(x + r, y + r, r, Math.PI, 1.5 * Math.PI);
    cr.closePath();
}

export class VoiceOverlay {
    constructor() {
        this._state = STATE_HIDE;
        this._shown = false;
        this._hiding = false;
        this._level = 0;          // 平滑后的音量 0–1
        this._levelTarget = 0;
        this._bars = new Array(BAR_COUNT).fill(0);
        this._caretK = 0;         // 光标变声波的程度 0–1
        this._caretOn = false;
        this._caretBars = [0, 0, 0, 0, 0];
        this._rect = null;        // 光标矩形（舞台坐标）
        this._anchorX = null;     // 浮条左边：开始说话时定下，光标走远了才跟着挪
        this._lastSignal = 0;
        this._lastFrame = 0;
        this._t = 0;
        this._hideTimeout = 0;

        this._build();

        this._timeline = new Clutter.Timeline({actor: global.stage, duration: 1000, repeat_count: -1});
        this._timeline.connect('new-frame', () => this._tick());
        // GNOME Shell 退出时不会先停用扩展，舞台直接销毁这些控件
        this._pill.connect('destroy', () => this._timeline?.stop());

        this._signalId = Gio.DBus.session.signal_subscribe(
            null, INTERFACE, 'State', OBJECT_PATH, null, Gio.DBusSignalFlags.NONE,
            (_conn, _sender, _path, _iface, _signal, params) => this._onState(params.deepUnpack()));
        this._nameId = Gio.bus_own_name(
            Gio.BusType.SESSION, BUS_NAME, Gio.BusNameOwnerFlags.NONE, null, null, null);
    }

    destroy() {
        if (this._nameId) {
            Gio.bus_unown_name(this._nameId);
            this._nameId = 0;
        }
        if (this._signalId) {
            Gio.DBus.session.signal_unsubscribe(this._signalId);
            this._signalId = 0;
        }
        if (this._hideTimeout) {
            GLib.source_remove(this._hideTimeout);
            this._hideTimeout = 0;
        }
        this._timeline.stop();
        this._pill.destroy();
        this._timeline = null;
        this._caret.destroy();
    }

    _build() {
        this._pill = new St.BoxLayout({
            style_class: 'wowtype-voice-pill',
            reactive: false,
            visible: false,
            opacity: 0,
        });
        this._pill.set_pivot_point(0.12, 0.5);

        this._mic = new St.DrawingArea({style_class: 'wowtype-voice-mic', y_align: Clutter.ActorAlign.CENTER});
        this._mic.connect('repaint', area => this._paintMic(area));
        this._pill.add_child(this._mic);

        this._label = new St.Label({
            style_class: 'wowtype-voice-label',
            text: '正在听…',
            y_align: Clutter.ActorAlign.CENTER,
        });
        this._pill.add_child(this._label);

        this._tag = new St.Label({
            style_class: 'wowtype-voice-tag',
            text: '离线',
            y_align: Clutter.ActorAlign.CENTER,
        });
        this._pill.add_child(this._tag);

        this._wave = new St.DrawingArea({style_class: 'wowtype-voice-wave', y_align: Clutter.ActorAlign.CENTER});
        this._wave.connect('repaint', area => this._paintWave(area));
        this._pill.add_child(this._wave);

        this._caret = new St.DrawingArea({reactive: false, visible: false});
        this._caret.connect('repaint', area => this._paintCaret(area));

        // 放在窗口上面、通知和菜单下面
        Main.layoutManager.uiGroup.add_child(this._caret);
        Main.layoutManager.uiGroup.add_child(this._pill);
    }

    // ── 信号 ────────────────────────────────────────────────────────────
    _onState([state, label, level, x, y, w, h, relative, scale]) {
        this._lastSignal = GLib.get_monotonic_time();
        if (state === STATE_HIDE) {
            if (this._state !== STATE_DONE)
                this._hide(0);
            return;
        }
        const rect = this._stageRect(x, y, w, h, relative, scale);
        if (rect)
            this._rect = rect;

        this._state = state;
        this._label.text = label || '';
        this._label.remove_style_class_name('wowtype-voice-error');
        if (state === STATE_ERROR)
            this._label.add_style_class_name('wowtype-voice-error');
        this._tag.visible = state !== STATE_ERROR;

        if (state === STATE_LISTENING) {
            this._levelTarget = levelToVoice(level);
            this._caretOn = true;
        } else {
            this._levelTarget = 0;
            this._caretOn = false;
        }

        this._show();
        this._place(false);
        if (state === STATE_DONE)
            this._hide(DONE_HOLD_MS);
    }

    // 光标矩形换成舞台坐标，算法和 Input Method Panel 扩展一样。
    _stageRect(x, y, w, h, relative, scale) {
        if (!x && !y && !w && !h)
            return null;
        const focus = global.display.focus_window;
        let rect;
        if (relative && focus) {
            const k = St.ThemeContext.get_for_stage(global.stage).scale_factor / (scale || 1);
            rect = new Mtk.Rectangle({x: x * k, y: y * k, width: w * k, height: h * k});
            rect = focus.protocol_to_stage_rect(rect);
            const actor = focus.get_compositor_private();
            if (actor) {
                rect.x += actor.x;
                rect.y += actor.y;
            }
        } else {
            rect = new Mtk.Rectangle({x, y, width: w, height: h});
            if (focus)
                rect = focus.protocol_to_stage_rect(rect);
        }
        return {x: rect.x, y: rect.y, w: rect.width, h: rect.height};
    }

    // ── 出现 / 收起 ──────────────────────────────────────────────────────
    _show() {
        if (this._hideTimeout) {
            GLib.source_remove(this._hideTimeout);
            this._hideTimeout = 0;
        }
        if (this._shown && !this._hiding)
            return;
        const fresh = !this._shown;
        this._shown = true;
        this._hiding = false;
        this._pill.remove_all_transitions();
        if (fresh) {
            this._anchorX = null;
            this._bars.fill(0);
            this._level = 0;
            this._caretK = 0;
            this._caretBars.fill(0);
            this._place(true);
            this._pill.opacity = 0;
            this._pill.translation_y = 8;
            this._pill.scale_x = this._pill.scale_y = 0.94;
        }
        Main.layoutManager.uiGroup.set_child_above_sibling(this._caret, null);
        Main.layoutManager.uiGroup.set_child_above_sibling(this._pill, null);
        this._pill.show();
        this._pill.ease({
            opacity: 255,
            translation_y: 0,
            scale_x: 1,
            scale_y: 1,
            duration: POP_MS,
            mode: Clutter.AnimationMode.EASE_OUT_BACK,
        });
        this._lastFrame = 0;
        this._timeline.start();
    }

    _hide(delayMs) {
        this._caretOn = false;
        if (!this._shown || this._hiding)
            return;
        if (delayMs > 0) {
            if (!this._hideTimeout) {
                this._hideTimeout = GLib.timeout_add(GLib.PRIORITY_DEFAULT, delayMs, () => {
                    this._hideTimeout = 0;
                    this._hide(0);
                    return GLib.SOURCE_REMOVE;
                });
            }
            return;
        }
        this._hiding = true;
        this._state = STATE_HIDE;
        this._pill.remove_all_transitions();
        this._pill.ease({
            opacity: 0,
            translation_y: 6,
            duration: HIDE_MS,
            mode: Clutter.AnimationMode.EASE_IN_QUAD,
            onStopped: finished => {
                if (!finished || !this._hiding)
                    return;
                this._hiding = false;
                this._shown = false;
                this._pill.hide();
                if (this._caretK <= 0.001)
                    this._stop();
            },
        });
    }

    _stop() {
        this._timeline.stop();
        this._caret.hide();
    }

    // ── 位置 ────────────────────────────────────────────────────────────
    _scale() {
        return St.ThemeContext.get_for_stage(global.stage).scale_factor;
    }

    _monitorFor(rect) {
        const monitors = Main.layoutManager.monitors;
        if (rect) {
            const index = global.display.get_monitor_index_for_rect(
                new Mtk.Rectangle({x: rect.x, y: rect.y, width: Math.max(1, rect.w), height: Math.max(1, rect.h)}));
            if (index >= 0 && index < monitors.length)
                return monitors[index];
        }
        return Main.layoutManager.primaryMonitor;
    }

    _place(immediate) {
        const [, pillW] = this._pill.get_preferred_width(-1);
        const [, pillH] = this._pill.get_preferred_height(-1);
        const s = this._scale();
        const rect = this._rect;
        const monitor = this._monitorFor(rect);
        if (!monitor)
            return;
        let x, y;
        if (!rect) {
            // 应用没给光标位置：放在屏幕下方正中
            x = monitor.x + (monitor.width - pillW) / 2;
            y = monitor.y + monitor.height - pillH - 96 * s;
        } else {
            // 左边先对着开始说话时的光标；字多了光标往右走，浮条才跟着挪（光标落在浮条约 2/3 处）
            const start = rect.x - 10 * s;
            if (this._anchorX === null || rect.x < this._anchorX)
                this._anchorX = start;
            this._anchorX = Math.max(this._anchorX, rect.x - pillW * 0.66);
            x = this._anchorX;
            y = rect.y + rect.h + 10 * s;
            if (y + pillH > monitor.y + monitor.height)
                y = rect.y - pillH - 10 * s;
        }
        x = clamp(x, monitor.x + 8 * s, monitor.x + monitor.width - pillW - 8 * s);
        y = clamp(y, monitor.y + 8 * s, monitor.y + monitor.height - pillH - 8 * s);
        x = Math.round(x);
        y = Math.round(y);
        if (immediate || !this._pill.visible) {
            this._pill.set_position(x, y);
        } else if (x !== this._pill.x || y !== this._pill.y) {
            this._pill.ease({x, y, duration: 160, mode: Clutter.AnimationMode.EASE_OUT_QUAD});
        }
    }

    // ── 每帧 ────────────────────────────────────────────────────────────
    _tick() {
        const now = GLib.get_monotonic_time();
        const dt = this._lastFrame ? Math.min(0.1, (now - this._lastFrame) / 1e6) : 1 / 60;
        this._lastFrame = now;
        this._t += dt;

        // 插件没了（fcitx5 退出、崩溃）就自己收起
        if (this._shown && !this._hiding && this._state !== STATE_DONE &&
            now - this._lastSignal > STALE_US)
            this._hide(0);

        this._level = follow(this._level, this._levelTarget, this._levelTarget > this._level ? 18 : 5, dt);
        for (let i = 0; i < BAR_COUNT; i++)
            this._bars[i] = follow(this._bars[i], this._barTarget(i), 16, dt);

        const caretTarget = this._caretOn && this._rect && this._rect.h > 0 ? 1 : 0;
        const step = dt * 1000 / CARET_MS;
        this._caretK = caretTarget > this._caretK
            ? Math.min(1, this._caretK + step) : Math.max(0, this._caretK - step);
        const factors = [0.55, 0.8, 1, 0.8, 0.55];
        for (let i = 0; i < 5; i++) {
            const wobble = 0.35 + 0.65 * Math.abs(Math.sin(2 * Math.PI * (2.1 + 0.37 * i) * this._t + i * 1.9));
            const target = this._level * (0.3 + 0.7 * wobble) * factors[i];
            this._caretBars[i] = follow(this._caretBars[i], target, 14, dt);
        }

        this._mic.queue_repaint();
        this._wave.queue_repaint();
        this._updateCaret();

        if (!this._shown && this._caretK <= 0.001)
            this._stop();
    }

    // 第 i 根竖条该有多高（0–1）：真实音量乘上一道从左往右走的起伏（照宣传片），安静时全部矮下去
    _barTarget(i) {
        const t = this._t;
        if (this._state === STATE_RECOGNIZING)
            return 0.12 * Math.max(0, Math.sin(t * 7 - i * 0.45));   // 识别中：一道矮矮的波走过去
        if (this._state !== STATE_LISTENING)
            return 0;
        const syl = 0.5 + 0.5 * Math.sin(2 * Math.PI * 3.1 * t - i * 0.35 + 0.8 * Math.sin(2 * Math.PI * 0.8 * t));
        const v = 0.3 + 0.7 * Math.abs(Math.sin(2 * Math.PI * (1.7 + 0.23 * i) * t + i * 2.1));
        return this._level * (0.25 + 0.75 * syl) * v;
    }

    // ── 画 ──────────────────────────────────────────────────────────────
    _paintMic(area) {
        const cr = area.get_context();
        const [, h] = area.get_surface_size();
        const k = h / MIC_SIZE;
        cr.scale(k, k);
        const cx = MIC_SIZE / 2, cy = MIC_SIZE / 2;
        // 光晕：说话越大声越大
        cr.setSourceRGBA(...GREEN, 0.16);
        cr.arc(cx, cy, mix(HALO_R0, HALO_R1, this._level), 0, 2 * Math.PI);
        cr.fill();
        cr.setSourceRGBA(...GREEN, 1);
        cr.arc(cx, cy, MIC_R, 0, 2 * Math.PI);
        cr.fill();
        // 白色话筒：头、托、柄
        cr.setSourceRGBA(1, 1, 1, 1);
        roundedRect(cr, cx - 3.2, cy - 8.2, 6.4, 10.8, 3.2);
        cr.fill();
        cr.setLineWidth(1.6);
        cr.setLineCap(1); // ROUND
        cr.arc(cx, cy - 1.4, 5.4, 0.15 * Math.PI, 0.85 * Math.PI);
        cr.stroke();
        cr.moveTo(cx, cy + 4);
        cr.lineTo(cx, cy + 7.2);
        cr.stroke();
        cr.$dispose();
    }

    _paintWave(area) {
        const cr = area.get_context();
        const [, h] = area.get_surface_size();
        const k = h / BARS_H;
        cr.scale(k, k);
        const env = this._state === STATE_LISTENING ? this._level : 0;
        cr.setSourceRGBA(...GREEN, 0.55 + 0.45 * env);
        for (let i = 0; i < BAR_COUNT; i++) {
            const bh = mix(BAR_MIN, BAR_MAX, clamp(this._bars[i], 0, 1));
            roundedRect(cr, i * BAR_PITCH, (BARS_H - bh) / 2, BAR_W, bh, BAR_W / 2);
        }
        cr.fill();
        cr.$dispose();
    }

    // 光标右边的 5 根竖条：按下语音键 0.2 秒内从一根光标长成声波，松开 0.2 秒收回
    _updateCaret() {
        const rect = this._rect;
        if (this._caretK <= 0.001 || !rect || rect.h <= 0) {
            this._caret.hide();
            return;
        }
        const ch = rect.h;
        const s = this._scale();
        const barW = Math.max(2 * s, Math.round(ch * 0.1));
        const pitch = barW + Math.max(2 * s, Math.round(ch * 0.14));
        const gap = Math.max(3 * s, ch * 0.18);
        const width = Math.ceil(gap + 5 * pitch + barW);
        const height = Math.ceil(ch * 1.6);
        this._caretGeom = {ch, barW, pitch, gap};
        this._caret.set_size(width, height);
        // 左边对着光标：收回时竖条正好合进光标里
        this._caret.set_position(Math.round(rect.x), Math.round(rect.y + ch / 2 - height / 2));
        this._caret.opacity = Math.round(255 * this._caretK);
        if (!this._caret.visible)
            this._caret.show();
        this._caret.queue_repaint();
    }

    _paintCaret(area) {
        const g = this._caretGeom;
        if (!g)
            return;
        const cr = area.get_context();
        const [, h] = area.get_surface_size();
        const kS = this._caretK;
        cr.setSourceRGBA(...GREEN, 1);
        for (let i = 0; i < 5; i++) {
            const full = g.ch * mix(0.3, 1.55, clamp(this._caretBars[i], 0, 1));
            const bh = mix(g.ch, full, kS);
            const x = (g.gap + 2 * g.pitch) * kS + (i - 2) * g.pitch * kS;
            roundedRect(cr, x, (h - bh) / 2, g.barW, bh, g.barW / 2);
        }
        cr.fill();
        cr.$dispose();
    }
}
