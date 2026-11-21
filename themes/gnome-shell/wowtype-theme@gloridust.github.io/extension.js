// WowType 的 GNOME Shell 扩展：
//   - stylesheet.css 把 Input Method Panel（kimpanel）画的候选框换成 WowType 的绿色主题，
//     GNOME Shell 启用扩展时自动加载，停用时自动卸载；
//   - voice.js 画语音输入浮条（按住语音键说话时出现在光标下面）；
//   - grid.js 画按下键展开的 6×6 候选面板（只有光标处那一格高亮，点格子选词，#270）。
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {CandidateGrid} from './grid.js';
import {VoiceOverlay} from './voice.js';

export default class WowTypeThemeExtension extends Extension {
    enable() {
        this._voice = new VoiceOverlay();
        // 网格出错不能连累语音浮条：它不登记名字，插件照旧把展开面板交给 kimpanel
        try {
            this._grid = new CandidateGrid();
        } catch (e) {
            console.error('WowType 展开面板的网格起不来：', e);
            this._grid = null;
        }
    }

    disable() {
        this._grid?.destroy();
        this._grid = null;
        this._voice?.destroy();
        this._voice = null;
    }
}
