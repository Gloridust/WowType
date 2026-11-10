#pragma once

#include <string>

namespace wowtype {

/// 把文字放进系统剪贴板：Wayland 用 wl-copy，X11 用 xclip 或 xsel（都没有就返回 false）。
/// 在后台启动，不等它结束（wl-copy、xclip 要一直留着才拿得住剪贴板）；文字经管道传过去，
/// 不出现在命令行里。只在 fcitx 主线程调用。
bool copyToClipboard(const std::string &text);

} // namespace wowtype
