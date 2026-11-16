package io.github.gloridust.wowtype;

import android.content.Context;
import android.content.res.AssetManager;
import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.Charset;

/**
 * 把 APK 里的词库、语言模型解到应用私有目录。第一次装完（或者换了词库版本）时解一次，
 * 之后用 {@code .version} 标记跳过。
 *
 * 只用 API 24 就有的类：不碰 java.nio.file，也不用 InputStream.readAllBytes。
 */
final class DataFiles {
    private static final String TAG = "WowType";
    private static final String ASSET_DIR = "wowtype";
    private static final Charset UTF8 = Charset.forName("UTF-8");
    /** 一起解出来的文件；words.lm 可以没有，词库不行。 */
    private static final String[] FILES = {
            "lexicon.tsv", "english.txt", "words.lm", "LICENSE", "SOURCE.txt",
    };

    private DataFiles() {}

    static final class Paths {
        final File lexicon;
        final File wordsLm;
        final File english;
        final File userDict;
        final File history;
        final File recentEmoji;

        Paths(File lexicon, File wordsLm, File english, File userDict, File history, File recentEmoji) {
            this.lexicon = lexicon;
            this.wordsLm = wordsLm;
            this.english = english;
            this.userDict = userDict;
            this.history = history;
            this.recentEmoji = recentEmoji;
        }
    }

    static Paths ensure(Context context) throws IOException {
        File root = new File(context.getFilesDir(), "wowtype");
        File versionFile = new File(root, ".version");
        String want = readAssetVersion(context);
        if (!root.isDirectory() || !versionFile.isFile() || !want.equals(readString(versionFile))) {
            if (!root.isDirectory() && !root.mkdirs()) throw new IOException("建不了目录 " + root);
            extract(context.getAssets(), root);
            writeString(versionFile, want);
        }
        return new Paths(
                new File(root, "lexicon.tsv"),
                new File(root, "words.lm"),
                new File(root, "english.txt"),
                new File(root, "userdict.tsv"),
                new File(root, "history.tsv"),
                new File(root, "recent-emoji.txt"));
    }

    /** 解好的数据目录里各文件的路径；没解过时是空的路径，调用方按存在与否判断。 */
    static Paths paths(Context context) {
        File root = new File(context.getFilesDir(), "wowtype");
        return new Paths(
                new File(root, "lexicon.tsv"),
                new File(root, "words.lm"),
                new File(root, "english.txt"),
                new File(root, "userdict.tsv"),
                new File(root, "history.tsv"),
                new File(root, "recent-emoji.txt"));
    }

    private static String readAssetVersion(Context context) {
        try (InputStream in = context.getAssets().open(ASSET_DIR + "/VERSION")) {
            return new String(readAll(in), UTF8).trim();
        } catch (IOException e) {
            Log.w(TAG, "APK 里没有词库版本，按当前文件算", e);
            return "unknown";
        }
    }

    private static void extract(AssetManager assets, File root) throws IOException {
        byte[] buffer = new byte[256 * 1024];
        for (String name : FILES) {
            File out = new File(root, name);
            File tmp = new File(root, name + ".tmp");
            try (InputStream in = assets.open(ASSET_DIR + "/" + name);
                 OutputStream os = new FileOutputStream(tmp)) {
                int n;
                while ((n = in.read(buffer)) > 0) os.write(buffer, 0, n);
            } catch (IOException e) {
                if ("words.lm".equals(name)) {
                    Log.w(TAG, "APK 里没有 words.lm，只用词库", e);
                    continue;
                }
                throw e;
            }
            if (out.exists() && !out.delete()) throw new IOException("删不掉旧文件 " + out);
            if (!tmp.renameTo(out)) throw new IOException("改名失败 " + tmp);
            Log.i(TAG, "解出 " + name + "（" + out.length() + " 字节）");
        }
        // 和 assets 里的 VERSION 比对，换了词库才重解
        try (InputStream in = assets.open(ASSET_DIR + "/VERSION")) {
            writeString(new File(root, "VERSION"), new String(readAll(in), UTF8));
        }
    }

    private static byte[] readAll(InputStream in) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buffer = new byte[16 * 1024];
        int n;
        while ((n = in.read(buffer)) > 0) out.write(buffer, 0, n);
        return out.toByteArray();
    }

    private static String readString(File file) {
        try (InputStream in = new FileInputStream(file)) {
            return new String(readAll(in), UTF8).trim();
        } catch (IOException e) {
            return "";
        }
    }

    private static void writeString(File file, String text) throws IOException {
        try (OutputStream os = new FileOutputStream(file)) {
            os.write(text.getBytes(UTF8));
        }
    }
}
