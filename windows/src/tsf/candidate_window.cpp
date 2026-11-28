#include "candidate_window.h"

#include <dwmapi.h>
#include <windowsx.h>

#include <algorithm>

#include "globals.h"

using Microsoft::WRL::ComPtr;

namespace wowtype::tsf {

namespace {

constexpr wchar_t kClassName[] = L"WowTypeCandidateWindow";
constexpr float kPad = 8.0f;
constexpr float kGap = 14.0f;
constexpr float kItemPadX = 5.0f;
constexpr float kItemPadY = 2.0f;
constexpr float kArrowWidth = 18.0f;

struct Palette {
    D2D1_COLOR_F background, border, text, muted, highlight, highlightText;
};

Palette palette(bool dark) {
    if (dark) {
        return {D2D1::ColorF(0x2B2B2B), D2D1::ColorF(0x454545), D2D1::ColorF(0xF2F2F2),
                D2D1::ColorF(0x9A9A9A), D2D1::ColorF(0x13B57C), D2D1::ColorF(0xFFFFFF)};
    }
    return {D2D1::ColorF(0xFFFFFF), D2D1::ColorF(0xD0D0D0), D2D1::ColorF(0x1F1F1F),
            D2D1::ColorF(0x8A8A8A), D2D1::ColorF(0x0EAF76), D2D1::ColorF(0xFFFFFF)};
}

/// 系统的「应用模式」是深色时候选框也用深色。
bool systemDark() {
    DWORD value = 1;
    DWORD size = sizeof value;
    if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                     L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &value, &size) != ERROR_SUCCESS) {
        return false;
    }
    return value == 0;
}

bool contains(const D2D1_RECT_F &r, float x, float y) { return x >= r.left && x < r.right && y >= r.top && y < r.bottom; }

} // namespace

CandidateWindow::~CandidateWindow() {
    if (hwnd_) {
        SetWindowLongPtrW(hwnd_, GWLP_USERDATA, 0);
        DestroyWindow(hwnd_);
    }
}

bool CandidateWindow::ensureWindow() {
    if (hwnd_) {
        return true;
    }
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof wc;
    // CS_IME：输入法的界面窗口；CS_DROPSHADOW：系统画的阴影
    wc.style = CS_IME | CS_DROPSHADOW | CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = windowProc;
    wc.hInstance = g_module;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.lpszClassName = kClassName;
    if (!RegisterClassExW(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        log(L"注册候选框窗口类失败 " + std::to_wstring(GetLastError()));
        return false;
    }
    hwnd_ = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_LAYERED, kClassName, L"",
                            WS_POPUP, 0, 0, 1, 1, nullptr, nullptr, g_module, nullptr);
    if (!hwnd_) {
        log(L"建候选框失败 " + std::to_wstring(GetLastError()));
        return false;
    }
    SetWindowLongPtrW(hwnd_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
    SetLayeredWindowAttributes(hwnd_, 0, 255, LWA_ALPHA);
    // Windows 11 上要圆角（Windows 10 不认这个属性，失败也没关系）
    const DWORD round = 3; // DWMWCP_ROUNDSMALL
    DwmSetWindowAttribute(hwnd_, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */, &round, sizeof round);
    return true;
}

bool CandidateWindow::ensureResources() {
    if (!d2d_ && FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, d2d_.GetAddressOf()))) {
        return false;
    }
    if (!dwrite_ && FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                                               reinterpret_cast<IUnknown **>(dwrite_.GetAddressOf())))) {
        return false;
    }
    if (!textFormat_ || formatSize_ != fontSize_) {
        textFormat_.Reset();
        smallFormat_.Reset();
        formatSize_ = fontSize_;
        const float size = static_cast<float>(fontSize_);
        if (FAILED(dwrite_->CreateTextFormat(L"Microsoft YaHei UI", nullptr, DWRITE_FONT_WEIGHT_NORMAL,
                                             DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, size, L"zh-cn",
                                             textFormat_.GetAddressOf())) ||
            FAILED(dwrite_->CreateTextFormat(L"Microsoft YaHei UI", nullptr, DWRITE_FONT_WEIGHT_NORMAL,
                                             DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, size * 0.72f,
                                             L"zh-cn", smallFormat_.GetAddressOf()))) {
            return false;
        }
        textFormat_->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        smallFormat_->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    }
    return true;
}

