package io.github.gloridust.wowtype;

/** 会话一次调用之后要做的事，和 {@code WowtypeFrame} 一一对应（见 core/include/wowtype_core.h）。 */
public final class Frame {
    /** 会话处理了这个键；false 时交给应用（软键盘自己把字打进去）。 */
    public final boolean handled;
    /** 要上屏的字，没有是 null。 */
    public final String commit;
    /** 编辑区（拼音），不为 null，可能为空串。 */
    public final String preedit;
    /** 编辑区光标（UTF-8 字节偏移）。 */
    public final int preeditCursor;
    /** 候选框上方的一行提示（五笔空码、没有码表），没有是 null。 */
    public final String aux;
    /** 0 普通一页，1 展开面板，2 表情面板，3 工具栏。 */
    public final int panel;
    public final int candCount;
    /** 光标在这一页里的位置，-1 是翻走了。 */
    public final int candCursor;
    public final boolean hasPrev;
    public final boolean hasNext;
    public final int mode;
    public final boolean modeChanged;
    public final boolean learned;
    public final boolean forgot;
    public final String[] candidates;
    public final String[] comments;

    Frame(boolean handled, String commit, String preedit, int preeditCursor, String aux, int panel,
          int candCount, int candCursor, boolean hasPrev, boolean hasNext, int mode,
          boolean modeChanged, boolean learned, boolean forgot, String[] candidates, String[] comments) {
        this.handled = handled;
        this.commit = commit;
        this.preedit = preedit;
        this.preeditCursor = preeditCursor;
        this.aux = aux;
        this.panel = panel;
        this.candCount = candCount;
        this.candCursor = candCursor;
        this.hasPrev = hasPrev;
        this.hasNext = hasNext;
        this.mode = mode;
        this.modeChanged = modeChanged;
        this.learned = learned;
        this.forgot = forgot;
        this.candidates = candidates;
        this.comments = comments;
    }

    static Frame empty() {
        return new Frame(false, null, "", 0, null, 0, 0, -1, false, false, 0, false, false, false,
                new String[0], new String[0]);
    }

    static Frame from(Object[] a) {
        if (a == null || a.length < 16) return empty();
        String[] candidates = (String[]) a[14];
        String[] comments = (String[]) a[15];
        return new Frame(
                ((Integer) a[0]) != 0,
                (String) a[1],
                a[2] == null ? "" : (String) a[2],
                ((Integer) a[3]),
                (String) a[4],
                ((Integer) a[5]),
                ((Integer) a[6]),
                ((Integer) a[7]),
                ((Boolean) a[8]),
                ((Boolean) a[9]),
                ((Integer) a[10]),
                ((Boolean) a[11]),
                ((Boolean) a[12]),
                ((Boolean) a[13]),
                candidates == null ? new String[0] : candidates,
                comments == null ? new String[0] : comments);
    }

    public boolean isComposing() {
        return preedit != null && !preedit.isEmpty();
    }
}
