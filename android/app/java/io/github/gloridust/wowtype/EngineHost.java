package io.github.gloridust.wowtype;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * 引擎：一个进程一份，所有输入框共用。词库 929k 条，不能在主线程载入：
 * 这里在后台线程解数据、建引擎，好了通知输入法和设置界面。
 *
 * 指针在后台线程建好，之后主线程的会话只是引用它（docs/ABI.md：引擎句柄可以跨线程）。
 * 学习数据（用户词库、输入习惯）也在同一后台线程写，免得大词库保存时卡输入。
 */
final class EngineHost {
    private static final String TAG = "WowType";
    private static final EngineHost INSTANCE = new EngineHost();

    interface Listener {
        void onEngineReady();
    }

    static EngineHost get() {
        return INSTANCE;
    }

    private final ExecutorService worker = Executors.newSingleThreadExecutor(runnable -> {
        Thread t = new Thread(runnable, "wowtype-engine");
        t.setPriority(Thread.NORM_PRIORITY - 1);
        return t;
    });
    private final Handler main = new Handler(Looper.getMainLooper());
    private final CopyOnWriteArrayList<Listener> listeners = new CopyOnWriteArrayList<>();

    private volatile long handle;
    private volatile boolean loading;
    private volatile boolean failed;
    private volatile String failure = "";
    private Context appContext;

    private EngineHost() {}

    long handle() {
        return handle;
    }

    boolean isLoading() {
        return loading;
    }

    /** 设置界面显示的一行状态。 */
    String status() {
        if (handle != 0) return "词库已载入";
        if (failed) return "词库载入失败：" + failure;
        if (loading) return "正在载入词库…";
        return "词库还没载入";
    }

    void start(Context context, Listener listener) {
        if (context != null) appContext = context.getApplicationContext();
        Context ctx = appContext;
        if (listener != null) {
            listeners.add(listener);
            if (handle != 0) main.post(listener::onEngineReady);
        }
        if (ctx == null || handle != 0 || loading || failed) return;
        loading = true;
        worker.execute(() -> {
            try {
                DataFiles.Paths paths = DataFiles.ensure(ctx);
                long created = Native.newEngine(
                        paths.lexicon.getAbsolutePath(),
                        paths.wordsLm.exists() ? paths.wordsLm.getAbsolutePath() : null,
                        paths.english.getAbsolutePath(),
                        paths.userDict.getAbsolutePath(),
                        paths.history.getAbsolutePath(),
                        paths.recentEmoji.getAbsolutePath());
                if (created == 0) {
                    failed = true;
                    failure = "引擎没建起来（词库文件坏了？）";
                } else {
                    handle = created;
                    Log.i(TAG, "词库载入完成，ABI " + Native.version());
                }
            } catch (Throwable t) {
                failed = true;
                failure = t.getMessage() == null ? t.toString() : t.getMessage();
                Log.e(TAG, "载入词库失败", t);
            } finally {
                loading = false;
                main.post(this::notifyReady);
            }
        });
    }

    private void notifyReady() {
        for (Listener listener : listeners) listener.onEngineReady();
    }

    void removeListener(Listener listener) {
        listeners.remove(listener);
    }

    /** 选了词、忘掉词以后马上存学习数据（和桌面版一样：learned / forgot 时才存）。 */
    void save() {
        long engine = handle;
        Context ctx = appContext;
        if (engine == 0 || ctx == null) return;
        DataFiles.Paths paths = DataFiles.paths(ctx);
        worker.execute(() -> {
            try {
                synchronized (Session.ENGINE_LOCK) {
                    Native.saveState(engine, paths.userDict.getAbsolutePath(), paths.history.getAbsolutePath());
                }
            } catch (Throwable t) {
                Log.w(TAG, "存学习数据失败", t);
            }
        });
    }
}
