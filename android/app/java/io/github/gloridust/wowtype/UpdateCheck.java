package io.github.gloridust.wowtype;

import android.content.Context;
import android.content.Intent;
import android.net.Uri;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;

/**
 * 检查更新：读 GitHub Releases，和当前 versionName 比。和桌面版一样默认开、可以关，
 * 「测试版」打开时预发布版本也算。只提示并打开下载页，不自动装。
 */
final class UpdateCheck {
    private static final String API =
            "https://api.github.com/repos/Gloridust/WowType/releases?per_page=15";

    interface Callback {
        void done(String version, String url);
    }

    private UpdateCheck() {}

    /** 后台线程跑，结果回主线程；没有新版本时 version 为 null。 */
    static void check(Context context, boolean beta, Callback callback) {
        new Thread(() -> {
            String version = null;
            String url = null;
            try {
                URL api = new URL(API);
                HttpURLConnection conn = (HttpURLConnection) api.openConnection();
                conn.setConnectTimeout(8000);
                conn.setReadTimeout(8000);
                conn.setRequestProperty("Accept", "application/vnd.github+json");
                StringBuilder body = new StringBuilder();
                try (InputStream in = conn.getInputStream();
                     BufferedReader reader = new BufferedReader(new InputStreamReader(in, "UTF-8"))) {
                    String line;
                    while ((line = reader.readLine()) != null) body.append(line);
                }
                JSONArray releases = new JSONArray(body.toString());
                String current = context.getPackageManager()
                        .getPackageInfo(context.getPackageName(), 0).versionName;
                for (int i = 0; i < releases.length(); i++) {
                    JSONObject release = releases.getJSONObject(i);
                    if (release.optBoolean("draft")) continue;
                    if (release.optBoolean("prerelease") && !beta) continue;
                    String tag = release.optString("tag_name", "").replaceFirst("^v", "");
                    if (tag.isEmpty()) continue;
                    if (newer(tag, current)) {
                        version = tag;
                        url = release.optString("html_url", "");
                    }
                    break;
                }
            } catch (Throwable ignored) {
                // 没网、接口不通就当没有更新，不打扰用户
            }
            final String found = version;
            final String link = url;
            new android.os.Handler(context.getMainLooper()).post(() -> callback.done(found, link));
        }, "wowtype-update").start();
    }

    static void open(Context context, String url) {
        if (url == null || url.isEmpty()) return;
        try {
            context.startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        } catch (Throwable ignored) {
        }
    }

    /** 简单的点分版本比较；0.7.10 > 0.7.9。 */
    static boolean newer(String candidate, String current) {
        String[] a = candidate.split("[^0-9]");
        String[] b = current.split("[^0-9]");
        int n = Math.max(a.length, b.length);
        for (int i = 0; i < n; i++) {
            int x = i < a.length && !a[i].isEmpty() ? Integer.parseInt(a[i]) : 0;
            int y = i < b.length && !b[i].isEmpty() ? Integer.parseInt(b[i]) : 0;
            if (x != y) return x > y;
        }
        return false;
    }
}