float CandidateWindow::measure(const std::wstring &text, IDWriteTextFormat *format, float *height) const {
    ComPtr<IDWriteTextLayout> layout;
    if (text.empty() ||
        FAILED(dwrite_->CreateTextLayout(text.c_str(), static_cast<UINT32>(text.size()), format, 10000.0f, 1000.0f,
                                         layout.GetAddressOf()))) {
        if (height) {
            *height = 0;
        }
        return 0;
    }
    DWRITE_TEXT_METRICS metrics{};
    layout->GetMetrics(&metrics);
    if (height) {
        *height = metrics.height;
    }
    return metrics.widthIncludingTrailingWhitespace;
}

void CandidateWindow::layout() {
    items_.clear();
    lines_.clear();
    float probe = 0;
    measure(L"中Ag", textFormat_.Get(), &probe);
    lineHeight_ = std::max(probe, static_cast<float>(fontSize_) * 1.3f);
    const float rowHeight = lineHeight_ + 2 * kItemPadY;
    float y = kPad;
    float width = 0;

    const auto addLine = [&](const std::wstring &text, bool muted) {
        if (text.empty()) {
            return;
        }
        lines_.push_back({text, muted, y});
        width = std::max(width, measure(text, textFormat_.Get()));
        y += lineHeight_;
    };
    if (page_.translate) {
        addLine(widen(page_.translate->title), true);
        addLine(widen(page_.translate->source), false);
    }
    if (page_.aux) {
        addLine(widen(*page_.aux), true);
    }
    if (!lines_.empty() && !page_.texts.empty()) {
        y += 4;
    }

    // 候选：先量好每一个
    const int count = static_cast<int>(page_.texts.size());
    for (int i = 0; i < count; ++i) {
        Item item;
        item.index = i;
        if (page_.labels) {
            // 网格里数字选光标所在行的第几个：序号按列编
            const int number = page_.expanded ? (i % CandidatePage::columns) + 1 : i + 1;
            item.label = std::to_wstring(number % 10) + L".";
        }
        item.text = widen(page_.texts[static_cast<std::size_t>(i)]);
        if (static_cast<std::size_t>(i) < page_.comments.size()) {
            item.comment = widen(page_.comments[static_cast<std::size_t>(i)]);
        }
        item.labelWidth = item.label.empty() ? 0 : measure(item.label, smallFormat_.Get()) + 3;
        item.textWidth = measure(item.text, textFormat_.Get());
        items_.push_back(std::move(item));
    }
    const auto itemWidth = [](const Item &item, float commentWidth) {
        return item.labelWidth + item.textWidth + commentWidth + 2 * kItemPadX;
    };
    std::vector<float> widths;
    for (const auto &item : items_) {
        const float comment = item.comment.empty() ? 0 : measure(item.comment, smallFormat_.Get()) + 4;
        widths.push_back(itemWidth(item, comment));
    }

    hasArrows_ = page_.hasPrev || page_.hasNext;
    if (page_.expanded) {
        // 网格：每列一样宽
        float column = 0;
        for (const float w : widths) {
            column = std::max(column, w);
        }
        for (int i = 0; i < count; ++i) {
            const int row = i / CandidatePage::columns;
            const int col = i % CandidatePage::columns;
            const float x = kPad + col * (column + 4);
            items_[static_cast<std::size_t>(i)].rect = D2D1::RectF(x, y + row * rowHeight, x + column, y + (row + 1) * rowHeight);
        }
        const int rows = (count + CandidatePage::columns - 1) / CandidatePage::columns;
        width = std::max(width, std::min(count, CandidatePage::columns) * (column + 4) - 4);
        y += rows * rowHeight;
    } else if (page_.vertical) {
        float column = 0;
        for (const float w : widths) {
            column = std::max(column, w);
        }
        for (int i = 0; i < count; ++i) {
            items_[static_cast<std::size_t>(i)].rect = D2D1::RectF(kPad, y, kPad + column, y + rowHeight);
            y += rowHeight;
        }
        width = std::max(width, column);
    } else if (count > 0) {
        float x = kPad;
        for (int i = 0; i < count; ++i) {
            items_[static_cast<std::size_t>(i)].rect = D2D1::RectF(x, y, x + widths[static_cast<std::size_t>(i)], y + rowHeight);
            x += widths[static_cast<std::size_t>(i)] + kGap - 2 * kItemPadX;
        }
        float rowWidth = x - kPad - (kGap - 2 * kItemPadX);
        if (hasArrows_) {
            prevArrow_ = D2D1::RectF(kPad + rowWidth + 6, y, kPad + rowWidth + 6 + kArrowWidth, y + rowHeight);
            nextArrow_ = D2D1::RectF(prevArrow_.right, y, prevArrow_.right + kArrowWidth, y + rowHeight);
            rowWidth += 6 + 2 * kArrowWidth;
        }
        width = std::max(width, rowWidth);
        y += rowHeight;
    }
    if (hasArrows_ && (page_.expanded || page_.vertical)) {
        // 竖排、网格：箭头放在最下面靠右
        const float right = kPad + width;
        prevArrow_ = D2D1::RectF(right - 2 * kArrowWidth, y, right - kArrowWidth, y + rowHeight);
        nextArrow_ = D2D1::RectF(right - kArrowWidth, y, right, y + rowHeight);
        y += rowHeight;
    }
    if (page_.translate && !page_.translate->status.empty()) {
        y += 2;
        addLine(widen(page_.translate->status), true);
    }
    width_ = std::max(width + 2 * kPad, 40.0f);
    height_ = y + kPad;
}

