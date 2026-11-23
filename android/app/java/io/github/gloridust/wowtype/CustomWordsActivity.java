package io.github.gloridust.wowtype;

import android.app.Activity;
import android.app.AlertDialog;
import android.os.Bundle;
import android.text.InputType;
import android.util.TypedValue;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.List;

/**
 * 自定义词（常用语）管理：列表、添加、删除，写和桌面同一个 custom.tsv 格式（拼音/编码&lt;TAB&gt;词）。
 * 改完立刻让引擎重新读，不用重启输入法。
 */
public final class CustomWordsActivity extends Activity {
    private Theme theme;
    private LinearLayout list;
    private TextView hint;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        theme = Theme.get(this);

        LinearLayout column = new LinearLayout(this);
        column.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(20);
        column.setPadding(pad, pad, pad, pad);
        column.setBackgroundColor(theme.background);

        TextView title = new TextView(this);
        title.setText("自定义词");
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 28);
        title.setTextColor(theme.text);
        title.setTypeface(android.graphics.Typeface.DEFAULT_BOLD);
        column.addView(title);

        hint = new TextView(this);
        hint.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        hint.setTextColor(theme.muted);
        hint.setPadding(0, dp(10), 0, dp(10));
        column.addView(hint);

        column.addView(button("添加自定义词", this::addDialog));
        list = new LinearLayout(this);
        list.setOrientation(LinearLayout.VERTICAL);
        column.addView(list);

        ScrollView scroll = new ScrollView(this);
        scroll.addView(column);
        setContentView(scroll);
        reload();
    }

    private void reload() {
        list.removeAllViews();
        String[] words = EngineHost.get().customPhrases();
        hint.setText(words.length == 0
                ? "还没有自定义词。加一个词或编码（mail、wfyx），打它就会排第一。"
                : "共 " + words.length + " 条。");
        for (int i = 0; i < words.length; i++) {
            final int index = i;
            LinearLayout row = new LinearLayout(this);
            row.setOrientation(LinearLayout.HORIZONTAL);
            row.setGravity(android.view.Gravity.CENTER_VERTICAL);
            TextView text = new TextView(this);
            text.setText(words[i].replace('\n', ' '));
            text.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
            text.setTextColor(theme.text);
            text.setPadding(0, dp(10), dp(8), dp(10));
            row.addView(text, new LinearLayout.LayoutParams(0,
                    ViewGroup.LayoutParams.WRAP_CONTENT, 1));
            Button delete = new Button(this);
            delete.setAllCaps(false);
            delete.setText("删除");
            delete.setTextColor(0xFFFFFFFF);
            delete.setBackgroundColor(theme.accent);
            delete.setOnClickListener(v -> {
                removeLine(index);
                EngineHost.get().reloadCustom();
                reload();
            });
            row.addView(delete);
            list.addView(row);
        }
    }

    private void addDialog() {
        LinearLayout form = new LinearLayout(this);
        form.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(16);
        form.setPadding(pad, pad, pad, pad);
        EditText code = new EditText(this);
        code.setHint("拼音或编码（可空，如 mail / wang fei）");
        code.setInputType(InputType.TYPE_CLASS_TEXT);
        form.addView(code);
        EditText word = new EditText(this);
        word.setHint("词（人名、公司、长句）");
        word.setInputType(InputType.TYPE_CLASS_TEXT);
        form.addView(word);

        new AlertDialog.Builder(this)
                .setTitle("添加自定义词")
                .setView(form)
                .setPositiveButton("添加", (dialog, which) -> {
                    String text = word.getText().toString().trim();
                    if (text.isEmpty() || text.contains("\t") || text.contains("\n")) return;
                    appendLine(code.getText().toString().trim(), text);
                    EngineHost.get().reloadCustom();
                    reload();
                })
                .setNegativeButton("取消", null)
                .show();
    }

    private File file() {
        return DataFiles.paths(this).custom;
    }

    private List<String> lines() {
        List<String> out = new ArrayList<>();
        File file = file();
        if (!file.isFile()) return out;
        try (InputStream in = new FileInputStream(file)) {
            ByteArrayOutputStream buffer = new ByteArrayOutputStream();
            byte[] chunk = new byte[16 * 1024];
            int n;
            while ((n = in.read(chunk)) > 0) buffer.write(chunk, 0, n);
            for (String line : new String(buffer.toByteArray(), "UTF-8").split("\n")) {
                if (!line.trim().isEmpty()) out.add(line);
            }
        } catch (Throwable ignored) {
        }
        return out;
    }

    private void appendLine(String code, String word) {
        List<String> all = lines();
        all.add(code.isEmpty() ? word : code + "\t" + word);
        write(all);
    }

    private void removeLine(int index) {
        List<String> all = lines();
        if (index >= 0 && index < all.size()) all.remove(index);
        write(all);
    }

    private void write(List<String> lines) {
        File file = file();
        File tmp = new File(file.getParentFile(), "custom.tsv.tmp");
        try {
            File parent = file.getParentFile();
            if (parent != null && !parent.isDirectory()) parent.mkdirs();
            try (OutputStream out = new FileOutputStream(tmp)) {
                for (String line : lines) {
                    out.write(line.getBytes("UTF-8"));
                    out.write('\n');
                }
            }
            if (file.exists() && !file.delete()) return;
            tmp.renameTo(file);
        } catch (Throwable ignored) {
        }
    }

    private Button button(String label, Runnable action) {
        Button button = new Button(this);
        button.setAllCaps(false);
        button.setText(label);
        button.setTextColor(0xFFFFFFFF);
        button.setBackgroundColor(theme.accent);
        button.setOnClickListener(v -> action.run());
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        params.setMargins(0, dp(8), 0, dp(8));
        button.setLayoutParams(params);
        return button;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
