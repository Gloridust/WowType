// 插件发来的光标矩形换成舞台坐标：语音浮条和展开面板的网格共用，算法和 Input Method Panel 扩展一样。
//
// x/y/w/h 和 kimpanel 的 SetSpotRect / SetRelativeSpotRectV2 同一个意思：relative 时是相对焦点窗口、
// 按应用的缩放 scale 给的，要先换成 GNOME 的缩放，再加上窗口的位置。
// protocol_to_stage_rect 是 GNOME 47 才有的（Xwayland 缩放）；45、46 上没有它，坐标本来就是舞台坐标，
// 原样用（#170：GNOME 46 上报 "protocol_to_stage_rect is not a function"，浮条一直画不出来）
import Mtk from 'gi://Mtk';
import St from 'gi://St';

export function stageRect(x, y, w, h, relative, scale) {
    const focus = global.display.focus_window;
    const toStage = r => focus && typeof focus.protocol_to_stage_rect === 'function'
        ? focus.protocol_to_stage_rect(r) : r;
    let rect;
    if (relative && focus) {
        const k = St.ThemeContext.get_for_stage(global.stage).scale_factor / (scale || 1);
        rect = toStage(new Mtk.Rectangle({x: x * k, y: y * k, width: w * k, height: h * k}));
        const actor = focus.get_compositor_private();
        if (actor) {
            rect.x += actor.x;
            rect.y += actor.y;
        }
    } else {
        rect = toStage(new Mtk.Rectangle({x, y, width: w, height: h}));
    }
    return {x: rect.x, y: rect.y, w: rect.width, h: rect.height};
}
