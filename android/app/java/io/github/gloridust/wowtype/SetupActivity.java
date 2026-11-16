package io.github.gloridust.wowtype;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Typeface;
import android.os.Bundle;
import android.provider.Settings;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.ViewGroup;
import android.view.inputmethod.InputMethodManager;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

/**
 * 设置 / 启用页。输入法本身没有配置项：这里只做三件事——告诉用户怎么启用、
 * 帮忙打开系统选择器、提前把词库解出来并载入（第一次要几秒，别等到打字时才发现）。
 */
public final class SetupActivity extends Activity {
    private static final int ACCENT = 0xFF0EAF76;
    private static final int TEXT = 0xFF1F2328;
    private static final int MUTED = 0xFF6B7280;

    private final EngineHost.Listener engineListener = this::updateStatus;
    private TextView state;
    private TextView engineState;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        int pad = dp(20);
        LinearLayout column = new LinearLayout(this);
        column.setOrientation(LinearLayout.VERTICAL);
        column.setPadding(pad, pad, pad, pad);
        column.setBackgroundColor(0xFFFFFFFF);

        TextView title = new TextView(this);
        title.setText(R.string.app_name);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 30);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        title.setTextColor(TEXT);
        column.addView(title);

        TextView intro = new TextView(this);
        intro.setText(R.string.setup_intro);
        intro.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        intro.setTextColor(TEXT);
        intro.setLineSpacing(dp(4), 1f);
        column.addView(intro, margins(0, dp(10), 0, 0));

        state = new TextView(this);
        state.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        state.setTextColor(ACCENT);
        column.addView(state, margins(0, dp(18), 0, 0));

        engineState = new TextView(this);
        engineState.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        engineState.setTextColor(MUTED);
        column.addView(engineState, margins(0, dp(6), 0, 0));

        column.addView(button(R.string.setup_enable, v ->
                startActivity(new Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))), margins(0, dp(20), 0, 0));
        column.addView(button(R.string.setup_choose, v -> {
            InputMethodManager imm = getSystemService(InputMethodManager.class);
            if (imm != null) imm.showInputMethodPicker();
        }), margins(0, dp(10), 0, 0));
        column.addView(button(R.string.setup_load, v -> {
            engineState.setText(R.string.setup_loading);
            EngineHost.get().start(this, engineListener);
        }), margins(0, dp(10), 0, 0));

        TextView usage = new TextView(this);
        usage.setText(R.string.setup_usage);
        usage.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        usage.setTextColor(MUTED);
        usage.setLineSpacing(dp(4), 1f);
        column.addView(usage, margins(0, dp(24), 0, 0));

        ScrollView scroll = new ScrollView(this);
        scroll.addView(column);
        setContentView(scroll);

        EngineHost.get().start(this, engineListener);
    }

    @Override
    protected void onResume() {
        super.onResume();
        updateStatus();
    }

    @Override
    protected void onDestroy() {
        EngineHost.get().removeListener(engineListener);
        super.onDestroy();
    }

    private void updateStatus() {
        boolean enabled = isEnabled();
        state.setText(enabled ? R.string.setup_enabled : R.string.setup_disabled);
        state.setTextColor(enabled ? ACCENT : MUTED);
        engineState.setText(EngineHost.get().status() + "（ABI " + Native.version() + "）");
    }

    /** 系统输入法列表里有没有我们：Settings.Secure 里记的是 {@code 包名/.类名}。 */
    private boolean isEnabled() {
        String enabled = Settings.Secure.getString(getContentResolver(),
                Settings.Secure.ENABLED_INPUT_METHODS);
        return enabled != null && enabled.contains(getPackageName() + "/.");
    }

    private Button button(int text, android.view.View.OnClickListener onClick) {
        Button button = new Button(this);
        button.setText(text);
        button.setAllCaps(false);
        button.setTextColor(0xFFFFFFFF);
        button.setBackgroundColor(ACCENT);
        button.setOnClickListener(onClick);
        return button;
    }

    private LinearLayout.LayoutParams margins(int left, int top, int right, int bottom) {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        params.setMargins(left, top, right, bottom);
        return params;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
