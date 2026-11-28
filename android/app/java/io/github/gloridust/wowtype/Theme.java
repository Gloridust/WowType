package io.github.gloridust.wowtype;

import android.content.Context;
import android.content.res.Configuration;

/**
 * 输入法和设置页的颜色。跟着系统深色模式走；设置里「外观」可以强制浅色 / 深色，
 * 和桌面设置窗口的 SettingsTheme（System / Light / Dark）对应。
 */
final class Theme {
    final int background;
    final int text;
    final int muted;
    final int key;
    final int keySpecial;
    final int keyPressed;
    final int candidate;
    final int highlight;
    final int accent;

    private Theme(boolean dark, String accentName) {
        int lightAccent = 0xFF0EAF76;
        int darkAccent = 0xFF3DDC97;
        switch (accentName) {
            case "Blue":
                lightAccent = 0xFF1A73E8;
                darkAccent = 0xFF6EA8FE;
                break;
            case "Purple":
                lightAccent = 0xFF7C4DFF;
                darkAccent = 0xFFB39DFF;
                break;
            case "Orange":
                lightAccent = 0xFFE8710A;
                darkAccent = 0xFFFFB077;
                break;
            case "Pink":
                lightAccent = 0xFFD81B60;
                darkAccent = 0xFFF48FB1;
                break;
            default:
                break;
        }
        if (dark) {
            background = 0xFF1B1D1F;
            text = 0xFFE6E8EA;
            muted = 0xFF9AA1A9;
            key = 0xFF2B2F33;
            keySpecial = 0xFF3A4046;
            keyPressed = 0xFF485058;
            candidate = 0xFF1B1D1F;
            highlight = 0xFF234238;
            accent = darkAccent;
        } else {
            background = 0xFFE7EAEE;
            text = 0xFF1F2328;
            muted = 0xFF6B7280;
            key = 0xFFFFFFFF;
            keySpecial = 0xFFD2D7DD;
            keyPressed = 0xFFC2C8CF;
            candidate = 0xFFFFFFFF;
            highlight = 0xFFDDF4EA;
            accent = lightAccent;
        }
    }

    static Theme get(Context context) {
        String mode = Prefs.get(context).string("SettingsTheme", "System");
        boolean dark;
        if ("Dark".equals(mode)) {
            dark = true;
        } else if ("Light".equals(mode)) {
            dark = false;
        } else {
            int ui = context.getResources().getConfiguration().uiMode
                    & Configuration.UI_MODE_NIGHT_MASK;
            dark = ui == Configuration.UI_MODE_NIGHT_YES;
        }
        return new Theme(dark, Prefs.get(context).string("SettingsAccent", "Green"));
    }
}
