package io.github.gloridust.wowtype;

import android.content.Context;

import java.io.File;

/**
 * 打字统计（默认关）。设置里打开以后，按键和上屏只在本机记每天的聚合计数，不记内容；
 * 记录器在核心里（core/src/stats.rs），这里只转一下。关着时核心什么都不做。
 */
final class StatsHost {
    private static final StatsHost INSTANCE = new StatsHost();

    private long handle;
    private String path;
    private Context context;

    private StatsHost() {}

    static StatsHost get() {
        return INSTANCE;
    }

    void start(Context ctx) {
        if (context == null) context = ctx.getApplicationContext();
        if (handle != 0) {
            applyEnabled();
            return;
        }
        File dir = new File(context.getFilesDir(), "wowtype");
        if (!dir.isDirectory() && !dir.mkdirs()) return;
        path = new File(dir, "stats.json").getAbsolutePath();
        handle = Native.statsNew(path);
        applyEnabled();
    }

    /** 设置里的 TypingStats 变了。 */
    void applyEnabled() {
        if (handle == 0 || context == null) return;
        Native.statsSetEnabled(handle, Prefs.get(context).typingStats() ? 1 : 0);
    }

    /** 一次物理按键。sensitive 是密码框之类，整个不算。 */
    void key(int code, boolean sensitive) {
        if (handle == 0) return;
        Native.statsKey(handle, code, 1, sensitive ? 1 : 0, System.currentTimeMillis());
    }

    /** 一次上屏。source: quanpin / shuangpin / wubi / english / translate。 */
    void commit(String text, String source, String scheme, int candidate, boolean sensitive) {
        if (handle == 0 || text == null || text.isEmpty()) return;
        Native.statsCommit(handle, text, source, scheme, candidate, sensitive ? 1 : 0,
                System.currentTimeMillis());
    }

    void flush() {
        if (handle != 0) Native.statsFlush(handle, System.currentTimeMillis());
    }

    /** 设置页的「清除统计」：清空文件和内存里的计数。 */
    void clear() {
        if (path != null) Native.statsClear(path);
    }

    String path() {
        return path;
    }

    boolean enabled() {
        return handle != 0 && context != null && Prefs.get(context).typingStats();
    }
}
