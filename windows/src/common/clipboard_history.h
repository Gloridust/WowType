#pragma once

// 剪贴板历史（docs/CONFIG.md「剪贴板历史」）：设置窗口「剪贴板」页的列表用。记录在核心里（wowtype_clipboard_*，
// 数据目录的 clipboard-history.json，后台进程记、输入法和设置窗口读），这里只解析核心给的 JSON、拼列表里显示的字，
// 写法和 Linux 设置界面、macOS 设置窗口的一样。不依赖 windows.h（windows/test.sh 在 Linux 上测）。

#include <cstdint>
#include <cstdio>
#include <ctime>
#include <string>
#include <vector>

#include "json.h"

namespace wowtype::clipboard {

struct Entry {
    std::string text;
    /// 记下（最近一次复制）的时间，Unix 秒
    int64_t time = 0;
    /// 复制时在前台的程序（exe 名），不知道是空串
    std::string app;
    /// 别的设备复制过来的：那台设备的名字
    std::string device;

    /// 从哪来的：别的设备的是「来自 那台」，本机的是程序名
    std::string source() const { return device.empty() ? app : "来自 " + device; }
};

/// wowtype_clipboard_entries_json 给的 {"items":[{"text","time","app","device"}…]}，最新的在前。读不了是空的。
inline std::vector<Entry> parseEntries(const std::string &text) {
    std::vector<Entry> out;
    Json json;
    if (!parseJson(text, json)) {
        return out;
    }
    const Json *items = json.field("items");
    if (!items) {
        return out;
    }
    for (const Json &item : items->items) {
        const Json *t = item.field("text");
        if (!t || t->kind != Json::Kind::String) {
            continue;
        }
        Entry e;
        e.text = t->text;
        if (const Json *time = item.field("time")) {
            e.time = static_cast<int64_t>(time->number);
        }
        if (const Json *app = item.field("app")) {
            e.app = app->str();
        }
        if (const Json *device = item.field("device")) {
            e.device = device->str();
        }
        out.push_back(std::move(e));
    }
    return out;
}

/// UTF-8 的一个字从 s[i] 开始占几个字节。
inline std::size_t utf8Length(const std::string &s, std::size_t i) {
    const auto c = static_cast<unsigned char>(s[i]);
    const std::size_t n = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;
    return i + n <= s.size() ? n : s.size() - i;
}

/// 列表里的一行：换行显示成 ⏎，连着的空格、制表符并成一个，太长的（按字数）截断。
inline std::string preview(const std::string &text, std::size_t limit = 120) {
    std::size_t begin = 0;
    std::size_t end = text.size();
    auto blank = [](char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; };
    while (begin < end && blank(text[begin])) {
        ++begin;
    }
    while (end > begin && blank(text[end - 1])) {
        --end;
    }
    std::string flat;
    for (std::size_t i = begin; i < end; ++i) {
        const char c = text[i];
        if (c == '\r' && i + 1 < end && text[i + 1] == '\n') {
            continue;
        }
        if (c == '\n' || c == '\r') {
            flat += " \xE2\x8F\x8E "; // ⏎
        } else {
            flat += c;
        }
    }
    std::string shown;
    bool lastBlank = false;
    for (char c : flat) {
        const bool isBlank = c == ' ' || c == '\t';
        if (isBlank && lastBlank) {
            continue;
        }
        shown += isBlank ? ' ' : c;
        lastBlank = isBlank;
    }
    std::string out;
    std::size_t chars = 0;
    for (std::size_t i = 0; i < shown.size();) {
        const std::size_t n = utf8Length(shown, i);
        if (chars + 1 == limit && i + n < shown.size()) {
            return out + "\xE2\x80\xA6"; // …
        }
        out.append(shown, i, n);
        i += n;
        ++chars;
    }
    return out;
}

/// 本地时间（utc 是 true 时按 UTC，测试用）。
inline std::tm brokenDown(int64_t t, bool utc) {
    const std::time_t time = static_cast<std::time_t>(t);
    std::tm out{};
#ifdef _WIN32
    utc ? gmtime_s(&out, &time) : localtime_s(&out, &time);
#else
    utc ? gmtime_r(&time, &out) : localtime_r(&time, &out);
#endif
    return out;
}

/// 「刚才」「5 分钟前」「3 小时前」「07:00」「昨天 14:02」「11月20日 14:02」「2025年11月20日」。
inline std::string when(int64_t time, int64_t now, bool utc = false) {
    const int64_t ago = now - time;
    if (ago < 60) {
        return "刚才";
    }
    if (ago < 3600) {
        return std::to_string(ago / 60) + " 分钟前";
    }
    const std::tm then = brokenDown(time, utc);
    const std::tm today = brokenDown(now, utc);
    const std::tm yesterday = brokenDown(now - 86400, utc);
    auto sameDay = [](const std::tm &a, const std::tm &b) {
        return a.tm_year == b.tm_year && a.tm_yday == b.tm_yday;
    };
    char clock[16];
    std::snprintf(clock, sizeof clock, "%02d:%02d", then.tm_hour, then.tm_min);
    if (ago < 12 * 3600 || sameDay(then, today)) {
        return !sameDay(then, today) || ago < 6 * 3600 ? std::to_string(ago / 3600) + " 小时前" : std::string(clock);
    }
    if (sameDay(then, yesterday)) {
        return std::string("昨天 ") + clock;
    }
    if (then.tm_year == today.tm_year) {
        return std::to_string(then.tm_mon + 1) + "月" + std::to_string(then.tm_mday) + "日 " + clock;
    }
    return std::to_string(then.tm_year + 1900) + "年" + std::to_string(then.tm_mon + 1) + "月" +
           std::to_string(then.tm_mday) + "日";
}

} // namespace wowtype::clipboard
