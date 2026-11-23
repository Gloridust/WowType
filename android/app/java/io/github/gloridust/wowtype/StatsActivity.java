package io.github.gloridust.wowtype;

import android.app.Activity;
import android.os.Bundle;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Date;
import java.util.Iterator;
import java.util.List;
import java.util.Locale;

/**
 * 打字统计：读输入法写的 stats.json（只读，不碰计数），显示今天 / 累计、字符、活跃时长、
 * 候选命中位置和前几个键。清除走核心的 wowtype_stats_clear。
 */
public final class StatsActivity extends Activity {
    private Theme theme;
    private TextView summary;
    private TextView status;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        theme = Theme.get(this);
        Prefs prefs = Prefs.get(this);

        LinearLayout column = new LinearLayout(this);
        column.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(20);
        column.setPadding(pad, pad, pad, pad);
        column.setBackgroundColor(theme.background);

        TextView title = new TextView(this);
        title.setText("打字统计");
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 28);
        title.setTextColor(theme.text);
        title.setTypeface(android.graphics.Typeface.DEFAULT_BOLD);
        column.addView(title);

        status = new TextView(this);
        status.setText(prefs.typingStats()
                ? "只在本机按天记聚合计数，不记打的字、拼音和按键顺序。"
                : "统计默认关：回「输入设置」打开「打字统计」后才开始记。");
        status.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        status.setTextColor(theme.muted);
        status.setPadding(0, dp(12), 0, dp(12));
        column.addView(status);

        summary = new TextView(this);
        summary.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        summary.setTextColor(theme.text);
        summary.setLineSpacing(dp(4), 1f);
        column.addView(summary);

        Button clear = new Button(this);
        clear.setAllCaps(false);
        clear.setText("清除统计");
        clear.setTextColor(0xFFFFFFFF);
        clear.setBackgroundColor(theme.accent);
        clear.setOnClickListener(v -> {
            StatsHost.get().clear();
            reload();
        });
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        params.setMargins(0, dp(20), 0, 0);
        column.addView(clear, params);

        ScrollView scroll = new ScrollView(this);
        scroll.addView(column);
        setContentView(scroll);
        reload();
    }

    private void reload() {
        String text = readStatsFile();
        if (text == null) {
            summary.setText("还没有统计数据。打开统计并打几个字，再回来看。");
            summary.setGravity(Gravity.START);
            return;
        }
        try {
            summary.setText(format(new JSONObject(text)));
        } catch (Throwable t) {
            summary.setText("统计文件读不了：" + t);
        }
    }

    private String format(JSONObject root) {
        JSONObject days = root.optJSONObject("days");
        if (days == null || days.length() == 0) return "还没有统计数据。";
        String today = new SimpleDateFormat("yyyy-MM-dd", Locale.US).format(new Date());
        long chars = 0, active = 0;
        long[] selections = new long[9];
        long beyond = 0;
        java.util.HashMap<String, Long> keys = new java.util.HashMap<>();
        int dayCount = 0;
        JSONObject todayObject = days.optJSONObject(today);
        long todayChars = todayObject == null ? 0 : todayObject.optLong("chars");
        long todayActive = todayObject == null ? 0 : todayObject.optLong("activeMs");

        for (Iterator<String> it = days.keys(); it.hasNext(); ) {
            String day = it.next();
            JSONObject d = days.optJSONObject(day);
            if (d == null) continue;
            dayCount++;
            chars += d.optLong("chars");
            active += d.optLong("activeMs");
            org.json.JSONArray sel = d.optJSONArray("selections");
            if (sel != null) {
                for (int i = 0; i < 9 && i < sel.length(); i++) selections[i] += sel.optLong(i);
            }
            beyond += d.optLong("beyond");
            JSONObject dayKeys = d.optJSONObject("keys");
            if (dayKeys != null) {
                for (Iterator<String> k = dayKeys.keys(); k.hasNext(); ) {
                    String name = k.next();
                    keys.put(name, keys.getOrDefault(name, 0L) + dayKeys.optLong(name));
                }
            }
        }

        StringBuilder out = new StringBuilder();
        out.append("今天：").append(todayChars).append(" 字，活跃 ")
                .append(minutes(todayActive)).append('\n');
        out.append("累计：").append(dayCount).append(" 天，").append(chars).append(" 字，活跃 ")
                .append(hours(active)).append('\n');
        out.append("候选位置：");
        for (int i = 0; i < 9; i++) {
            out.append(i + 1).append(':').append(selections[i]).append(' ');
        }
        out.append("10+:").append(beyond).append('\n');
        List<java.util.Map.Entry<String, Long>> top = new ArrayList<>(keys.entrySet());
        Collections.sort(top, (a, b) -> Long.compare(b.getValue(), a.getValue()));
        out.append("按键：");
        for (int i = 0; i < Math.min(8, top.size()); i++) {
            if (i > 0) out.append("  ");
            out.append(top.get(i).getKey()).append(' ').append(top.get(i).getValue());
        }
        if (top.isEmpty()) out.append("还没有（软键盘按键不计，外接键盘才有）");
        return out.toString();
    }

    private String minutes(long ms) {
        long minutes = ms / 60000;
        return minutes < 1 ? "不到 1 分钟" : minutes + " 分钟";
    }

    private String hours(long ms) {
        long minutes = ms / 60000;
        if (minutes < 1) return "不到 1 分钟";
        return minutes < 60 ? minutes + " 分钟" : (minutes / 60) + " 小时 " + (minutes % 60) + " 分钟";
    }

    private String readStatsFile() {
        String path = StatsHost.get().path();
        if (path == null) return null;
        File file = new File(path);
        if (!file.isFile()) return null;
        try (InputStream in = new FileInputStream(file)) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buffer = new byte[16 * 1024];
            int n;
            while ((n = in.read(buffer)) > 0) out.write(buffer, 0, n);
            return new String(out.toByteArray(), "UTF-8");
        } catch (Throwable t) {
            return null;
        }
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
