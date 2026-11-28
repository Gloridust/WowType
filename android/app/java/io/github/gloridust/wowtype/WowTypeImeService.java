package io.github.gloridust.wowtype;

import android.Manifest;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.content.res.Configuration;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.speech.RecognitionListener;
import android.speech.RecognizerIntent;
import android.speech.SpeechRecognizer;
import android.text.InputType;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.widget.LinearLayout;
import android.widget.Toast;

import java.util.ArrayList;

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
    private TranslateHost translate;
    private SpeechRecognizer recognizer;
    private KeyboardView keyboard;
    private CandidateBar bar;
    private ToolbarView toolbar;

    /** 输入框的情况（密码框不自动空格、不翻译）。 */
    private int hints;
    /** 光标前一个字（Unicode 码位）；hasSurrounding 为 true 时才是应用告诉的。 */
    private int prevChar;
    private boolean hasSurrounding;
    /** 这次上屏是点第几个候选（1 起），不是点候选就是 0。打字统计用。 */
    private int lastCandidateIndex;
    /** 会话说「过一会儿再叫我」（互译出结果、单按 Shift 等双击）。 */
    private final Handler ticker = new Handler(Looper.getMainLooper());
    private final Runnable tickRunnable = () -> {
        if (session != null) render(session.tick());
    };

    /** 设置页改了东西：引擎选项、会话配置、候选排列马上跟上。 */
    private final SharedPreferences.OnSharedPreferenceChangeListener prefListener =
            (sharedPreferences, key) -> {
                Prefs prefs = Prefs.get(this);
                EngineHost.get().applySettings();
                if (bar != null) bar.setHorizontal(prefs.horizontal());
                if (keyboard != null && ("KeySound".equals(key) || "KeyVibrate".equals(key))) {
                    keyboard.setFeedback(prefs.keySound(), prefs.keyVibrate());
                }
                if (keyboard != null && "SwipeHide".equals(key)) {
                    keyboard.setSwipeHide(prefs.swipeHide());
                }
                if (session != null) {
                    session.configure(prefs.sessionConfig());
                }
                if ("TypingStats".equals(key)) {
                    StatsHost.get().applyEnabled();
                }
                if ("LexiconPath".equals(key)) {
                    if (session != null) {
                        session.setTranslateBackend(null);
                        session.close();
                        session = null;
                    }
                    EngineHost.get().restart();
                    Toast.makeText(this, "正在切换词库…", Toast.LENGTH_SHORT).show();
                }
                if (key != null && key.startsWith("Translate") && session != null) {
                    session.setTranslateBackend(
                            translate != null && prefs.translateReady() ? translate : null);
                }
                if ("SettingsTheme".equals(key)) {
                    // 键盘和候选条的颜色是建 View 时取的，换主题要重建输入视图
                    setInputView(onCreateInputView());
                }
                refresh();
            };

    private final CandidateBar.Listener candidateListener = new CandidateBar.Listener() {
        @Override
        public void onPick(int index) {
            if (session == null) return;
            lastCandidateIndex = index + 1;
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
        Prefs prefs = Prefs.get(this);
        globalMode = prefs.initialMode();
        prefs.raw().registerOnSharedPreferenceChangeListener(prefListener);
        StatsHost.get().start(this);
        translate = new TranslateHost(this);
        EngineHost.get().start(this, engineListener);
    }

    @Override
    public void onDestroy() {
        Prefs.get(this).raw().unregisterOnSharedPreferenceChangeListener(prefListener);
        EngineHost.get().removeListener(engineListener);
        if (session != null) {
            session.setTranslateBackend(null);
            session.close();
            session = null;
        }
        StatsHost.get().flush();
        ticker.removeCallbacks(tickRunnable);
        stopVoice();
        super.onDestroy();
    }

    @Override
    public View onCreateInputView() {
        // 原生库没装上时，设置页和这里都直接说原因，别只留一个打不开的键盘
        if (!Native.available()) {
            Toast.makeText(this, "WowType 原生库加载失败：" + Native.loadError(),
                    Toast.LENGTH_LONG).show();
        }
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);

        bar = new CandidateBar(this);
        bar.setListener(candidateListener);
        bar.setHorizontal(Prefs.get(this).horizontal());
        root.addView(bar, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));

        toolbar = new ToolbarView(this);
        toolbar.setListener(new ToolbarView.Listener() {
            @Override
            public void onEmoji() {
                if (session != null) render(session.toggleEmoji());
            }

            @Override
            public void onClipboard() {
                rememberClipboard();
                if (session != null) render(session.openTool(Session.TOOL_CLIPBOARD));
            }

            @Override
            public void onMenu() {
                if (session != null) render(session.openTool(Session.TOOL_MENU));
            }

            @Override
            public void onSettings() {
                startActivity(new Intent(WowTypeImeService.this, SettingsActivity.class)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            }

            @Override
            public void onHide() {
                requestHideSelf(0);
            }
        });
        root.addView(toolbar, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(40)));

        keyboard = new KeyboardView(this);
        keyboard.setListener(this);
        keyboard.setEnglish(globalMode == Session.MODE_ENGLISH);
        keyboard.setFeedback(Prefs.get(this).keySound(), Prefs.get(this).keyVibrate());
        keyboard.setSwipeHide(Prefs.get(this).swipeHide());
        int keyboardHeight = getResources().getConfiguration().orientation
                == Configuration.ORIENTATION_LANDSCAPE ? 170 : 238;
        root.addView(keyboard, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                dp(keyboardHeight)));

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
    public void onConfigurationChanged(Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        // 横屏空间小：键盘降到 170dp，候选条和输入框才留得下
        setInputView(onCreateInputView());
        refresh();
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
        // 原生库没装上：不建会话，免得在输入框里闪退（设置页会显示具体原因）
        if (!Native.available()) {
            session = null;
            return;
        }
        session = new Session(EngineHost.get().handle(), Prefs.get(this).sessionConfig());
        session.setTranslateBackend(translate != null && translate.ready() ? translate : null);
        rememberClipboard();
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
            session.setTranslateBackend(null);
            session.close();
            session = null;
        }
        StatsHost.get().flush();
        stopVoice();
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

    /** 打开工具栏之前把系统剪贴板交一份给核心（桌面版也是这样，最近 20 条只在内存里）。 */
    private void rememberClipboard() {
        if (!Prefs.get(this).clipboardHistory()) return;
        try {
            ClipboardManager manager = (ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
            if (manager == null || !manager.hasPrimaryClip()) return;
            ClipData clip = manager.getPrimaryClip();
            if (clip == null || clip.getItemCount() == 0) return;
            CharSequence text = clip.getItemAt(0).coerceToText(this);
            if (text != null && text.length() > 0 && text.length() <= 4000) {
                Native.clipboardRemember(text.toString());
            }
        } catch (Throwable ignored) {
            // Android 10 起剪贴板读取可能被系统拒绝：拿不到就算了
        }
    }

    private void onEngineReady() {
        long handle = EngineHost.get().handle();
        if (handle == 0) return;
        if (session == null) {
            session = new Session(handle, Prefs.get(this).sessionConfig());
            session.setTranslateBackend(translate != null && translate.ready() ? translate : null);
        } else {
            session.setEngine(handle);
        }
        refresh();
    }

    @Override
    public void onKey(int keysym, int modifiers) {
        handleKey(keysym, modifiers, false);
    }

    @Override
    public void onHideKeyboard() {
        requestHideSelf(0);
    }

    /** 语音键：用系统的语音识别（可能联网），结果走 core 的 commit_text。 */
    @Override
    public void onVoice() {
        Prefs prefs = Prefs.get(this);
        if (!prefs.voice()) {
            Toast.makeText(this, "先在设置里打开「语音输入」", Toast.LENGTH_SHORT).show();
            return;
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO)
                != PackageManager.PERMISSION_GRANTED) {
            Toast.makeText(this, "没有麦克风权限：在设置里关掉再打开「语音输入」授权",
                    Toast.LENGTH_LONG).show();
            return;
        }
        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            Toast.makeText(this, "系统没有可用的语音识别服务", Toast.LENGTH_LONG).show();
            return;
        }
        stopVoice();
        recognizer = SpeechRecognizer.createSpeechRecognizer(this);
        recognizer.setRecognitionListener(voiceListener);
        Intent intent = new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH);
        intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM);
        intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE, "zh-CN");
        intent.putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false);
        intent.putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1);
        recognizer.startListening(intent);
        Toast.makeText(this, "正在听…", Toast.LENGTH_SHORT).show();
    }

    private final RecognitionListener voiceListener = new RecognitionListener() {
        @Override
        public void onReadyForSpeech(Bundle params) {
        }

        @Override
        public void onBeginningOfSpeech() {
        }

        @Override
        public void onRmsChanged(float rmsdB) {
        }

        @Override
        public void onBufferReceived(byte[] buffer) {
        }

        @Override
        public void onEndOfSpeech() {
        }

        @Override
        public void onError(int error) {
            Toast.makeText(WowTypeImeService.this, "没听清，再试一次", Toast.LENGTH_SHORT).show();
            stopVoice();
        }

        @Override
        public void onResults(Bundle results) {
            ArrayList<String> list = results == null ? null
                    : results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);
            if (list != null && !list.isEmpty() && session != null) {
                render(session.commitText(list.get(0), prevChar));
            }
            stopVoice();
        }

        @Override
        public void onPartialResults(Bundle partialResults) {
        }

        @Override
        public void onEvent(int eventType, Bundle params) {
        }
    };

    private void stopVoice() {
        if (recognizer != null) {
            recognizer.cancel();
            recognizer.destroy();
            recognizer = null;
        }
    }

    @Override
    public void onToggleMode() {
        if (session == null) return;
        // 和桌面单按 Shift 一样循环：中 → 英 →（配好互译时）译 → 中。
        // ACTION_TOGGLE_MODE 在核心里只切中↔英，所以这里自己算下一档。
        int mode = session.mode();
        int next;
        if (mode == Session.MODE_CHINESE) {
            next = Session.MODE_ENGLISH;
        } else if (mode == Session.MODE_ENGLISH
                && Prefs.get(this).translateReady()) {
            next = Session.MODE_TRANSLATE;
        } else {
            next = Session.MODE_CHINESE;
        }
        render(session.setMode(next));
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
            // 自动配对：成对删除时退格删左边，再删补好的右边
            if (frame.deleteNext != 0) {
                sendDownUpKeyEvents(KeyEvent.KEYCODE_FORWARD_DEL);
            }
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
                StatsHost.get().commit(frame.commit, statsSource(), statsScheme(),
                        lastCandidateIndex, (hints & Session.HINT_NO_LEARN) != 0);
                lastCandidateIndex = 0;
                conn.commitText(frame.commit, 1);
                afterTyped(frame.commit);
                if (frame.cursorDelta != 0) moveCaret(conn, frame.cursorDelta);
            }
            String preedit = frame.preedit == null ? "" : frame.preedit;
            // 「译」里编辑区显示译文（还没有译文时先显示攒着的原文），和桌面版一样边译边看
            if (frame.mode == Session.MODE_TRANSLATE) {
                if (!frame.translateText.isEmpty()) {
                    preedit = frame.translateText;
                } else if (!frame.translateSource.isEmpty()) {
                    preedit = frame.translateSource;
                }
            }
            if (!preedit.isEmpty()) {
                conn.setComposingText(preedit, 1);
            } else {
                // 先清空再 finish：直接 finishComposingText 会把最后一段拼音（v、ni'hao）上屏，
                // 工具栏、Esc、表情面板这些「丢掉编辑区」的路径就会留下 v
                conn.setComposingText("", 1);
                conn.finishComposingText();
            }
        }

        if (frame.modeChanged) globalMode = frame.mode;
        if (session != null) {
            if (keyboard != null) keyboard.setMode(session.mode());
        }
        if (bar != null) bar.setFrame(frame);
        if (frame.learned || frame.forgot) EngineHost.get().save();
        ticker.removeCallbacks(tickRunnable);
        if (frame.wakeAfterMs > 0) {
            ticker.postDelayed(tickRunnable, frame.wakeAfterMs);
        }
    }

    /** 自动配对：上屏「（）」以后把光标挪到中间。 */
    private void moveCaret(InputConnection conn, int delta) {
        int code = delta < 0 ? KeyEvent.KEYCODE_DPAD_LEFT : KeyEvent.KEYCODE_DPAD_RIGHT;
        for (int i = 0; i < Math.abs(delta); i++) {
            conn.sendKeyEvent(new KeyEvent(KeyEvent.ACTION_DOWN, code));
            conn.sendKeyEvent(new KeyEvent(KeyEvent.ACTION_UP, code));
        }
    }

    /** 打字统计的上屏来源。 */
    private String statsSource() {
        Prefs prefs = Prefs.get(this);
        if (prefs.wubi()) return "wubi";
        if (prefs.shuangpin()) return "shuangpin";
        if (session != null && session.mode() == Session.MODE_TRANSLATE) return "translate";
        if (session != null && session.mode() == Session.MODE_ENGLISH) return "english";
        return "quanpin";
    }

    private String statsScheme() {
        Prefs prefs = Prefs.get(this);
        return prefs.shuangpin() ? prefs.shuangpinScheme() : "";
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
        return password
                ? Session.HINT_NO_AUTO_SPACE | Session.HINT_NO_TRANSLATE | Session.HINT_NO_LEARN
                : 0;
    }

    // ---- 硬件键盘（外接键盘、Chromebook、桌面模式） ----

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (session == null) return super.onKeyDown(keyCode, event);
        // 桌面版的 Super + . 开表情面板
        if (event.getRepeatCount() == 0) {
            StatsHost.get().key(keyCode, (hints & Session.HINT_NO_LEARN) != 0);
        }
        if (keyCode == KeyEvent.KEYCODE_PERIOD && event.isMetaPressed()) {
            render(session.toggleEmoji());
            return true;
        }
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
        // 单按 Shift 切中/英/译：松开要交给会话（软键盘的 Shift 只管大小写，不走这里）
        int keysym = keysymFor(keyCode, event);
        if (keysym == 0xffe1 || keysym == 0xffe2) {
            if (session != null) {
                Frame frame = session.release(keysym, modifiersFor(event), keyCode);
                if (frame.handled) {
                    render(frame);
                    return true;
                }
            }
        }
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
            case KeyEvent.KEYCODE_SHIFT_LEFT: return 0xffe1;
            case KeyEvent.KEYCODE_SHIFT_RIGHT: return 0xffe2;
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
