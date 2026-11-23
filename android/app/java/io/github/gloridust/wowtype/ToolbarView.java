package io.github.gloridust.wowtype;

import android.content.Context;
import android.graphics.drawable.GradientDrawable;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * 键盘上方的工具条：表情、剪贴板、更多（常用语/符号/表情）、设置、收起键盘。
 * 和微信输入法一样，工具都放在键盘上沿，点一下直接用。
 */
final class ToolbarView extends LinearLayout {
    interface Listener {
        void onEmoji();

        void onClipboard();

        void onMenu();

        void onSettings();

        void onHide();
    }

    private final Theme theme;

    ToolbarView(Context context) {
        super(context);
        theme = Theme.get(context);
        setOrientation(HORIZONTAL);
        setGravity(Gravity.CENTER_VERTICAL);
        setBackgroundColor(theme.keySpecial);
        setPadding(dp(6), dp(2), dp(6), dp(2));
    }

    void setListener(Listener listener) {
        removeAllViews();
        button("😊", "表情", listener::onEmoji);
        button("📋", "剪贴板", listener::onClipboard);
        button("⋯", "更多", listener::onMenu);
        button("⚙", "设置", listener::onSettings);

        View spacer = new View(getContext());
        addView(spacer, new LayoutParams(0, 1, 1));

        button("⌄", "收起键盘", listener::onHide);
    }

    private TextView button(String label, String description, Runnable action) {
        TextView text = new TextView(getContext());
        text.setText(label);
        text.setTextSize(TypedValue.COMPLEX_UNIT_SP, 18);
        text.setTextColor(theme.text);
        text.setGravity(Gravity.CENTER);
        text.setContentDescription(description);
        text.setPadding(dp(12), 0, dp(12), 0);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(0x00000000);
        text.setBackground(bg);
        text.setOnClickListener(v -> action.run());
        addView(text, new LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.MATCH_PARENT));
        return text;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
