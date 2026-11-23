package io.github.gloridust.wowtype;

import android.content.Context;
import android.content.SharedPreferences;

/**
 * 安卓外壳的设置，存在 SharedPreferences 里。键名和桌面版 {@code settings/wowtype-config} 的
 * DEFAULTS 对齐，值也尽量用同一套（True/False、Quanpin/Shuangpin、Ziranma……），方便以后导入桌面配置。
 *
 * 引擎级的（双拼、模糊音、纠错、繁体、候选上限）由 {@link EngineHost#applySettings()} 设到引擎上；
 * 会话级的打包成 int[] 交给 {@code WowtypeSessionConfig}（顺序见 {@link #sessionConfig()} 和
 * {@code android/app/jni/wowtype_jni.c} 的 fill_session_config，改一边要改另一边）。
 */
final class Prefs {
    static final String FILE = "wowtype";

    /* 模糊音分组：和 core/src/syllable.rs 的 fuzzy::* 位一致 */
    static final int FZ_ZH = 1 << 0;
    static final int FZ_CH = 1 << 1;
    static final int FZ_SH = 1 << 2;
    static final int FZ_NL = 1 << 3;
    static final int FZ_FH = 1 << 4;
    static final int FZ_RL = 1 << 5;
    static final int FZ_AN = 1 << 6;
    static final int FZ_EN = 1 << 7;
    static final int FZ_IN = 1 << 8;
    static final int FZ_IAN = 1 << 9;
    static final int FZ_UAN = 1 << 10;
    static final int FZ_UN = 1 << 11;
    static final int FZ_AN_AI = 1 << 12;
    static final int FZ_HUANG_WANG = 1 << 13;
    static final int FZ_UN_IONG = 1 << 14;
    static final int FZ_ENG_ONG = 1 << 15;
    /** 和桌面版默认打开的组一样：z=zh、c=ch、s=sh、an=ang、en=eng、in=ing、ian=iang、uan=uang。 */
    static final int FUZZY_DEFAULT = FZ_ZH | FZ_CH | FZ_SH | FZ_AN | FZ_EN | FZ_IN | FZ_IAN | FZ_UAN;

    /* WowtypeSessionConfig.page_keys 的位（core/include/wowtype_core.h） */
    static final int PAGE_MINUS = 1;
    static final int PAGE_BRACKET = 1 << 1;
    static final int PAGE_COMMA = 1 << 2;
    static final int PAGE_TAB = 1 << 3;

    static final String[] SHUANGPIN_SCHEMES = {
            "ziranma", "xiaohe", "microsoft", "sogou", "abc", "ziguang", "pinyinjiajia",
    };
    static final String[] SHUANGPIN_NAMES = {
            "自然码", "小鹤双拼", "微软双拼", "搜狗双拼", "智能 ABC", "紫光双拼", "拼音加加",
    };

    private final SharedPreferences prefs;

    private Prefs(SharedPreferences prefs) {
        this.prefs = prefs;
    }

    static Prefs get(Context context) {
        return new Prefs(context.getApplicationContext()
                .getSharedPreferences(FILE, Context.MODE_PRIVATE));
    }

    SharedPreferences raw() {
        return prefs;
    }

    String string(String key, String fallback) {
        return prefs.getString(key, fallback);
    }

    boolean bool(String key, boolean fallback) {
        return prefs.getBoolean(key, fallback);
    }

    int integer(String key, int fallback) {
        return prefs.getInt(key, fallback);
    }

    void set(String key, boolean value) {
        prefs.edit().putBoolean(key, value).apply();
    }

    void set(String key, int value) {
        prefs.edit().putInt(key, value).apply();
    }

    void set(String key, String value) {
        prefs.edit().putString(key, value).apply();
    }

    boolean shuangpin() {
        return "Shuangpin".equals(string("InputScheme", "Quanpin"));
    }

    boolean wubi() {
        return "Wubi".equals(string("InputScheme", "Quanpin"));
    }

    String shuangpinScheme() {
        return string("ShuangpinScheme", "ziranma");
    }

    boolean shuangpinShowKeys() {
        return bool("ShuangpinShowKeys", false);
    }

    boolean shuangpinAbbrev() {
        return bool("ShuangpinAbbrev", true);
    }

    boolean fuzzy() {
        return bool("Fuzzy", false);
    }

    int fuzzyGroups() {
        return integer("FuzzyGroups", FUZZY_DEFAULT);
    }

    boolean typo() {
        return bool("TypoCorrection", true);
    }

    boolean rareExtChars() {
        return bool("RareExtChars", false);
    }

    boolean traditional() {
        return bool("Traditional", false);
    }

    boolean horizontal() {
        return !"Vertical".equals(string("CandidateLayout", "Horizontal"));
    }

    int pageSize() {
        try {
            return Math.max(3, Math.min(9, Integer.parseInt(string("PageSize", "9"))));
        } catch (NumberFormatException e) {
            return 9;
        }
    }

