package io.github.gloridust.wowtype;

import android.text.InputType;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.widget.LinearLayout;

/**
 * Android 输入法外壳：软键盘的按键 → 核心的输入会话（{@code wowtype_session_*}）→ 编辑区和候选。
 *
 * 和 macOS / fcitx5 外壳分工一样：这里只管把按键翻成 keysym、把 frame 画出来、把 commit 交给
 * InputConnection。拼音切分、纠错、整句、选词、标点、学习中英文模式都在核心里。
 */
public final class WowTypeImeService extends android.inputmethodservice.InputMethodService
        implements KeyboardView.Listener {
    /** 中 / 英在输入框之间保留（桌面版是每个输入框一个会话，但安卓用户期望切一次就一直有效）。 */
    private static int globalMode = Session.MODE_CHINESE;

    private final EngineHost.Listener engineListener = this::onEngineReady;

    private Session session;
    private KeyboardView keyboard;
    private CandidateBar bar;

    /** 输入框的情况（密码框不自动空格、不翻译）。 */
    private int hints;
    /** 光标前一个字（Unicode 码位）；hasSurrounding 为 true 时才是应用告诉的。 */
    private int prevChar;
    private boolean hasSurrounding;

    private final CandidateBar.Listener candidateListener = new CandidateBar.Listener() {
        @Override
        public void onPick(int index) {
            if (session == null) return;
            render(session.select(index));
        }

        @Override
        public void onPrevPage() {
            page(Session.ACTION_PREV_PAGE);
        }

        @Override
        public void onNextPage() {
            page(Session.ACTION_NEXT_PAGE);
        }
    };

    @Override
    public void onCreate() {
        super.onCreate();
        EngineHost.get().start(this, engineListener);
    }

    @Override
    public void onDestroy() {
        EngineHost.get().removeListener(engineListener);
        if (session != null) {
            session.close();
            session = null;
        }
        super.onDestroy();
    }

    @Override
    public View onCreateInputView() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);

        bar = new CandidateBar(this);
        bar.setListener(candidateListener);
        root.addView(bar, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(46)));

        keyboard = new KeyboardView(this);
        keyboard.setListener(this);
        keyboard.setEnglish(globalMode == Session.MODE_ENGLISH);
        root.addView(keyboard, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(238)));

        // 手势导航条 / 导航栏会盖在输入法窗口底下：把底部内边距让出来，最下面一行才不被吃掉
        root.setOnApplyWindowInsetsListener((view, insets) -> {
            int bottom = insets.getSystemWindowInsetBottom();
            if (view.getPaddingBottom() != bottom) {
                view.setPadding(0, 0, 0, bottom);
            }
            return insets;
        });
        return root;
    }

    @Override
    public boolean onEvaluateFullscreenMode() {
        // 横屏也别全屏：候选条就在键盘上面，不需要占满屏幕
        return false;
    }

    @Override
    public void onStartInput(EditorInfo attribute, boolean restarting) {
        super.onStartInput(attribute, restarting);
        if (session != null) session.close();
        session = new Session(EngineHost.get().handle());
        hints = hintsFor(attribute);
        refreshSurrounding();
        if (globalMode != Session.MODE_CHINESE) {
            session.setMode(globalMode);
        }
        if (bar != null) bar.clear();
        refresh();
    }

    @Override
    public void onStartInputView(EditorInfo info, boolean restarting) {
        super.onStartInputView(info, restarting);
        refresh();
    }

    @Override
    public void onFinishInput() {
        if (session != null) {
            // 失去焦点：打到一半的丢掉（不往下一个输入框里塞拼音）
            session.reset(false);
            session.close();
            session = null;
        }
        if (bar != null) bar.clear();
        super.onFinishInput();
    }

    @Override
    public void onUpdateSelection(int oldSelStart, int oldSelEnd, int newSelStart, int newSelEnd,
                                  int candidatesStart, int candidatesEnd) {
        super.onUpdateSelection(oldSelStart, oldSelEnd, newSelStart, newSelEnd, candidatesStart,
                candidatesEnd);
        if (candidatesStart < 0 && session != null && !session.input().isEmpty()) {
            // 应用自己把编辑区清了（点了别处、换行）：会话跟上
            session.reset(false);
            if (bar != null) bar.clear();
        }
        if (candidatesStart < 0) {
            // 组字的时候光标前的字是拼音，不是上屏的内容：只在没组字时读
            refreshSurrounding();
        }
    }

    private void onEngineReady() {
        if (session == null) return;
        long handle = EngineHost.get().handle();
        if (handle == 0) return;
        session.setEngine(handle);
        refresh();
    }

    @Override
    public void onKey(int keysym, int modifiers) {
        handleKey(keysym, modifiers, false);
    }

    @Override
    public void onToggleMode() {
        if (session == null) return;
        Frame frame = session.tap(Session.ACTION_TOGGLE_MODE, 0);
        if (frame.handled) render(frame);
    }

    /** 软键盘按键和硬件键盘都走这里。handled 为 0 时由外壳把字原样打进去（英文模式）。 */
    private void handleKey(int keysym, int modifiers, boolean repeat) {
        dispatch(keysym, modifiers, 0, repeat);
    }

    private void dispatch(int keysym, int modifiers, int code, boolean repeat) {
        if (session == null) return;
        int fieldHints = hints | (hasSurrounding ? Session.HINT_SURROUNDING : 0);
        Frame frame = session.dispatch(keysym, modifiers, Session.ACTION_NONE,
                hasSurrounding ? prevChar : 0, fieldHints, code, repeat);
        if (frame.handled) {
            render(frame);
        } else {
            passThrough(keysym, modifiers);
        }
    }

    private void page(int action) {
        if (session == null) return;
        Frame frame = session.tap(action, 0);
        if (frame.handled) render(frame);
    }

    /** 会话交给应用：软键盘自己把字符 / 删除 / 回车打进去。 */
    private void passThrough(int keysym, int modifiers) {
        InputConnection conn = getCurrentInputConnection();
        if (conn == null) return;
        switch (keysym) {
            case Session.KEY_BACKSPACE:
                sendDownUpKeyEvents(KeyEvent.KEYCODE_DEL);
                return;
            case Session.KEY_RETURN:
                if (!sendDefaultEditorAction(true)) {
                    sendDownUpKeyEvents(KeyEvent.KEYCODE_ENTER);
                }
                return;
            case Session.KEY_ESCAPE:
                return;
            default:
                break;
        }
        String text = textForKeysym(keysym);
        if (text != null) {
            conn.commitText(text, 1);
            afterTyped(text);
        }
    }

    private String textForKeysym(int keysym) {
        if (keysym >= 0x20 && keysym <= 0x7e) {
            return String.valueOf((char) keysym);
        }
        return null;
    }

    /** 把 frame 画出来：上屏、编辑区、候选条、模式。 */
    private void render(Frame frame) {
        InputConnection conn = getCurrentInputConnection();
        if (conn != null) {
            if (frame.commit != null && !frame.commit.isEmpty()) {
                conn.commitText(frame.commit, 1);
                afterTyped(frame.commit);
            }
            String preedit = frame.preedit == null ? "" : frame.preedit;
            if (!preedit.isEmpty()) {
                conn.setComposingText(preedit, 1);
            } else {
                conn.finishComposingText();
            }
        }

        if (frame.modeChanged) globalMode = frame.mode;
        if (session != null) {
            boolean english = session.mode() == Session.MODE_ENGLISH;
            if (keyboard != null) keyboard.setEnglish(english);
        }
        if (bar != null) bar.setFrame(frame);
        if (frame.learned || frame.forgot) EngineHost.get().save();
    }

    /** 重新画（引擎载入完了、输入框换了）：编辑区可能从原始输入变成了分好音节的拼音。 */
    private void refresh() {
        if (session == null) return;
        if (bar != null) bar.clear();
        render(session.frame());
    }

    private void afterTyped(String text) {
        if (text.isEmpty()) return;
        prevChar = Character.codePointBefore(text, text.length());
        hasSurrounding = true;
    }

    private void refreshSurrounding() {
        InputConnection conn = getCurrentInputConnection();
        hasSurrounding = false;
        prevChar = 0;
        if (conn == null) return;
        CharSequence before = conn.getTextBeforeCursor(1, 0);
        if (before != null && before.length() > 0) {
            prevChar = Character.codePointBefore(before, before.length());
            hasSurrounding = true;
        }
    }

    private static int hintsFor(EditorInfo info) {
        if (info == null) return 0;
        int inputType = info.inputType;
        int cls = inputType & InputType.TYPE_MASK_CLASS;
        int variation = inputType & InputType.TYPE_MASK_VARIATION;
        boolean password = false;
        if (cls == InputType.TYPE_CLASS_TEXT) {
            password = variation == InputType.TYPE_TEXT_VARIATION_PASSWORD
                    || variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
                    || variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD;
        } else if (cls == InputType.TYPE_CLASS_NUMBER) {
            password = variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD;
        }
        return password ? Session.HINT_NO_AUTO_SPACE | Session.HINT_NO_TRANSLATE : 0;
    }

    // ---- 硬件键盘（外接键盘、Chromebook、桌面模式） ----

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (session == null) return super.onKeyDown(keyCode, event);
        int keysym = keysymFor(keyCode, event);
        if (keysym == 0) return super.onKeyDown(keyCode, event);
        int fieldHints = hints | (hasSurrounding ? Session.HINT_SURROUNDING : 0);
        Frame frame = session.dispatch(keysym, modifiersFor(event), Session.ACTION_NONE,
                hasSurrounding ? prevChar : 0, fieldHints, keyCode, event.getRepeatCount() > 0);
        if (frame.handled) {
            render(frame);
            return true;
        }
        return super.onKeyDown(keyCode, event);
    }

    @Override
    public boolean onKeyUp(int keyCode, KeyEvent event) {
        // 松开事件不需要交给会话：会话只在 Shift 上用，而软键盘的 Shift 只管大小写
        return super.onKeyUp(keyCode, event);
    }

    private static int keysymFor(int keyCode, KeyEvent event) {
        if (keyCode >= KeyEvent.KEYCODE_A && keyCode <= KeyEvent.KEYCODE_Z) {
            char lower = (char) ('a' + keyCode - KeyEvent.KEYCODE_A);
            return event.isShiftPressed() ? Character.toUpperCase(lower) : lower;
        }
        if (keyCode >= KeyEvent.KEYCODE_0 && keyCode <= KeyEvent.KEYCODE_9) {
            return '0' + keyCode - KeyEvent.KEYCODE_0;
        }
        switch (keyCode) {
            case KeyEvent.KEYCODE_SPACE: return Session.KEY_SPACE;
            case KeyEvent.KEYCODE_ENTER:
            case KeyEvent.KEYCODE_NUMPAD_ENTER: return Session.KEY_RETURN;
            case KeyEvent.KEYCODE_DEL: return Session.KEY_BACKSPACE;
            case KeyEvent.KEYCODE_ESCAPE: return Session.KEY_ESCAPE;
            case KeyEvent.KEYCODE_COMMA: return ',';
            case KeyEvent.KEYCODE_PERIOD: return '.';
            case KeyEvent.KEYCODE_SLASH: return '/';
            case KeyEvent.KEYCODE_APOSTROPHE: return Session.KEY_APOSTROPHE;
            case KeyEvent.KEYCODE_MINUS: return '-';
            case KeyEvent.KEYCODE_EQUALS: return '=';
            case KeyEvent.KEYCODE_LEFT_BRACKET: return '[';
            case KeyEvent.KEYCODE_RIGHT_BRACKET: return ']';
            case KeyEvent.KEYCODE_SEMICOLON: return ';';
            case KeyEvent.KEYCODE_DPAD_LEFT: return 0xff51;
            case KeyEvent.KEYCODE_DPAD_UP: return 0xff52;
            case KeyEvent.KEYCODE_DPAD_RIGHT: return 0xff53;
            case KeyEvent.KEYCODE_DPAD_DOWN: return 0xff54;
            case KeyEvent.KEYCODE_PAGE_UP: return 0xff55;
            case KeyEvent.KEYCODE_PAGE_DOWN: return 0xff56;
            case KeyEvent.KEYCODE_TAB: return 0xff09;
            default: return 0;
        }
    }

    private static int modifiersFor(KeyEvent event) {
        int meta = event.getMetaState();
        int modifiers = 0;
        if ((meta & KeyEvent.META_SHIFT_ON) != 0) modifiers |= Session.MOD_SHIFT;
        if ((meta & KeyEvent.META_CTRL_ON) != 0) modifiers |= Session.MOD_CTRL;
        if ((meta & KeyEvent.META_ALT_ON) != 0) modifiers |= Session.MOD_ALT;
        if ((meta & KeyEvent.META_META_ON) != 0) modifiers |= Session.MOD_SUPER;
        if ((meta & KeyEvent.META_CAPS_LOCK_ON) != 0) modifiers |= Session.MOD_CAPS;
        return modifiers;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
