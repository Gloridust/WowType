// WowType 的 GNOME Shell 扩展：
//   - stylesheet.css 把 Input Method Panel（kimpanel）画的候选框换成 WowType 的绿色主题，
//     GNOME Shell 启用扩展时自动加载，停用时自动卸载；
//   - voice.js 画语音输入浮条（按住语音键说话时出现在光标下面）。
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {VoiceOverlay} from './voice.js';

export default class WowTypeThemeExtension extends Extension {
    enable() {
        this._voice = new VoiceOverlay();
    }

    disable() {
        this._voice?.destroy();
        this._voice = null;
    }
}