    int pageKeys() {
        return integer("PageKeys", PAGE_MINUS);
    }

    int selectKeys() {
        try {
            return Math.max(0, Math.min(2, Integer.parseInt(string("SelectKeys", "0"))));
        } catch (NumberFormatException e) {
            return 0;
        }
    }

    boolean pickChar() {
        return bool("PickChar", true);
    }

    /** false 是全角（中文标点）。 */
    boolean halfwidthPunct() {
        return "Halfwidth".equals(string("PunctuationStyle", "Fullwidth"));
    }

    int autoSpace() {
        int flags = 0;
        if (bool("AutoSpaceLetters", true)) flags |= 1;
        if (bool("AutoSpaceDigits", true)) flags |= 2;
        return bool("AutoSpace", false) ? flags : 0;
    }

    int shiftToggle() {
        try {
            return Math.max(0, Math.min(3, Integer.parseInt(string("ShiftToggle", "0"))));
        } catch (NumberFormatException e) {
            return 0;
        }
    }

    int initialMode() {
        return "English".equals(string("InitialMode", "Chinese"))
                ? Session.MODE_ENGLISH : Session.MODE_CHINESE;
    }

    boolean dateTime() {
        return bool("DateTime", true);
    }

    boolean calculator() {
        return bool("Calculator", true);
    }

    boolean emojiSuggest() {
        return bool("EmojiSuggest", true);
    }

    boolean association() {
        return bool("Association", false);
    }

    boolean autoPairPunct() {
        return bool("AutoPairPunct", false);
    }

    boolean toolbar() {
        return bool("Toolbar", true);
    }

    boolean translate() {
        return bool("Translate", false);
    }

    String translateTarget() {
        return string("TranslateTarget", "en");
    }

    String translateBaseUrl() {
        return string("TranslateBaseUrl", "https://index-translate.bilibili.com/v1");
    }

    String translateModel() {
        return string("TranslateModel", "Index-Translate-2B");
    }

    String translateKey() {
        return string("TranslateApiKey", "");
    }

    boolean translateFormal() {
        return bool("TranslateFormal", false);
    }

    /** 配好了才让会话进「译」。 */
    boolean translateReady() {
        return translate() && !translateBaseUrl().trim().isEmpty();
    }

    /** 自定义词库路径（导入的 lexicon.tsv）；空串用 APK 自带。 */
    String lexiconPath() {
        return string("LexiconPath", "");
    }

    boolean wubiAutoCommit() {
        return bool("WubiAutoCommit", true);
    }

    boolean wubiHint() {
        return bool("WubiHint", true);
    }

    boolean shiftDoubleTap() {
        return bool("ShiftDoubleTap", false);
    }

    boolean translateOneShot() {
        return bool("TranslateOneShot", false);
    }

    boolean checkUpdate() {
        return bool("CheckUpdate", true);
    }

    boolean betaUpdates() {
        return bool("BetaUpdates", false);
    }

    boolean keyVibrate() {
        return bool("KeyVibrate", true);
    }

    boolean keySound() {
        return bool("KeySound", false);
    }

    boolean swipeHide() {
        return bool("SwipeHide", true);
    }

    boolean voice() {
        return bool("Voice", false);
    }

    boolean typingStats() {
        return bool("TypingStats", false);
    }

    boolean clipboardHistory() {
        return bool("ClipboardHistory", false);
    }

    /**
     * WowtypeSessionConfig 的取值，顺序和 JNI 的 fill_session_config 一致：
     * page_size, calculator, date_time, emoji_suggest, horizontal, page_keys, select_keys, pick_char,
     * punct_style, auto_space, shift_toggle, translate_mode, toolbar, clipboard_history,
     * shuangpin_keys, arrow_keys, wubi, wubi_auto_commit, wubi_hint, translate_key, association,
     * auto_pair_punct, shift_double_tap, translate_one_shot。
     */
    int[] sessionConfig() {
        return new int[]{
                pageSize(),
                calculator() ? 1 : 0,
                dateTime() ? 1 : 0,
                emojiSuggest() ? 1 : 0,
                horizontal() ? 1 : 0,
                pageKeys(),
                selectKeys(),
                pickChar() ? 1 : 0,
                halfwidthPunct() ? 1 : 0,
                autoSpace(),
                shiftToggle(),
                translateReady() ? 1 : 0,
                toolbar() ? 1 : 0,
                clipboardHistory() ? 1 : 0,
                shuangpinShowKeys() ? 1 : 0,
                0, // arrow_keys：候选
                wubi() ? 1 : 0,
                wubiAutoCommit() ? 1 : 0,
                wubiHint() ? 1 : 0,
                0, // translate_key
                association() ? 1 : 0,
                autoPairPunct() ? 1 : 0,
                shiftDoubleTap() ? 1 : 0,
                translateOneShot() ? 1 : 0,
        };
    }
}
