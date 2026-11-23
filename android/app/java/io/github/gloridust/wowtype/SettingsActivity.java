package io.github.gloridust.wowtype;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.os.Bundle;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.ViewGroup;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Spinner;
import android.widget.Switch;
import android.widget.TextView;

/**
 * 输入设置。桌面版设置窗口里的输入相关项在这里都有对应；改完马上写进 SharedPreferences，
 * 输入法服务监听到以后会 applySettings / 重建会话配置。
 *
 * 全部用代码搭界面（和 SetupActivity 一样，不引 layout XML）。
 */
public final class SettingsActivity extends Activity {
    private Theme theme;

    private Prefs prefs;
    private LinearLayout column;

    private static final String[] FUZZY_LABELS = {
            "z = zh", "c = ch", "s = sh", "n = l", "f = h", "r = l",
            "an = ang", "en = eng", "in = ing", "ian = iang", "uan = uang",
            "un = ong", "an = ai", "huang = wang", "un = iong", "eng = ong",
    };
    private static final int[] FUZZY_BITS = {
            Prefs.FZ_ZH, Prefs.FZ_CH, Prefs.FZ_SH, Prefs.FZ_NL, Prefs.FZ_FH, Prefs.FZ_RL,
            Prefs.FZ_AN, Prefs.FZ_EN, Prefs.FZ_IN, Prefs.FZ_IAN, Prefs.FZ_UAN,
            Prefs.FZ_UN, Prefs.FZ_AN_AI, Prefs.FZ_HUANG_WANG, Prefs.FZ_UN_IONG, Prefs.FZ_ENG_ONG,
    };
    private static final String[] PAGE_KEY_LABELS = {"- / =", "[ ]", ", .", "Tab"};
    private static final int[] PAGE_KEY_BITS = {
            Prefs.PAGE_MINUS, Prefs.PAGE_BRACKET, Prefs.PAGE_COMMA, Prefs.PAGE_TAB,
    };

    private TextView fuzzySummary;
    private TextView pageKeySummary;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        prefs = Prefs.get(this);
        theme = Theme.get(this);

        column = new LinearLayout(this);
        column.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(20);
        column.setPadding(pad, pad, pad, pad);
        column.setBackgroundColor(theme.background);

