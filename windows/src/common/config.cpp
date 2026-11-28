#include "config.h"

#include <algorithm>
#include <cstdlib>
#include <optional>

#include "wowtype_core.h"

namespace wowtype {

namespace {

using T = SettingType;

std::string_view trim(std::string_view s) {
    while (!s.empty() && (s.front() == ' ' || s.front() == '\t')) {
        s.remove_prefix(1);
    }
    while (!s.empty() && (s.back() == ' ' || s.back() == '\t')) {
        s.remove_suffix(1);
    }
    return s;
}

/// fcitx5 写文件时，带空格、引号的值会加双引号并转义。
std::string unquote(std::string_view value) {
    if (value.size() < 2 || value.front() != '"' || value.back() != '"') {
        return std::string(value);
    }
    std::string out;
    bool escaped = false;
    for (const char c : value.substr(1, value.size() - 2)) {
        if (escaped) {
            out += c == 'n' ? '\n' : c;
            escaped = false;
        } else if (c == '\\') {
            escaped = true;
        } else {
            out += c;
        }
    }
    return out;
}

/// Swift 的 Int(String)：可选的正负号 + 至少一位数字，别的都不认。
std::optional<long long> parseInt(std::string_view s) {
    if (s.empty()) {
        return std::nullopt;
    }
    bool negative = false;
    std::size_t i = 0;
    if (s[0] == '+' || s[0] == '-') {
        negative = s[0] == '-';
        i = 1;
    }
    if (i == s.size() || s.size() - i > 18) {
        return std::nullopt;
    }
    long long n = 0;
    for (; i < s.size(); ++i) {
        if (s[i] < '0' || s[i] > '9') {
            return std::nullopt;
        }
        n = n * 10 + (s[i] - '0');
    }
    return negative ? -n : n;
}

/// 写文件时：值里有空白、换行，或者本身就被引号包着，照 fcitx5 的写法加双引号并转义（unquote 读回来一样）。
std::string quote(const std::string &value) {
    const bool wrapped = value.size() >= 2 && value.front() == '"' && value.back() == '"';
    const bool special = value.find_first_of(" \t\n\r\v\f") != std::string::npos;
    if (!wrapped && !special) {
        return value;
    }
    std::string out = "\"";
    for (const char c : value) {
        switch (c) {
        case '\\': out += "\\\\"; break;
        case '"': out += "\\\""; break;
        case '\n': out += "\\n"; break;
        default: out += c;
        }
    }
    return out + "\"";
}

bool blank(std::string_view s) {
    return std::all_of(s.begin(), s.end(), [](char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; });
}

const SettingDef *find(const std::string &key) {
    for (const auto &def : settingDefs()) {
        if (key == def.key) {
            return &def;
        }
    }
    return nullptr;
}

} // namespace

const std::vector<SettingDef> &settingDefs() {
    static const std::vector<SettingDef> defs = {
        {"CandidateLayout", T::Enum, "Horizontal", 0, 0, {"Horizontal", "Vertical"}},
        {"ArrowKeys", T::Enum, "Candidates", 0, 0, {"Candidates", "Caret"}},
        {"PageSize", T::Int, "9", 3, 9},
        {"CandidateFontSize", T::Int, "17", 10, 40},
        {"PageKeysMinusEqual", T::Bool, "True"},
        {"PageKeysBracket", T::Bool, "False"},
        {"PageKeysCommaPeriod", T::Bool, "False"},
        {"PageKeysTab", T::Bool, "False"},
        {"Fuzzy", T::Bool, "False"},
        {"FuzzyZh", T::Bool, "True"},
        {"FuzzyCh", T::Bool, "True"},
        {"FuzzySh", T::Bool, "True"},
        {"FuzzyNL", T::Bool, "False"},
        {"FuzzyFH", T::Bool, "False"},
        {"FuzzyRL", T::Bool, "False"},
        {"FuzzyAn", T::Bool, "True"},
        {"FuzzyEn", T::Bool, "True"},
        {"FuzzyIn", T::Bool, "True"},
        {"FuzzyIan", T::Bool, "True"},
        {"FuzzyUan", T::Bool, "True"},
        {"FuzzyUn", T::Bool, "False"},
        {"FuzzyAnAi", T::Bool, "False"},
        {"FuzzyHuangWang", T::Bool, "False"},
        {"FuzzyUnIong", T::Bool, "False"},
        {"FuzzyEngOng", T::Bool, "False"},
        {"TypoCorrection", T::Bool, "True"},
        {"RareExtChars", T::Bool, "False"},
        {"InlineSpaceSeparator", T::Bool, "False"},
        {"InputScheme", T::Enum, "Quanpin", 0, 0, {"Quanpin", "Shuangpin", "Wubi86"}},
        {"ShuangpinScheme", T::Enum, "Ziranma", 0, 0,
         {"Ziranma", "Xiaohe", "Microsoft", "Sogou", "ABC", "Ziguang", "PinyinJiajia"}},
        {"ShuangpinShowKeys", T::Bool, "False"},
        {"ShuangpinAbbrev", T::Bool, "True"},
        {"WubiAutoCommit", T::Bool, "True"},
        {"WubiHint", T::Bool, "True"},
        {"ShiftToggle", T::Enum, "Both", 0, 0, {"Both", "Left", "Right", "Off"}},
        {"InitialMode", T::Enum, "Chinese", 0, 0, {"Chinese", "English", "Last"}},
        {"WindowMode", T::Enum, "Same", 0, 0, {"Same", "Chinese", "English"}},
        {"Traditional", T::Bool, "False"},
        {"PunctuationStyle", T::Enum, "Fullwidth", 0, 0, {"Fullwidth", "Halfwidth"}},
        {"SelectKeys", T::Enum, "Off", 0, 0, {"Off", "Semicolon", "SemicolonQuote"}},
        {"PickChar", T::Bool, "True"},
        {"Association", T::Bool, "False"},
        {"DateTime", T::Bool, "True"},
        {"Calculator", T::Bool, "True"},
        {"Toolbar", T::Bool, "True"},
        {"ClipboardHistory", T::Bool, "False"},
        // 跨设备复制粘贴（docs/SYNC.md）。Windows 上由设置程序起的后台进程收发（--sync-agent），
        // 收到的总是放进系统剪贴板，所以没有 ClipboardSyncPaste
        {"ClipboardSync", T::Bool, "False"},
        {"ClipboardSyncLan", T::Bool, "True"},
        {"ClipboardSyncRelayUrl", T::String, ""},
        {"ClipboardSyncDeviceName", T::String, ""},
        {"AutoSpace", T::Bool, "False"},
        {"AutoSpaceLetters", T::Bool, "True"},
        {"AutoSpaceDigits", T::Bool, "True"},
        {"AutoPairPunct", T::Bool, "False"},
        {"Voice", T::Bool, "True"},
        // 语音键用 fcitx5 的键名（Alt_R、F8），原样存（和 macOS 一样），用的时候 VoiceKey::parse 认，认不出就不用热键
        {"VoiceKey", T::Key, "Alt_R"},
        // 点按说话时没声音多久自动结束，毫秒；0 不自动结束（再点一下语音键结束，核心里最长录 2 分钟）
        {"VoiceSilenceTimeout", T::Int, "1500", 0, 60000},
        {"VoiceCopy", T::Bool, "False"},
        {"EmojiSuggest", T::Bool, "True"},
        // Win+. 是系统的表情面板，到不了输入法：和 macOS 一样默认 Control+.（Super 当 Control）
        {"EmojiKey", T::Key, "Control+period"},
        {"ToggleKey", T::Key, ""},
        {"TranslateModeKey", T::Key, ""},
        {"CheckUpdate", T::Bool, "True"},
        {"BetaUpdates", T::Bool, "False"},
        {"TypingStats", T::Bool, "False"},
        // 开发者模式（默认关）：把每次上屏打的输入、当时的候选、选了第几个明文记进数据目录的 devlog.jsonl
        {"DeveloperMode", T::Bool, "False"},
        // 设置窗口自己的主题、强调色（输入法不读），可选值和名字见 look.h
        {"SettingsTheme", T::Enum, "System", 0, 0, {"System", "Light", "Dark"}},
        {"SettingsAccent", T::Enum, "Green", 0, 0, {"Green", "Blue", "Purple", "Orange", "Pink"}},
        {"Translate", T::Bool, "False"},
        {"TranslateTarget", T::Enum, "en", 0, 0,
         {"en", "ja", "ko", "fr", "de", "es", "ru", "pt", "it", "vi", "th", "id", "ar"}},
        {"TranslateBaseUrl", T::String, ""},
        {"TranslateModel", T::String, ""},
        {"TranslateFormal", T::Bool, "False"},
        {"TranslateOneShot", T::Bool, "False"},
        {"TranslateLocal", T::Bool, "True"},
        {"TranslateLocalModel", T::String, ""},
        {"TranslateLlamaServer", T::String, ""},
        {"TranslateIdleMinutes", T::Int, "5", 0, 240},
        {"Lexicon", T::String, ""},
    };
    return defs;
}

const std::vector<IntChoice> &voiceSilenceChoices() {
    static const std::vector<IntChoice> choices = {
        {1500, "1.5 秒"}, {3000, "3 秒"}, {5000, "5 秒"}, {10000, "10 秒"}, {30000, "30 秒"}, {0, "不自动结束"},
    };
    return choices;
}

bool impliedTranslateLocal(std::string_view baseUrl) {
    return std::all_of(baseUrl.begin(), baseUrl.end(),
                       [](char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; });
}

Config::Config() {
    for (const auto &def : settingDefs()) {
        values_[def.key] = def.defaultValue;
    }
}

Config Config::parse(std::string_view text) {
    Config config;
    bool inGroup = false;
    bool sawTranslateLocal = false;
    bool sawInputScheme = false;
    bool oldShuangpin = false;
    std::size_t start = 0;
    while (start <= text.size()) {
        std::size_t end = text.find_first_of("\r\n", start);
        if (end == std::string_view::npos) {
            end = text.size();
        }
        const std::string_view line = trim(text.substr(start, end - start));
        start = end + 1;
        if (line.empty() || line.front() == '#' || line.front() == ';') {
            continue;
        }
        if (line.front() == '[') {
            inGroup = true;
            continue;
        }
        const std::size_t eq = line.find('=');
        if (inGroup || eq == std::string_view::npos) {
            continue;
        }
        const std::string key(trim(line.substr(0, eq)));
        const std::string value = unquote(trim(line.substr(eq + 1)));
        if (key == "Shuangpin") {
            // 0.3.12 及以前的双拼开关：只在没有 InputScheme 时算
            oldShuangpin = value == "True";
            continue;
        }
        config.setValue(key, value);
        sawTranslateLocal = sawTranslateLocal || key == "TranslateLocal";
        sawInputScheme = sawInputScheme || key == "InputScheme";
    }
    if (!sawTranslateLocal) {
        config.values_["TranslateLocal"] = impliedTranslateLocal(config.value("TranslateBaseUrl")) ? "True" : "False";
    }
    if (!sawInputScheme && oldShuangpin) {
        config.values_["InputScheme"] = "Shuangpin";
    }
    return config;
}

std::string Config::value(const std::string &key) const {
    const auto it = values_.find(key);
    return it == values_.end() ? std::string() : it->second;
}

void Config::setValue(const std::string &key, std::string_view value) {
    const SettingDef *def = find(key);
    if (!def) {
        return;
    }
    switch (def->type) {
    case T::Bool:
        // 开关只认 True / False，和 fcitx5 一样；别的写法保持原值
        if (value == "True" || value == "False") {
            values_[key] = std::string(value);
        }
        break;
    case T::Enum:
        if (std::find(def->values.begin(), def->values.end(), value) != def->values.end()) {
            values_[key] = std::string(value);
        }
        break;
    case T::Int:
        if (const auto n = parseInt(value)) {
            values_[key] = std::to_string(std::clamp<long long>(*n, def->min, def->max));
        }
        break;
    case T::String:
        values_[key] = std::string(value);
        break;
    case T::Key:
        if (key == "VoiceKey") {
            values_[key] = std::string(value);
            break;
        }
        // 留空是不用；写错了保持原样
        if (value.empty()) {
            values_[key].clear();
        } else if (const auto shortcut = Shortcut::parse(value)) {
            values_[key] = shortcut->name();
        }
        break;
    }
}

std::string Config::templateText() {
    std::string out = "# WowType 设置（键名、取值和 Linux、macOS 的 wowtype.conf 一样，见 docs/CONFIG.md）。\n"
                      "# 前面带 # 的设置行是默认值，不生效；要改哪一项，去掉那一行前面的 # 再改值。\n"
                      "# 改完保存，下一次按键时生效；删掉一行就是用默认值。注释要单独写一行。\n"
                      "# 设置窗口只写和默认值不一样的项，以后默认值变了，没改过的项跟着变。\n\n";
    const Config d;
    for (const auto &def : settingDefs()) {
        out += std::string("# ") + def.key + "=" + quote(d.value(def.key)) + "\n";
    }
    return out;
}

std::string Config::serialized(const std::string *existing) const {
    if (!existing || blank(*existing)) {
        const std::string text = templateText();
        return serialized(&text);
    }
    // 按 \n 拆，每行末尾的 \r 留着
    std::vector<std::string> lines;
    {
        std::size_t start = 0;
        while (true) {
            const std::size_t nl = existing->find('\n', start);
            lines.push_back(existing->substr(start, nl == std::string::npos ? std::string::npos : nl - start));
            if (nl == std::string::npos) {
                break;
            }
            start = nl + 1;
        }
    }
    std::map<std::string, bool> seen;
    std::optional<std::size_t> firstGroup;
    bool crlf = false;
    std::vector<std::size_t> oldShuangpin;
    std::map<std::string, std::size_t> commented;
    for (std::size_t i = 0; i < lines.size(); ++i) {
        std::string line = lines[i];
        const bool cr = !line.empty() && line.back() == '\r';
        if (cr) {
            line.pop_back();
            crlf = true;
        }
        const std::string_view body = trim(line);
        if (!body.empty() && body.front() == '[' && !firstGroup) {
            firstGroup = i;
        }
        if (!firstGroup && !body.empty() && body.front() == '#') {
            // 注释掉的设置行（# PageSize=9、#PageSize=9）：这个键要写进去时就地换成生效的
            const std::string_view rest = body.substr(1);
            const std::size_t eq = rest.find('=');
            if (eq != std::string_view::npos) {
                const std::string key(trim(rest.substr(0, eq)));
                if (find(key) && !commented.count(key)) {
                    commented[key] = i;
                }
            }
        }
        if (firstGroup || body.empty() || body.front() == '#' || body.front() == ';') {
            continue;
        }
        const std::size_t eq = line.find('=');
        if (eq == std::string::npos) {
            continue;
        }
        const std::string key(trim(std::string_view(line).substr(0, eq)));
        if (key == "Shuangpin") {
            oldShuangpin.push_back(i);
            continue;
        }
        if (!find(key)) {
            continue;
        }
        const std::string wanted = value(key);
        seen[key] = true;
        // 这一行单独读出来（从默认值开始）已经是要的值：不动
        Config probe;
        probe.setValue(key, unquote(trim(std::string_view(line).substr(eq + 1))));
        if (probe.value(key) == wanted) {
            continue;
        }
        std::size_t start = eq + 1;
        while (start < line.size() && (line[start] == ' ' || line[start] == '\t')) {
            ++start;
        }
        lines[i] = line.substr(0, start) + quote(wanted) + (cr ? "\r" : "");
    }
    // 文件里没有的键读出来是默认值；TranslateLocal 没写时跟着 TranslateBaseUrl 走
    Config implied;
    implied.values_["TranslateLocal"] = impliedTranslateLocal(value("TranslateBaseUrl")) ? "True" : "False";
    std::vector<std::string> missing;
    for (const auto &def : settingDefs()) {
        const std::string key = def.key;
        if (seen.count(key) || value(key) == implied.value(key)) {
            continue;
        }
        const std::string entry = key + "=" + quote(value(key)) + (crlf ? "\r" : "");
        if (const auto it = commented.find(key); it != commented.end()) {
            lines[it->second] = entry;
        } else {
            missing.push_back(entry);
        }
    }
    for (auto it = oldShuangpin.rbegin(); it != oldShuangpin.rend(); ++it) {
        lines.erase(lines.begin() + static_cast<std::ptrdiff_t>(*it));
    }
    if (firstGroup) {
        *firstGroup -= oldShuangpin.size();
    }
    if (!missing.empty()) {
        // 补在最后一个设置后面：跳过 [分组]（或文件末尾）前面的空行
        std::size_t at = firstGroup ? *firstGroup : lines.size();
        while (at > 0 && (trim(lines[at - 1]).empty() || lines[at - 1] == "\r")) {
            --at;
        }
        lines.insert(lines.begin() + static_cast<std::ptrdiff_t>(at), missing.begin(), missing.end());
    }
    std::string out;
    for (std::size_t i = 0; i < lines.size(); ++i) {
        out += (i ? "\n" : "") + lines[i];
    }
    return out;
}

std::string Config::merged(const Config &base, const std::string *current) const {
    Config target = current ? parse(*current) : Config();
    for (const auto &def : settingDefs()) {
        const std::string mine = value(def.key);
        if (mine != base.value(def.key)) {
            target.setValue(def.key, mine);
        }
    }
    return target.serialized(current);
}

int Config::number(const char *key) const {
    const auto n = parseInt(value(key));
    return n ? static_cast<int>(*n) : 0;
}

uint32_t Config::fuzzyGroups() const {
    static const std::pair<const char *, uint32_t> groups[] = {
        {"FuzzyZh", 1},      {"FuzzyCh", 2},          {"FuzzySh", 4},        {"FuzzyNL", 8},
        {"FuzzyFH", 16},     {"FuzzyRL", 32},         {"FuzzyAn", 64},       {"FuzzyEn", 128},
        {"FuzzyIn", 256},    {"FuzzyIan", 512},       {"FuzzyUan", 1024},    {"FuzzyUn", 2048},
        {"FuzzyAnAi", 4096}, {"FuzzyHuangWang", 8192}, {"FuzzyUnIong", 16384}, {"FuzzyEngOng", 32768},
    };
    uint32_t out = 0;
    for (const auto &[key, bit] : groups) {
        if (flag(key)) {
            out |= bit;
        }
    }
    return out;
}

uint32_t Config::pageKeys() const {
    return (flag("PageKeysMinusEqual") ? WOWTYPE_PAGE_KEYS_MINUS : 0u) |
           (flag("PageKeysBracket") ? WOWTYPE_PAGE_KEYS_BRACKET : 0u) |
           (flag("PageKeysCommaPeriod") ? WOWTYPE_PAGE_KEYS_COMMA : 0u) | (flag("PageKeysTab") ? WOWTYPE_PAGE_KEYS_TAB : 0u);
}

int Config::selectKeys() const {
    if (is("SelectKeys", "Semicolon")) {
        return WOWTYPE_SELECT_KEYS_SEMICOLON;
    }
    if (is("SelectKeys", "SemicolonQuote")) {
        return WOWTYPE_SELECT_KEYS_SEMICOLON_QUOTE;
    }
    return WOWTYPE_SELECT_KEYS_OFF;
}

int Config::arrowKeys() const {
    return is("ArrowKeys", "Caret") ? WOWTYPE_ARROW_KEYS_CARET : WOWTYPE_ARROW_KEYS_CANDIDATES;
}

int Config::shiftToggle() const {
    if (is("ShiftToggle", "Left")) {
        return WOWTYPE_SHIFT_TOGGLE_LEFT;
    }
    if (is("ShiftToggle", "Right")) {
        return WOWTYPE_SHIFT_TOGGLE_RIGHT;
    }
    if (is("ShiftToggle", "Off")) {
        return WOWTYPE_SHIFT_TOGGLE_OFF;
    }
    return WOWTYPE_SHIFT_TOGGLE_BOTH;
}

uint32_t Config::autoSpaceFlags() const {
    if (!flag("AutoSpace")) {
        return 0;
    }
    return (flag("AutoSpaceLetters") ? 1u : 0u) | (flag("AutoSpaceDigits") ? 2u : 0u);
}

std::optional<Shortcut> Config::shortcut(const char *key) const {
    const std::string name = value(key);
    if (name.empty()) {
        return std::nullopt;
    }
    return Shortcut::parse(name);
}

} // namespace wowtype