void CandidateWindow::show(const CandidatePage &page, const RECT &anchor, int fontSize) {
    if (!ensureWindow()) {
        return;
    }
    page_ = page;
    fontSize_ = std::clamp(fontSize, 10, 40);
    dark_ = systemDark();
    if (!ensureResources()) {
        return;
    }
    layout();
    const UINT dpi = GetDpiForWindow(hwnd_) ? GetDpiForWindow(hwnd_) : 96;
    const float scale = dpi / 96.0f;
    const int w = static_cast<int>(width_ * scale + 0.5f);
    const int h = static_cast<int>(height_ * scale + 0.5f);
    // 放在编辑区下面；屏幕下面放不下就放上面，左右不出屏幕
    MONITORINFO monitor{};
    monitor.cbSize = sizeof monitor;
    GetMonitorInfoW(MonitorFromRect(&anchor, MONITOR_DEFAULTTONEAREST), &monitor);
    const RECT work = monitor.rcWork;
    int x = anchor.left;
    int y = anchor.bottom + 2;
    if (y + h > work.bottom) {
        y = anchor.top - h - 2;
    }
    x = std::max(static_cast<int>(work.left), std::min(x, static_cast<int>(work.right) - w));
    y = std::max(static_cast<int>(work.top), y);
    SetWindowPos(hwnd_, HWND_TOPMOST, x, y, w, h, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    if (target_) {
        target_->Resize(D2D1::SizeU(static_cast<UINT32>(w), static_cast<UINT32>(h)));
        target_->SetDpi(static_cast<float>(dpi), static_cast<float>(dpi));
    }
    InvalidateRect(hwnd_, nullptr, FALSE);
    UpdateWindow(hwnd_);
}

void CandidateWindow::hide() {
    if (hwnd_) {
        ShowWindow(hwnd_, SW_HIDE);
    }
}

void CandidateWindow::setTimer(UINT_PTR id, UINT ms) {
    if (ensureWindow()) {
        SetTimer(hwnd_, id, ms, nullptr);
    }
}

void CandidateWindow::killTimer(UINT_PTR id) {
    if (hwnd_) {
        KillTimer(hwnd_, id);
    }
}

void CandidateWindow::paint() {
    if (!ensureResources()) {
        return;
    }
    RECT client{};
    GetClientRect(hwnd_, &client);
    const UINT dpi = GetDpiForWindow(hwnd_) ? GetDpiForWindow(hwnd_) : 96;
    if (!target_) {
        const auto props = D2D1::RenderTargetProperties(
            D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE),
            static_cast<float>(dpi), static_cast<float>(dpi));
        const auto hwndProps = D2D1::HwndRenderTargetProperties(
            hwnd_, D2D1::SizeU(static_cast<UINT32>(client.right), static_cast<UINT32>(client.bottom)));
        if (FAILED(d2d_->CreateHwndRenderTarget(props, hwndProps, target_.GetAddressOf()))) {
            return;
        }
    }
    const Palette colors = palette(dark_);
    ComPtr<ID2D1SolidColorBrush> brush;
    target_->CreateSolidColorBrush(colors.text, brush.GetAddressOf());
    if (!brush) {
        return;
    }
    target_->BeginDraw();
    target_->Clear(colors.background);
    brush->SetColor(colors.border);
    target_->DrawRectangle(D2D1::RectF(0.5f, 0.5f, width_ - 0.5f, height_ - 0.5f), brush.Get(), 1.0f);

    const auto draw = [&](const std::wstring &text, IDWriteTextFormat *format, float x, float y, float h,
                          const D2D1_COLOR_F &color) {
        if (text.empty()) {
            return;
        }
        ComPtr<IDWriteTextLayout> layout;
        if (FAILED(dwrite_->CreateTextLayout(text.c_str(), static_cast<UINT32>(text.size()), format, 10000.0f, h,
                                             layout.GetAddressOf()))) {
            return;
        }
        layout->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
        brush->SetColor(color);
        // 彩色 emoji（Windows 8.1 起）
        target_->DrawTextLayout(D2D1::Point2F(x, y), layout.Get(), brush.Get(),
                                D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
    };

    for (const auto &line : lines_) {
        draw(line.text, textFormat_.Get(), kPad, line.y, lineHeight_, line.muted ? colors.muted : colors.text);
    }
    for (const auto &item : items_) {
        const bool current = item.index == page_.cursor;
        if (current) {
            brush->SetColor(colors.highlight);
            target_->FillRoundedRectangle(D2D1::RoundedRect(item.rect, 4.0f, 4.0f), brush.Get());
        }
        const float h = item.rect.bottom - item.rect.top;
        float x = item.rect.left + kItemPadX;
        draw(item.label, smallFormat_.Get(), x, item.rect.top, h, current ? colors.highlightText : colors.muted);
        x += item.labelWidth;
        draw(item.text, textFormat_.Get(), x, item.rect.top, h, current ? colors.highlightText : colors.text);
        x += item.textWidth;
        if (!item.comment.empty()) {
            draw(item.comment, smallFormat_.Get(), x + 4, item.rect.top, h,
                 current ? colors.highlightText : colors.muted);
        }
    }
    if (hasArrows_) {
        const float h = prevArrow_.bottom - prevArrow_.top;
        draw(L"‹", textFormat_.Get(), prevArrow_.left + 4, prevArrow_.top, h,
             page_.hasPrev ? colors.text : colors.border);
        draw(L"›", textFormat_.Get(), nextArrow_.left + 4, nextArrow_.top, h,
             page_.hasNext ? colors.text : colors.border);
    }
    if (target_->EndDraw() == D2DERR_RECREATE_TARGET) {
        target_.Reset();
    }
}

const CandidateWindow::Item *CandidateWindow::itemAt(LPARAM lParam) const {
    const UINT dpi = GetDpiForWindow(hwnd_) ? GetDpiForWindow(hwnd_) : 96;
    const float x = GET_X_LPARAM(lParam) * 96.0f / dpi;
    const float y = GET_Y_LPARAM(lParam) * 96.0f / dpi;
    for (const auto &item : items_) {
        if (contains(item.rect, x, y)) {
            return &item;
        }
    }
    return nullptr;
}

void CandidateWindow::showForgetMenu(LPARAM lParam) {
    const Item *item = itemAt(lParam);
    if (!item || !canForget || !onForget) {
        return;
    }
    const int index = item->index;
    if (!canForget(index)) {
        return;
    }
    HMENU menu = CreatePopupMenu();
    if (!menu) {
        return;
    }
    // 字样和 Linux、macOS 一样；Tab 后面是右对齐的快捷键提示
    const std::wstring title = widen(Composer::forgetMenuTitle) + L"\tCtrl+Delete";
    constexpr UINT kForget = 1;
    AppendMenuW(menu, MF_STRING, kForget, title.c_str());
    POINT pt{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};
    ClientToScreen(hwnd_, &pt);
    // 候选框在应用的线程里，应用本来就在前台：不 SetForegroundWindow，免得抢走输入框的焦点、结束组字
    const UINT chosen = static_cast<UINT>(TrackPopupMenuEx(
        menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON | TPM_LEFTALIGN | TPM_TOPALIGN, pt.x, pt.y, hwnd_,
        nullptr));
    DestroyMenu(menu);
    if (chosen == kForget && onForget) {
        onForget(index);
    }
}

LRESULT CALLBACK CandidateWindow::windowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    auto *self = reinterpret_cast<CandidateWindow *>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (self) {
        return self->handle(message, wParam, lParam);
    }
    return DefWindowProcW(hwnd, message, wParam, lParam);
}

