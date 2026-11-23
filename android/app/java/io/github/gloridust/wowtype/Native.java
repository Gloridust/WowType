package io.github.gloridust.wowtype;

/**
 * JNI 入口（{@code android/app/jni/wowtype_jni.c}）。
 *
 * 指针都是 jlong 里的 handle，只由 {@link Session} / {@link EngineHost} 拿着。方法名和 C 那边
 * 一一对应，改一边要改另一边；{@code android/test.sh} 在主机 JVM 上把这一层跑一遍。
 */
final class Native {
    /**
     * 原生库没装上（ABI 不对、16 KB 页对齐不对、APK 里缺 .so）时记下原因。
     *
     * 以前这里直接 System.loadLibrary，类初始化失败以后 {@code Native.version()} 在设置页主线程上
     * 抛 UnsatisfiedLinkError，App 一打开就闪退，什么也看不到。现在捕获下来，设置页把原因显示出来，
     * 用户截图就能看到具体是 dlopen 失败还是找不到库。
     */
    private static Throwable loadError;

    static {
        try {
            System.loadLibrary("wowtype");
        } catch (Throwable t) {
            loadError = t;
            t.printStackTrace();
        }
    }

    private Native() {}

    /** 原生库加载失败的原因；成功是 null。 */
    static Throwable loadError() {
        return loadError;
    }

    /** 原生库可用（加载成功）。 */
    static boolean available() {
        return loadError == null;
    }

    /** 设置页状态行用：成功是 ABI 号，失败是原因；不会抛 UnsatisfiedLinkError。 */
    static String versionText() {
        if (loadError != null) return "原生库加载失败：" + describe(loadError);
        try {
            return Integer.toString(version());
        } catch (Throwable t) {
            return "原生库加载失败：" + describe(t);
        }
    }

    private static String describe(Throwable t) {
        StringBuilder text = new StringBuilder(t.toString());
        for (Throwable cause = t.getCause(); cause != null; cause = cause.getCause()) {
            text.append(" / ").append(cause);
        }
        return text.toString();
    }

    static native int version();

    static native long newEngine(String lexicon, String bigram, String english,
                                 String userDict, String history, String recentEmoji);

    /* 引擎设置（和在桌面外壳里设的是同一组 C 函数） */
    static native void setFuzzy(long engine, int on, int groups);

    static native void setShuangpin(long engine, int on, String scheme, int abbrev);

    static native void setTypo(long engine, int on);

    static native void setRareExt(long engine, int on);

    static native void setTraditional(long engine, int on);

    /** 载入繁简转换表（s2t.tsv）；没载入时繁体开关不生效。 */
    static native void loadConversion(long engine, String path);

    /** 载入五笔 86 码表（wubi86.tsv）。 */
    static native void loadWubi(long engine, String path);

    /** 重新读自定义词（custom.tsv）。 */
    static native void loadCustomWords(long engine, String path);

    /** 自定义词列表（custom.tsv 的顺序）。 */
    static native String[] customPhrases(long engine);

    static native void saveState(long engine, String userDict, String history);

    static native void freeEngine(long engine);

    static native long newSession(long engine, int[] config);

    static native void configureSession(long session, int[] config);

    /** 读系统剪贴板后交给核心（工具栏「剪贴板」页）。 */
    static native void clipboardRemember(String text);

    /** Super + . 的表情面板。 */
    static native Object[] toggleEmoji(long session);

    /** 「译」的 Java 翻译器；null 表示关掉。用 Object 是为了主机 JVM 测试不用编 TranslateHost。 */
    static native void setTranslateBackend(long session, Object host);

    static native void freeSession(long session);

    static native void setEngine(long session, long engine);

    static native Object[] key(long session, int keysym, int modifiers, boolean release,
                               int prevChar, int action, int hints, int code, boolean repeat,
                               long timeMs);

    static native Object[] frame(long session);

    static native Object[] tick(long session, long nowMs);

    static native Object[] select(long session, int index);

    static native Object[] reset(long session, boolean commitPending);

    static native Object[] setMode(long session, int mode);

    static native int mode(long session);

    static native String input(long session);

    /* 打字统计（默认关，设置里打开） */
    static native long statsNew(String path);

    static native void statsFree(long stats);

    static native void statsSetEnabled(long stats, int enabled);

    static native void statsKey(long stats, int code, int down, int flags, long nowMs);

    static native void statsCommit(long stats, String text, String source, String scheme,
                                   int candidate, int flags, long nowMs);

    static native void statsFlush(long stats, long nowMs);

    static native int statsClear(String path);
}
