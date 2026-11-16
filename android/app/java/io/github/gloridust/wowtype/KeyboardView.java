package io.github.gloridust.wowtype;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.os.Handler;
import android.os.Looper;
import android.view.HapticFeedbackConstants;
import android.view.MotionEvent;
import android.view.View;

import java.util.ArrayList;
import java.util.List;

/**
 * 软键盘：四行 QWERTY，字母、Shift、退格、空格、回车、逗号句号，右上角一个中/英切换。
 *
 * 只负责画和收触摸，按键往上交给 {@link WowTypeImeService}：字母 / 数字 / 标点报 keysym，
 * 退格、回车、空格也报 keysym（会话自己决定是选词还是上屏），中/英报切换动作。
 * 退格按住不放会重复（400 毫秒以后每 50 毫秒一次），和系统键盘一致。
 */
public final class KeyboardView extends View {
    public interface Listener {
        /** keysym 是 XKB 的一个子集（见 core/include/wowtype_core.h）；modifiers 是 Session.MOD_*。 */
        void onKey(int keysym, int modifiers);

        /** 「中/英」键：会话切中 → 英 → 中。 */
        void onToggleMode();
    }

    private static final int KIND_LETTER = 0;
    private static final int KIND_PUNCT = 1;
    private static final int KIND_SPACE = 2;
    private static final int KIND_ENTER = 3;
    private static final int KIND_BACKSPACE = 4;
    private static final int KIND_SHIFT = 5;
    private static final int KIND_MODE = 6;

    private static final int BG = 0xFFE7EAEE;
    private static final int KEY = 0xFFFFFFFF;
    private static final int KEY_SPECIAL = 0xFFD2D7DD;
    private static final int KEY_PRESSED = 0xFFC2C8CF;
    private static final int TEXT = 0xFF1F2328;
    private static final int ACCENT = 0xFF0EAF76;

    private static final class Hit {
        RectF rect;
        int kind;
        String label;
        int keysym;
    }

    private final Paint keyPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint textPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint specialTextPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF scratch = new RectF();
    private final List<Hit> hits = new ArrayList<>();
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable repeat = new Runnable() {
        @Override
        public void run() {
            if (pressed == null || pressed.kind != KIND_BACKSPACE) return;
            if (listener != null) listener.onKey(Session.KEY_BACKSPACE, 0);
            handler.postDelayed(this, 50);
        }
    };

    private Listener listener;
    private boolean shift;
    private boolean english;
    private Hit pressed;
    private int activePointer = -1;

    private float density;
    private float gap;
    private float padding;

    public KeyboardView(Context context) {
        super(context);
        density = getResources().getDisplayMetrics().density;
        gap = 4 * density;
        padding = 4 * density;
        keyPaint.setStyle(Paint.Style.FILL);
        textPaint.setColor(TEXT);
        textPaint.setTextAlign(Paint.Align.CENTER);
        textPaint.setTypeface(Typeface.create("sans-serif", Typeface.NORMAL));
        textPaint.setTextSize(23 * density);
        specialTextPaint.setColor(TEXT);
        specialTextPaint.setTextAlign(Paint.Align.CENTER);
        specialTextPaint.setTypeface(Typeface.create("sans-serif", Typeface.NORMAL));
        specialTextPaint.setTextSize(15 * density);
        setFocusable(false);
        setBackgroundColor(BG);
        setContentDescription("WowType 键盘");
    }

    public void setListener(Listener listener) {
        this.listener = listener;
    }

    /** 中/英：影响「中/英」键、逗号句号的显示（中文模式下上屏的是全角）。 */
    public void setEnglish(boolean english) {
        if (this.english == english) return;
        this.english = english;
        layoutKeys();
        invalidate();
    }

    public boolean isEnglish() {
        return english;
    }

    @Override
    protected void onSizeChanged(int w, int h, int oldw, int oldh) {
        super.onSizeChanged(w, h, oldw, oldh);
        layoutKeys();
    }