LRESULT CandidateWindow::handle(UINT message, WPARAM wParam, LPARAM lParam) {
    switch (message) {
    case WM_MOUSEACTIVATE:
        // 点候选框不抢应用的焦点
        return MA_NOACTIVATE;
    case WM_PAINT: {
        PAINTSTRUCT ps;
        BeginPaint(hwnd_, &ps);
        paint();
        EndPaint(hwnd_, &ps);
        return 0;
    }
    case WM_ERASEBKGND:
        return 1;
    case WM_LBUTTONUP: {
        const UINT dpi = GetDpiForWindow(hwnd_) ? GetDpiForWindow(hwnd_) : 96;
        const float x = GET_X_LPARAM(lParam) * 96.0f / dpi;
        const float y = GET_Y_LPARAM(lParam) * 96.0f / dpi;
        if (hasArrows_ && contains(prevArrow_, x, y)) {
            if (page_.hasPrev && onPage) {
                onPage(false);
            }
            return 0;
        }
        if (hasArrows_ && contains(nextArrow_, x, y)) {
            if (page_.hasNext && onPage) {
                onPage(true);
            }
            return 0;
        }
        for (const auto &item : items_) {
            if (contains(item.rect, x, y)) {
                if (onSelect) {
                    onSelect(item.index);
                }
                break;
            }
        }
        return 0;
    }
    case WM_RBUTTONUP:
        showForgetMenu(lParam);
        return 0;
    case WM_MOUSEWHEEL:
        if (onPage) {
            onPage(GET_WHEEL_DELTA_WPARAM(wParam) < 0);
        }
        return 0;
    case WM_TIMER:
        if (onTimer) {
            onTimer(wParam);
        }
        return 0;
    case WM_DPICHANGED:
        target_.Reset();
        return 0;
    default:
        break;
    }
    return DefWindowProcW(hwnd_, message, wParam, lParam);
}

} // namespace wowtype::tsf
