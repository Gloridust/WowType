package io.github.gloridust.wowtype;

/**
 * 一个输入框一个会话（{@code wowtype_session_*}，见 docs/ABI.md）。所有调用都在主线程，
 * 和 Android 的 InputConnection 同一个线程。
 */
public final class Session implements AutoCloseable {
    /* WowtypeKey.modifiers：和 X11 / fcitx5 的 KeyState 取值一样（core/include/wowtype_core.h） */
    public static final int MOD_SHIFT = 1;
    public static final int MOD_CAPS = 1 << 1;
    public static final int MOD_CTRL = 1 << 2;
    public static final int MOD_ALT = 1 << 3;
    public static final int MOD_NUMLOCK = 1 << 4;
    public static final int MOD_SUPER = 1 << 6;

    /* WowtypeKey.action（1.6 / 1.10 起） */
    public static final int ACTION_NONE = 0;
    public static final int ACTION_PREV_PAGE = 1;
    public static final int ACTION_NEXT_PAGE = 2;
    public static final int ACTION_TOGGLE_MODE = 6;

    /* WowtypeKey.hints（1.10 起） */
    public static final int HINT_NO_AUTO_SPACE = 1;
    public static final int HINT_NO_TRANSLATE = 1 << 2;
    public static final int HINT_SURROUNDING = 1 << 3;

    /* WOWTYPE_MODE_*（1.10 起） */
    public static final int MODE_CHINESE = 0;
    public static final int MODE_ENGLISH = 1;
    public static final int MODE_TRANSLATE = 2;

    /* XKB keysym 里用到的几个（和桌面外壳翻出来的一样） */
    public static final int KEY_SPACE = 0x20;
    public static final int KEY_APOSTROPHE = 0x27;
    public static final int KEY_BACKSPACE = 0xff08;
    public static final int KEY_RETURN = 0xff0d;
    public static final int KEY_ESCAPE = 0xff1b;

    private long ptr;

    /**
     * 引擎句柄不允许两个线程同时调用（docs/ABI.md「线程」）。会话在主线程用引擎，
     * 学习数据在后台线程存；两边都拿这把锁，保证不会同时进核心。
     */
    static final Object ENGINE_LOCK = new Object();

    public Session(long engine) {
        synchronized (ENGINE_LOCK) {
            ptr = Native.newSession(engine);
        }
    }

    public boolean isOpen() {
        return ptr != 0;
    }

    /** 处理一次按下（松开事件安卓外壳不送，会话只在 Shift 上用松开）。 */
    public Frame press(int keysym, int modifiers, int prevChar, int hints) {
        return dispatch(keysym, modifiers, ACTION_NONE, prevChar, hints, 0, false);
    }

    /** 外壳认出来的键（翻页、中/英切换）：只有动作，没有 keysym。 */
    public Frame tap(int action, int modifiers) {
        return dispatch(0, modifiers, action, 0, 0, 0, false);
    }

    /** 完整版，给硬件键盘的按键用（带键码、自动重复、时刻）。 */
    public Frame dispatch(int keysym, int modifiers, int action, int prevChar, int hints, int code,
                          boolean repeat) {
        if (ptr == 0) return Frame.empty();
        synchronized (ENGINE_LOCK) {
            return Frame.from(Native.key(ptr, keysym, modifiers, false, prevChar, action, hints, code,
                    repeat, System.currentTimeMillis()));
        }
    }

    public Frame frame() {
        if (ptr == 0) return Frame.empty();
        synchronized (ENGINE_LOCK) {
            return Frame.from(Native.frame(ptr));
        }
    }

    public Frame select(int index) {
        if (ptr == 0) return Frame.empty();
        synchronized (ENGINE_LOCK) {
            return Frame.from(Native.select(ptr, index));
        }
    }

    public Frame reset(boolean commitPending) {
        if (ptr == 0) return Frame.empty();
        synchronized (ENGINE_LOCK) {
            return Frame.from(Native.reset(ptr, commitPending));
        }
    }

    public Frame setMode(int mode) {
        if (ptr == 0) return Frame.empty();
        synchronized (ENGINE_LOCK) {
            return Frame.from(Native.setMode(ptr, mode));
        }
    }

    public int mode() {
        if (ptr == 0) return MODE_CHINESE;
        synchronized (ENGINE_LOCK) {
            return Native.mode(ptr);
        }
    }

    public String input() {
        if (ptr == 0) return "";
        synchronized (ENGINE_LOCK) {
            return Native.input(ptr);
        }
    }

    public void setEngine(long engine) {
        if (ptr == 0) return;
        synchronized (ENGINE_LOCK) {
            Native.setEngine(ptr, engine);
        }
    }

    @Override
    public void close() {
        if (ptr == 0) return;
        synchronized (ENGINE_LOCK) {
            Native.freeSession(ptr);
            ptr = 0;
        }
    }
}
