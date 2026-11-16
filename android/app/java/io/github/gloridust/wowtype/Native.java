package io.github.gloridust.wowtype;

/**
 * JNI 入口（{@code android/app/jni/wowtype_jni.c}）。
 *
 * 指针都是 jlong 里的 handle，只由 {@link Session} / {@link EngineHost} 拿着。方法名和 C 那边
 * 一一对应，改一边要改另一边；{@code android/test.sh} 在主机 JVM 上把这一层跑一遍。
 */
final class Native {
    static {
        System.loadLibrary("wowtype");
    }

    private Native() {}

    static native int version();

    static native long newEngine(String lexicon, String bigram, String english,
                                 String userDict, String history, String recentEmoji);

    static native void saveState(long engine, String userDict, String history);

    static native void freeEngine(long engine);

    static native long newSession(long engine);

    static native void freeSession(long session);

    static native void setEngine(long session, long engine);

    static native Object[] key(long session, int keysym, int modifiers, boolean release,
                               int prevChar, int action, int hints, int code, boolean repeat,
                               long timeMs);

    static native Object[] frame(long session);

    static native Object[] select(long session, int index);

    static native Object[] reset(long session, boolean commitPending);

    static native Object[] setMode(long session, int mode);

    static native int mode(long session);

    static native String input(long session);
}