    /** 按当前宽度、大小写、中英模式重算每个键的位置。 */
    private void layoutKeys() {
        hits.clear();
        int width = getWidth();
        int height = getHeight();
        if (width <= 0 || height <= 0) return;

        float contentWidth = getWidth() - padding * 2;
        float rowHeight = (height - padding * 2) / 4f;
        // 所有行用同一个键宽：第一行 10 个键、9 个缝，这样各行的字母键一样大
        float unit = (contentWidth - gap * 9) / 10f;
        buildRow(0, rowHeight, "qwertyuiop", padding, unit, gap);
        // 第二行 9 个键，居中
        float row1Width = unit * 9 + gap * 8;
        buildRow(1, rowHeight, "asdfghjkl", padding + (contentWidth - row1Width) / 2, unit, gap);
        // 第三行：Shift 1.5 + 7 个字母 + 退格 1.5 = 10 个键宽，8 个缝
        buildRow2(rowHeight, (contentWidth - unit * 10) / 8);
        // 第四行：中/英 1.5 + 逗号 1 + 空格 4.5 + 句号 1 + 回车 1.5 = 9.5 个键宽，4 个缝
        buildRow3(rowHeight, (contentWidth - unit * 9.5f) / 4);
    }

    private void add(float left, float top, float right, float bottom, int kind, String label, int keysym) {
        Hit hit = new Hit();
        hit.rect = new RectF(left, top, right, bottom);
        hit.kind = kind;
        hit.label = label;
        hit.keysym = keysym;
        hits.add(hit);
    }

    private void buildRow(int row, float rowHeight, String letters, float startX, float unit, float gap) {
        float top = padding + row * rowHeight + gap / 2;
        float bottom = padding + (row + 1) * rowHeight - gap / 2;
        float x = startX;
        for (int i = 0; i < letters.length(); i++) {
            char lower = letters.charAt(i);
            char label = shift ? Character.toUpperCase(lower) : lower;
            add(x, top, x + unit, bottom, KIND_LETTER, String.valueOf(label), label);
            x += unit + gap;
        }
    }

    private void buildRow2(float rowHeight, float gap) {
        float top = padding + 2 * rowHeight + gap / 2;
        float bottom = padding + 3 * rowHeight - gap / 2;
        float unit = (getWidth() - padding * 2 - gap * 8) / 10f;
        float special = 1.5f;
        float x = padding;
        add(x, top, x + unit * special, bottom, KIND_SHIFT, "⇧", 0);
        x += unit * special + gap;
        for (char lower : "zxcvbnm".toCharArray()) {
            char label = shift ? Character.toUpperCase(lower) : lower;
            add(x, top, x + unit, bottom, KIND_LETTER, String.valueOf(label), label);
            x += unit + gap;
        }
        add(x, top, x + unit * special, bottom, KIND_BACKSPACE, "⌫", Session.KEY_BACKSPACE);
    }