        TextView title = new TextView(this);
        title.setText("输入设置");
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 28);
        title.setTextColor(theme.text);
        title.setTypeface(android.graphics.Typeface.DEFAULT_BOLD);
        column.addView(title);

        section("外观");
        choice("颜色", new String[]{"跟随系统", "浅色", "深色"},
                new String[]{"System", "Light", "Dark"}, "SettingsTheme", "System", false);

        section("输入方案");
        choice("输入方案", new String[]{"全拼", "双拼", "五笔 86"},
                new String[]{"Quanpin", "Shuangpin", "Wubi"}, "InputScheme", "Quanpin", true);
        choice("双拼方案", Prefs.SHUANGPIN_NAMES, Prefs.SHUANGPIN_SCHEMES,
                "ShuangpinScheme", "ziranma", true);
        toggle("双拼时编辑区显示按键", "ShuangpinShowKeys", false, false);
        toggle("双拼简拼", "ShuangpinAbbrev", true, true);

        section("候选");
        choice("候选排列", new String[]{"横排", "竖排"},
                new String[]{"Horizontal", "Vertical"}, "CandidateLayout", "Horizontal", false);
        int pageSize = prefs.pageSize();
        String[] sizes = new String[7];
        String[] sizeValues = new String[7];
        for (int i = 0; i < 7; i++) {
            sizes[i] = String.valueOf(i + 3);
            sizeValues[i] = String.valueOf(i + 3);
        }
        choice("每页候选数", sizes, sizeValues, "PageSize", String.valueOf(pageSize), false);
        toggle("以词定字（[ ]）", "PickChar", true, false);
        toggle("上屏后联想", "Association", false, false);

        section("拼音");
        toggle("模糊音", "Fuzzy", false, true);
        fuzzySummary = button("模糊音分组",
                summary(prefs.fuzzyGroups(), FUZZY_BITS, "组"), this::pickFuzzyGroups);
        toggle("按错键也能认出来", "TypoCorrection", true, true);
        toggle("生僻扩展字", "RareExtChars", false, true);

        section("标点与空格");
        choice("标点", new String[]{"全角（中文标点）", "半角"},
                new String[]{"Fullwidth", "Halfwidth"}, "PunctuationStyle", "Fullwidth", false);
        toggle("中文和英文之间自动加空格", "AutoSpace", false, false);
        toggle("  汉字和字母之间", "AutoSpaceLetters", true, false);
        toggle("  汉字和数字之间", "AutoSpaceDigits", true, false);
        pageKeySummary = button("翻页键",
                summary(prefs.pageKeys(), PAGE_KEY_BITS, "个"), this::pickPageKeys);
        choice("分号 / 引号选词", new String[]{"关", "分号选第 2 个", "分号 + 引号"},
                new String[]{"0", "1", "2"}, "SelectKeys", "0", false);

        section("模式");
        choice("单按 Shift", new String[]{"两边", "左 Shift", "右 Shift", "关"},
                new String[]{"0", "1", "2", "3"}, "ShiftToggle", "0", false);
        choice("默认模式", new String[]{"中文", "英文"},
                new String[]{"Chinese", "English"}, "InitialMode", "Chinese", false);
        toggle("繁体输出", "Traditional", false, true);

        section("功能");
        toggle("日期时间候选", "DateTime", true, false);
        toggle("计算器（v1+2*3）", "Calculator", true, false);
        toggle("打字推荐 emoji", "EmojiSuggest", true, false);
        toggle("工具栏（v + 空格）", "Toolbar", true, false);
        toggle("剪贴板历史（最近 20 条，只在内存）", "ClipboardHistory", false, false);
        toggle("打字统计（只记本机聚合计数）", "TypingStats", false, false);
        toggle("检查更新", "CheckUpdate", true, false);
        toggle("测试版更新", "BetaUpdates", false, false);
        button("查看统计", "打开", () -> startActivity(new Intent(this, StatsActivity.class)));
        button("管理自定义词", "打开",
                () -> startActivity(new Intent(this, CustomWordsActivity.class)));

        ScrollView scroll = new ScrollView(this);
        scroll.addView(column);
        setContentView(scroll);
    }

    // ---- 界面小工具 ----

    private void section(String label) {
        TextView text = new TextView(this);
        text.setText(label);
        text.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
        text.setTextColor(theme.accent);
        text.setPadding(0, dp(22), 0, dp(4));
        column.addView(text);
    }

    private void toggle(String label, String key, boolean fallback, boolean engineLevel) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        TextView text = rowLabel(label);
        row.addView(text, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        Switch toggle = new Switch(this);
        toggle.setTextOn("开");
        toggle.setTextOff("关");
        toggle.setChecked(prefs.bool(key, fallback));
        toggle.setOnCheckedChangeListener((button, checked) -> {
            prefs.set(key, checked);
            if (engineLevel) EngineHost.get().applySettings();
        });
        row.addView(toggle);
        column.addView(row);
    }

    private void choice(String label, String[] labels, String[] values, String key,
                        String fallback, boolean engineLevel) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.addView(rowLabel(label), new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        Spinner spinner = new Spinner(this);
        ArrayAdapter<String> adapter = new ArrayAdapter<>(this,
                android.R.layout.simple_spinner_item, labels);
        adapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
        spinner.setAdapter(adapter);
        String current = prefs.string(key, fallback);
        for (int i = 0; i < values.length; i++) {
            if (values[i].equals(current)) {
                spinner.setSelection(i, false);
                break;
            }
        }
        spinner.setOnItemSelectedListener(new android.widget.AdapterView.OnItemSelectedListener() {
            @Override
            public void onItemSelected(android.widget.AdapterView<?> parent,
                                       android.view.View view, int position, long id) {
                if (position < 0 || position >= values.length) return;
                if (values[position].equals(prefs.string(key, fallback))) return;
                prefs.set(key, values[position]);
                if (engineLevel) EngineHost.get().applySettings();
                if ("SettingsTheme".equals(key)) recreate();
            }

            @Override
            public void onNothingSelected(android.widget.AdapterView<?> parent) {
            }
        });
        row.addView(spinner, new LinearLayout.LayoutParams(dp(180),
                ViewGroup.LayoutParams.WRAP_CONTENT));
        column.addView(row);
    }

    private TextView button(String label, String summary, Runnable onClick) {
        Button button = new Button(this);
        button.setAllCaps(false);
        button.setText(label + "：" + summary);
        button.setTextColor(0xFFFFFFFF);
        button.setBackgroundColor(theme.accent);
        button.setOnClickListener(v -> onClick.run());
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        params.setMargins(0, dp(8), 0, dp(8));
        column.addView(button, params);
        return button;
    }

    private TextView rowLabel(String label) {
        TextView text = new TextView(this);
        text.setText(label);
        text.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        text.setTextColor(theme.text);
        text.setPadding(0, dp(8), dp(8), dp(8));
        return text;
    }

    private String summary(int mask, int[] bits, String suffix) {
        int n = 0;
        for (int bit : bits) if ((mask & bit) != 0) n++;
        return n == 0 ? "关" : n + " " + suffix;
    }

    private void pickFuzzyGroups() {
        boolean[] checked = new boolean[FUZZY_BITS.length];
        int mask = prefs.fuzzyGroups();
        for (int i = 0; i < FUZZY_BITS.length; i++) checked[i] = (mask & FUZZY_BITS[i]) != 0;
        new AlertDialog.Builder(this)
                .setTitle("模糊音分组")
                .setMultiChoiceItems(FUZZY_LABELS, checked,
                        (dialog, which, isChecked) -> checked[which] = isChecked)
                .setPositiveButton("确定", (dialog, which) -> {
                    int next = 0;
                    for (int i = 0; i < FUZZY_BITS.length; i++) if (checked[i]) next |= FUZZY_BITS[i];
                    prefs.set("FuzzyGroups", next);
                    fuzzySummary.setText("模糊音分组：" + summary(next, FUZZY_BITS, "组"));
                    EngineHost.get().applySettings();
                })
                .setNegativeButton("取消", null)
                .show();
    }

    private void pickPageKeys() {
        boolean[] checked = new boolean[PAGE_KEY_BITS.length];
        int mask = prefs.pageKeys();
        for (int i = 0; i < PAGE_KEY_BITS.length; i++) checked[i] = (mask & PAGE_KEY_BITS[i]) != 0;
        new AlertDialog.Builder(this)
                .setTitle("翻页键（外接键盘）")
                .setMultiChoiceItems(PAGE_KEY_LABELS, checked,
                        (dialog, which, isChecked) -> checked[which] = isChecked)
                .setPositiveButton("确定", (dialog, which) -> {
                    int next = 0;
                    for (int i = 0; i < PAGE_KEY_BITS.length; i++) if (checked[i]) next |= PAGE_KEY_BITS[i];
                    prefs.set("PageKeys", next);
                    pageKeySummary.setText("翻页键：" + summary(next, PAGE_KEY_BITS, "个"));
                })
                .setNegativeButton("取消", null)
                .show();
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
