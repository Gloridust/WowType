package io.github.gloridust.wowtype;

/**
 * 主机 JVM 上的 JNI + 会话冒烟测试（不需要 Android 设备，android/test.sh 跑它）。
 *
 * 验的是 APK 里真正跑的那一层：{@code wowtype_jni.c} 的 UTF-8 → jstring、frame 打包，
 * 以及核心会话的拼音、候选、空格选词、回车原样上屏、退格、中英切换、emoji（四字节 UTF-8）。
 */
public final class NativeTest {
    private static int checks;
    private static int failures;

    public static void main(String[] args) {
        String dir = args.length > 0 ? args[0] : "dist/data";
        try {
            run(dir);
        } catch (Throwable t) {
            failures++;
            System.out.println("FAIL 异常：" + t);
            t.printStackTrace(System.out);
        }
        System.out.println();
        System.out.println(checks + " 项检查，" + (failures == 0 ? "全部通过" : failures + " 项失败"));
        if (failures != 0) System.exit(1);
    }

    private static void run(String dir) {
        int abi = Native.version();
        check(abi / 1000 == 1, "ABI 主版本是 1（实际 " + abi + "）");

        long engine = Native.newEngine(
                dir + "/lexicon.tsv", dir + "/words.lm", dir + "/english.txt",
                null, null, null);
        check(engine != 0, "载入 " + dir + "/lexicon.tsv");
        if (engine == 0) return;

        try (Session session = new Session(engine)) {
            check(session.isOpen(), "建会话");

            type(session, "nihao");
            Frame frame = session.frame();
            check("ni'hao".equals(frame.preedit), "编辑区分好音节：" + frame.preedit);
            check(frame.candidates.length == frame.candCount, "候选数组和 candCount 一致");
            check(frame.candCount > 0, "有候选（" + frame.candCount + " 个）");
            check("你好".equals(first(frame)), "第一个候选是「你好」，实际 " + first(frame));

            Frame commit = session.press(Session.KEY_SPACE, 0, 0, 0);
            check("你好".equals(commit.commit), "空格上屏第一个候选，实际 " + commit.commit);
            check(commit.isComposing() == false, "上屏后编辑区空了");
        }

        // 回车：拼音原样上屏
        try (Session session = new Session(engine)) {
            type(session, "nihao");
            Frame commit = session.press(Session.KEY_RETURN, 0, 0, 0);
            check("nihao".equals(commit.commit), "回车把拼音原样上屏，实际 " + commit.commit);
        }

        // 退格删一个字母
        try (Session session = new Session(engine)) {
            type(session, "nihao");
            Frame frame = session.press(Session.KEY_BACKSPACE, 0, 0, 0);
            check("ni'ha".equals(frame.preedit), "退格删一个字母（编辑区还是分好音节的），实际 " + frame.preedit);
        }

        // 按错顺序：weixni -> 微信
        try (Session session = new Session(engine)) {
            type(session, "weixni");
            Frame frame = session.frame();
            check("微信".equals(first(frame)), "weixni 的第一个候选是「微信」，实际 " + first(frame));
        }

        // 点候选（鼠标 / 手指）
        try (Session session = new Session(engine)) {
            type(session, "zhongg");
            Frame frame = session.frame();
            check("中国".equals(first(frame)), "zhongg 的第一个候选是「中国」，实际 " + first(frame));
            Frame commit = session.select(0);
            check("中国".equals(commit.commit), "点第一个候选上屏「中国」，实际 " + commit.commit);
        }

        // 中 / 英：切到英文后字母交给应用（handled = false）
        try (Session session = new Session(engine)) {
            Frame mode = session.tap(Session.ACTION_TOGGLE_MODE, 0);
            check(mode.handled && mode.mode == Session.MODE_ENGLISH, "切到英文模式");
            Frame letter = session.press('a', 0, 0, 0);
            check(!letter.handled, "英文模式下字母交给应用");
            Frame back = session.tap(Session.ACTION_TOGGLE_MODE, 0);
            check(back.handled && back.mode == Session.MODE_CHINESE, "切回中文模式");
        }

        // emoji：候选里四字节 UTF-8 要完好地过一遍 JNI（NewStringUTF 会坏，这里用的是 UTF-16）
        try (Session session = new Session(engine)) {
            type(session, "kaixin");
            Frame frame = session.frame();
            int emoji = -1;
            for (int i = 0; i < frame.candCount; i++) {
                if (frame.candidates[i].contains("\uD83D\uDE0A")) {
                    emoji = i;
                    break;
                }
            }
            if (emoji < 0) {
                System.out.println("SKIP 词库里没有「开心」的 emoji 推荐（词表问题，不算失败）");
            } else {
                Frame commit = session.select(emoji);
                check(commit.commit != null && commit.commit.contains("\uD83D\uDE0A"),
                        "选 emoji 候选上屏的字里带着 😊：" + commit.commit);
            }
        }

        // 存学习数据（不崩就行；写系统临时目录，别动词库目录）
        String tmp = System.getProperty("java.io.tmpdir");
        Native.saveState(engine, tmp + "/wowtype-userdict.tsv", tmp + "/wowtype-history.tsv");
        check(true, "保存学习数据没抛异常");
    }

    private static void type(Session session, String text) {
        for (int i = 0; i < text.length(); i++) {
            Frame frame = session.press(text.charAt(i), 0, 0, 0);
            check(frame.handled, "字母 " + text.charAt(i) + " 由会话处理");
        }
    }

    private static String first(Frame frame) {
        return frame.candCount > 0 ? frame.candidates[0] : "(没有候选)";
    }

    private static void check(boolean ok, String what) {
        checks++;
        if (!ok) {
            failures++;
            System.out.println("FAIL " + what);
        } else {
            System.out.println("ok   " + what);
        }
    }
}
