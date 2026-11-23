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
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

/**
 * 候选条：会话给的一页候选，点一个就选，带上一页 / 下一页。
 *
 * 和桌面设置里的「候选排列」对应：横排是一行可滚动（默认），竖排是一列，最多显示 6 行，
 * 多了在条里上下滚。没有候选时显示编辑区（拼音，分好音节）或者会话的提示（aux）。
 */
public final class CandidateBar extends FrameLayout {
    public interface Listener {
        void onPick(int index);

        void onPrevPage();

        void onNextPage();
    }

    private final Theme theme;

    /** 横排高度（和原来一样）。 */
    private static final int HORIZONTAL_HEIGHT_DP = 46;
    /** 竖排一行、最多露几行。 */
    private static final int VERTICAL_ROW_DP = 44;
    private static final int VERTICAL_MAX_ROWS = 6;

    private final HorizontalScrollView horizontalScroll;
    private final LinearLayout horizontalRow;
    private final ScrollView verticalScroll;
    private final LinearLayout verticalColumn;
    private final int pad;

    private Listener listener;
    private boolean horizontal = true;
    private String lastSignature = "";

    public CandidateBar(Context context) {
        super(context);
        theme = Theme.get(context);
        pad = dp(10);

        horizontalRow = new LinearLayout(context);
        horizontalRow.setOrientation(LinearLayout.HORIZONTAL);
        horizontalRow.setGravity(Gravity.CENTER_VERTICAL);
        horizontalScroll = new HorizontalScrollView(context);
        horizontalScroll.setHorizontalScrollBarEnabled(false);
        horizontalScroll.setFillViewport(false);
        horizontalScroll.setVerticalScrollBarEnabled(false);
        horizontalScroll.addView(horizontalRow,
                new FrameLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.MATCH_PARENT));

        verticalColumn = new LinearLayout(context);
        verticalColumn.setOrientation(LinearLayout.VERTICAL);
        verticalScroll = new ScrollView(context);
        verticalScroll.setVerticalScrollBarEnabled(false);
        verticalScroll.setHorizontalScrollBarEnabled(false);
        verticalScroll.addView(verticalColumn,
                new FrameLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT));

        addView(horizontalScroll,
                new LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT));
        addView(verticalScroll,
                new LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT));
        verticalScroll.setVisibility(GONE);
        setBackgroundColor(theme.candidate);
        setMinimumHeight(dp(HORIZONTAL_HEIGHT_DP));
    }

    public void setListener(Listener listener) {
        this.listener = listener;
    }

    /** 横排 / 竖排（设置里的 CandidateLayout）。 */
    public void setHorizontal(boolean horizontal) {
        if (this.horizontal == horizontal) return;
        this.horizontal = horizontal;
        lastSignature = "";
        horizontalScroll.setVisibility(horizontal ? VISIBLE : GONE);
        verticalScroll.setVisibility(horizontal ? GONE : VISIBLE);
        updateHeight(0, false, false);
    }

    /** 照 frame 重画。同一帧不重复建 View（按住退格时每 50 毫秒来一次）。 */
    public void setFrame(Frame frame) {
        StringBuilder signature = new StringBuilder();
        signature.append(horizontal ? 'h' : 'v').append('|')
                .append(frame.candCursor).append('|').append(frame.hasPrev).append('|')
                .append(frame.hasNext).append('|').append(frame.aux == null ? "" : frame.aux)
                .append('|').append(frame.preedit);
        for (int i = 0; i < frame.candCount; i++) {
            signature.append('|').append(frame.candidates[i]);
        }
        if (signature.toString().equals(lastSignature)) return;
        lastSignature = signature.toString();

        LinearLayout row = horizontal ? horizontalRow : verticalColumn;
        row.removeAllViews();

        if (horizontal) {
            if (frame.hasPrev) {
                row.addView(pageButton("‹", listener == null ? null : listener::onPrevPage));
            }
            for (int i = 0; i < frame.candCount; i++) {
                row.addView(candidateView(i, frame, false));
            }
            if (frame.hasNext) {
                row.addView(pageButton("›", listener == null ? null : listener::onNextPage));
            }
        } else {
            if (frame.hasPrev) {
                row.addView(pageButton("‹", listener == null ? null : listener::onPrevPage), rowParams());
            }
            for (int i = 0; i < frame.candCount; i++) {
                row.addView(candidateView(i, frame, true), rowParams());
            }
            if (frame.hasNext) {
                row.addView(pageButton("›", listener == null ? null : listener::onNextPage), rowParams());
            }
        }

        if (frame.candCount == 0) {
            String hint = frame.aux;
            if (hint == null || hint.isEmpty()) hint = frame.preedit;
            if (hint != null && !hint.isEmpty()) {
                TextView text = new TextView(getContext());
                text.setText(hint);
                text.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
                text.setTextColor(theme.muted);
                text.setPadding(pad, 0, pad, 0);
                text.setGravity(Gravity.CENTER_VERTICAL);
                text.setSingleLine(true);
                if (horizontal) {
                    row.addView(text);
                } else {
                    row.addView(text, rowParams());
                }
            }
        }

        if (horizontal) horizontalScroll.scrollTo(0, 0);
        else verticalScroll.scrollTo(0, 0);
        updateHeight(frame.candCount, frame.hasPrev, frame.hasNext);
    }

    public void clear() {
        lastSignature = "";
        horizontalRow.removeAllViews();
        verticalColumn.removeAllViews();
    }

    private LinearLayout.LayoutParams rowParams() {
        return new LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, dp(VERTICAL_ROW_DP));
    }

    private void updateHeight(int candidates, boolean hasPrev, boolean hasNext) {
        int height;
        if (horizontal || candidates == 0) {
            height = dp(HORIZONTAL_HEIGHT_DP);
        } else {
            int rows = candidates + (hasPrev ? 1 : 0) + (hasNext ? 1 : 0);
            height = dp(Math.min(rows, VERTICAL_MAX_ROWS) * VERTICAL_ROW_DP + 8);
        }
        ViewGroup.LayoutParams params = getLayoutParams();
        if (params != null && params.height != height) {
            params.height = height;
            setLayoutParams(params);
        } else if (params == null) {
            setMinimumHeight(height);
        }
    }

    private View candidateView(int index, Frame frame, boolean vertical) {
        TextView text = new TextView(getContext());
        String label = frame.candidates[index];
        String comment = index < frame.comments.length ? frame.comments[index] : "";
        SpannableString span = new SpannableString(comment.isEmpty() ? label : label + " " + comment);
        if (!comment.isEmpty()) {
            int start = label.length() + 1;
            span.setSpan(new RelativeSizeSpan(0.7f), start, span.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            span.setSpan(new ForegroundColorSpan(theme.muted), start, span.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        }
        text.setText(span);
        text.setTextSize(TypedValue.COMPLEX_UNIT_SP, 20);
        text.setTextColor(index == frame.candCursor ? theme.accent : theme.text);
        text.setTypeface(null, index == frame.candCursor ? android.graphics.Typeface.BOLD
                : android.graphics.Typeface.NORMAL);
        text.setGravity(vertical ? (Gravity.CENTER_VERTICAL | Gravity.START) : Gravity.CENTER);
        text.setPadding(pad, 0, pad, 0);
        text.setSingleLine(true);
        if (index == frame.candCursor) {
            GradientDrawable bg = new GradientDrawable();
            bg.setColor(theme.highlight);
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
        text.setTextColor(theme.muted);
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