    private void buildRow3(float rowHeight, float gap) {
        float top = padding + 3 * rowHeight + gap / 2;
        float bottom = padding + 4 * rowHeight - gap / 2;
        float unit = (getWidth() - padding * 2 - gap * 4) / 9.5f;
        float x = padding;

        add(x, top, x + unit * 1.5f, bottom, KIND_MODE, english ? "英" : "中", 0);
        x += unit * 1.5f + gap;
        add(x, top, x + unit, bottom, KIND_PUNCT, english ? "," : "，", ',');
        x += unit + gap;
        add(x, top, x + unit * 4.5f, bottom, KIND_SPACE, english ? "space" : "空格", Session.KEY_SPACE);
        x += unit * 4.5f + gap;
        add(x, top, x + unit, bottom, KIND_PUNCT, english ? "." : "。", '.');
        x += unit + gap;
        add(x, top, x + unit * 1.5f, bottom, KIND_ENTER, "↵", Session.KEY_RETURN);
    }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        float radius = 7 * density;
        for (Hit hit : hits) {
            boolean isPressed = hit == pressed;
            int fill;
            if (isPressed) {
                fill = KEY_PRESSED;
            } else if (hit.kind == KIND_SHIFT && shift) {
                fill = ACCENT;
            } else if (hit.kind == KIND_MODE) {
                fill = english ? KEY_SPECIAL : ACCENT;
            } else if (hit.kind == KIND_LETTER || hit.kind == KIND_SPACE) {
                fill = KEY;
            } else {
                fill = KEY_SPECIAL;
            }
            keyPaint.setColor(fill);
            scratch.set(hit.rect);
            scratch.inset(gap / 3, gap / 3);
            canvas.drawRoundRect(scratch, radius, radius, keyPaint);

            boolean big = hit.kind == KIND_LETTER;
            Paint paint = big ? textPaint : specialTextPaint;
            paint.setColor(hit.kind == KIND_MODE && !english ? 0xFFFFFFFF
                    : hit.kind == KIND_SHIFT && shift ? 0xFFFFFFFF : TEXT);
            if (big) paint.setTextSize(23 * density);
            float centerY = hit.rect.centerY() - (paint.descent() + paint.ascent()) / 2;
            canvas.drawText(hit.label, hit.rect.centerX(), centerY, paint);
        }
    }

    @Override
    public boolean onTouchEvent(MotionEvent event) {
        switch (event.getActionMasked()) {
            case MotionEvent.ACTION_DOWN: {
                activePointer = event.getPointerId(0);
                pressed = hitAt(event.getX(), event.getY());
                if (pressed == null) return false;
                invalidate();
                performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP);
                if (pressed.kind == KIND_BACKSPACE) {
                    handler.postDelayed(repeat, 400);
                }
                return true;
            }
            case MotionEvent.ACTION_MOVE: {
                if (pressed == null) return false;
                int index = event.findPointerIndex(activePointer);
                if (index < 0) return false;
                Hit now = hitAt(event.getX(index), event.getY(index));
                if (now != pressed) {
                    pressed = now;
                    invalidate();
                }
                return true;
            }
            case MotionEvent.ACTION_UP: {
                if (pressed == null) return false;
                int index = event.findPointerIndex(activePointer);
                Hit up = index < 0 ? null : hitAt(event.getX(index), event.getY(index));
                Hit pressedNow = pressed;
                pressed = null;
                activePointer = -1;
                handler.removeCallbacks(repeat);
                invalidate();
                if (up == pressedNow) fire(pressedNow);
                return true;
            }
            case MotionEvent.ACTION_CANCEL: {
                pressed = null;
                activePointer = -1;
                handler.removeCallbacks(repeat);
                invalidate();
                return true;
            }
            default:
                return super.onTouchEvent(event);
        }
    }

    private void fire(Hit hit) {
        if (listener == null) return;
        switch (hit.kind) {
            case KIND_SHIFT:
                shift = !shift;
                layoutKeys();
                invalidate();
                break;
            case KIND_MODE:
                listener.onToggleMode();
                break;
            case KIND_BACKSPACE:
                listener.onKey(Session.KEY_BACKSPACE, 0);
                break;
            case KIND_ENTER:
                listener.onKey(Session.KEY_RETURN, 0);
                break;
            case KIND_SPACE:
                listener.onKey(Session.KEY_SPACE, 0);
                break;
            case KIND_PUNCT:
            case KIND_LETTER:
                listener.onKey(hit.keysym, shift ? Session.MOD_SHIFT : 0);
                if (shift) {
                    shift = false;
                    layoutKeys();
                    invalidate();
                }
                break;
            default:
                break;
        }
    }

    private Hit hitAt(float x, float y) {
        for (Hit hit : hits) {
            if (hit.rect.contains(x, y)) return hit;
        }
        return null;
    }
}
