package io.github.gloridust.wowtype;

import android.content.Context;
import android.graphics.drawable.GradientDrawable;
import android.text.SpannableString;
import android.text.Spanned;
import android.text.style.ForegroundColorSpan;
import android.text.style.RelativeSizeSpan;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * 候选条：会话给的一页候选，横排、可滚动，点了就选。还有上一页 / 下一页。
 *
 * 没有候选时显示编辑区（拼音，分好音节）或者会话的提示（aux）：词库还在后台载入、
 * 五笔没码表的时候，提示就画在这里。
 */
public final class CandidateBar extends HorizontalScrollView {
    public interface Listener {
        void onPick(int index);

        void onPrevPage();

        void onNextPage();
    }

    private static final int BG = 0xFFFFFFFF;
    private static final int TEXT = 0xFF1F2328;
    private static final int MUTED = 0xFF6B7280;
    private static final int HIGHLIGHT_BG = 0xFFDDF4EA;
    private static final int ACCENT = 0xFF0B8A5C;

    private final LinearLayout row;
    private final int pad;
    private Listener listener;
    private String lastSignature = "";

    public CandidateBar(Context context) {
        super(context);
        pad = dp(10);
        row = new LinearLayout(context);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        addView(row, new LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.MATCH_PARENT));
        setBackgroundColor(BG);
        setHorizontalScrollBarEnabled(false);
        setFillViewport(false);
        setVerticalScrollBarEnabled(false);
    }

    public void setListener(Listener listener) {
        this.listener = listener;
    }

    /** 照 frame 重画。同一帧不重复建 View（按住退格时每 50 毫秒来一次）。 */
    public void setFrame(Frame frame) {
        StringBuilder signature = new StringBuilder();
        signature.append(frame.candCursor).append('|').append(frame.hasPrev).append('|')
                .append(frame.hasNext).append('|').append(frame.aux == null ? "" : frame.aux)
                .append('|').append(frame.preedit);
        for (int i = 0; i < frame.candCount; i++) {
            signature.append('|').append(frame.candidates[i]);
        }
        if (signature.toString().equals(lastSignature)) return;
        lastSignature = signature.toString();

        row.removeAllViews();
        if (frame.hasPrev) row.addView(pageButton("‹", listener == null ? null : listener::onPrevPage));
        for (int i = 0; i < frame.candCount; i++) {
            row.addView(candidateView(i, frame));
        }
        if (frame.hasNext) row.addView(pageButton("›", listener == null ? null : listener::onNextPage));

        if (frame.candCount == 0) {
            String hint = frame.aux;
            if (hint == null || hint.isEmpty()) hint = frame.preedit;
            if (hint != null && !hint.isEmpty()) {
                TextView text = new TextView(getContext());
                text.setText(hint);
                text.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
                text.setTextColor(MUTED);
                text.setPadding(pad, 0, pad, 0);
                text.setGravity(Gravity.CENTER_VERTICAL);
                text.setSingleLine(true);
                row.addView(text);
            }
        }
        scrollTo(0, 0);
    }

    public void clear() {
        lastSignature = "";
        row.removeAllViews();
    }

    private View candidateView(int index, Frame frame) {
        TextView text = new TextView(getContext());
        String label = frame.candidates[index];
        String comment = index < frame.comments.length ? frame.comments[index] : "";
        SpannableString span = new SpannableString(comment.isEmpty() ? label : label + " " + comment);
        if (!comment.isEmpty()) {
            int start = label.length() + 1;
            span.setSpan(new RelativeSizeSpan(0.7f), start, span.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            span.setSpan(new ForegroundColorSpan(MUTED), start, span.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        }
        text.setText(span);
        text.setTextSize(TypedValue.COMPLEX_UNIT_SP, 20);
        text.setTextColor(index == frame.candCursor ? ACCENT : TEXT);
        text.setTypeface(null, index == frame.candCursor ? android.graphics.Typeface.BOLD
                : android.graphics.Typeface.NORMAL);
        text.setGravity(Gravity.CENTER);
        text.setPadding(pad, 0, pad, 0);
        text.setSingleLine(true);
        if (index == frame.candCursor) {
            GradientDrawable bg = new GradientDrawable();
            bg.setColor(HIGHLIGHT_BG);
            bg.setCornerRadius(dp(4));
            text.setBackground(bg);
        }
        final int picked = index;
        text.setOnClickListener(v -> {
            if (listener != null) listener.onPick(picked);
        });
        return text;
    }

    private View pageButton(String label, Runnable action) {
        TextView text = new TextView(getContext());
        text.setText(label);
        text.setTextSize(TypedValue.COMPLEX_UNIT_SP, 22);
        text.setTextColor(MUTED);
        text.setGravity(Gravity.CENTER);
        text.setPadding(pad, 0, pad, 0);
        text.setOnClickListener(v -> {
            if (action != null) action.run();
        });
        return text;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
