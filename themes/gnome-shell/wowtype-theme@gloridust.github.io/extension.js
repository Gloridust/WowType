// 这个扩展只带一份样式表（stylesheet.css）：GNOME Shell 启用扩展时会自动加载它，
// 停用时自动卸载，所以这里什么都不用做。
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

export default class WowTypeThemeExtension extends Extension {
    enable() {}

    disable() {}
}
