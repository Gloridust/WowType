#include "wowtype_engine.h"
#include "clipboard_copy.h"
#include "wowtype_log.h"

#include <algorithm>
#include <chrono>
#include <ctime>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>

#include <fcitx-config/iniparser.h>
#include <fcitx/addonfactory.h>
#include <fcitx/addonmanager.h>
#include <fcitx/candidatelist.h>
#include <fcitx/globalconfig.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputcontextmanager.h>
#include <fcitx/inputpanel.h>
#include <fcitx/instance.h>
#include <fcitx/text.h>
#include <fcitx/userinterface.h>
#include <fcitx-utils/event.h>
#include <fcitx-utils/key.h>
#include <fcitx-utils/keysym.h>
#include <fcitx-utils/log.h>
#include <fcitx-utils/misc.h>
#include <fcitx-utils/utf8.h>
#include <fcitx-utils/textformatflags.h>

// fcitx5 自带的 clipboard 插件对外的函数（和它的 clipboard_public.h 一样，自 5.0 起没变过）。
// 抄在这里免得依赖 fcitx5-modules-dev；没装这个插件时 addon("clipboard") 是空的，不调用。
FCITX_ADDON_DECLARE_FUNCTION(Clipboard, clipboard, std::string(const fcitx::InputContext *ic));

namespace {

// 系统词库目录：CMake 按安装前缀传进来（Nix 等不装在 /usr 的发行版）
#ifndef WOWTYPE_SYSTEM_DATA_DIR
#define WOWTYPE_SYSTEM_DATA_DIR "/usr/share/wowtype"
#endif
constexpr const char *kSystemDataDir = WOWTYPE_SYSTEM_DATA_DIR;
/// 展开的候选面板：每行几个、一屏几行（照微信输入法：6 × 6）。
constexpr std::size_t kGridCols = 6;
constexpr std::size_t kGridRows = 6;
/// 候选总数上限（约 33 页 × 9 个）。
constexpr unsigned int kMaxCandidates = 300;
/// 上下文只保留尾部这么多字节：bigram 特征只看紧邻的上文。
constexpr std::size_t kContextBytes = 24;
/// 每上屏这么多次保存一次用户词库（另外失去焦点和退出时也保存）。
constexpr int kSaveEvery = 20;
/// 表情面板最多列这么多个（空搜索时是全部 emoji）。
constexpr std::size_t kMaxEmoji = 2000;
/// 记住最近用过的 emoji 个数（面板里排最前，正好三行）。
constexpr std::size_t kRecentEmoji = 18;
/// 打字推荐的 emoji 插在第几个候选（从 0 数）：不挤掉前两个词。
constexpr std::size_t kEmojiSlot = 2;

bool envFlag(const char *name, bool fallback) {
    const char *value = std::getenv(name);
    if (!value || !*value) {
        return fallback;
    }
    return *value != '0';
}

constexpr const char *kConfigFile = "conf/wowtype.conf";

std::string userDataDir() {
    std::string base;
    if (const char *data = std::getenv("XDG_DATA_HOME"); data && *data) {
        base = data;
    } else if (const char *home = std::getenv("HOME"); home && *home) {
        base = std::string(home) + "/.local/share";
    } else {
        return {};
    }
    return base + "/wowtype";
}

/// 按顺序找第一个存在的文件：环境变量 > 用户数据目录 > 系统目录。
std::string findDataFile(const char *envName, const std::string &fileName) {
    if (const char *env = std::getenv(envName); env && *env) {
        return env;
    }
    std::error_code ec;
    const std::string user = userDataDir();
    if (!user.empty() && std::filesystem::exists(user + "/" + fileName, ec)) {
        return user + "/" + fileName;
    }
    const std::string system = std::string(kSystemDataDir) + "/" + fileName;
    if (std::filesystem::exists(system, ec)) {
        return system;
    }
    return {};
}

/// 去掉末尾一个 UTF-8 字符。
void popUtf8(std::string &text) {
    while (!text.empty()) {
        const auto byte = static_cast<unsigned char>(text.back());
        text.pop_back();
        if ((byte & 0xC0) != 0x80) {
            break;
        }
    }
}

/// 只留尾部 maxBytes 字节，起点对齐到 UTF-8 字符边界。
std::string utf8Tail(const std::string &text, std::size_t maxBytes) {
    if (text.size() <= maxBytes) {
        return text;
    }
    std::size_t start = text.size() - maxBytes;
    while (start < text.size() &&
           (static_cast<unsigned char>(text[start]) & 0xC0) == 0x80) {
        ++start;
    }
    return text.substr(start);
}

constexpr uint64_t kVoicePollUsec = 50 * 1000;
constexpr std::size_t kVoiceBars = 6;

/// 音量（0–100）画成一排竖条，不足 kVoiceBars 个时左边补最低的条。
std::string voiceWave(const std::vector<int> &levels) {
    static const char *const kBlocks[] = {"▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"};
    std::string out;
    for (std::size_t i = levels.size(); i < kVoiceBars; ++i) {
        out += kBlocks[0];
    }
    for (const int level : levels) {
        out += kBlocks[std::clamp(level, 0, 100) * 7 / 100];
    }
    return out;
}
constexpr uint64_t kVoiceErrorUsec = 1500 * 1000;
/// 互译：原文停下来这么久才发请求（句末标点立刻发），以及取结果的间隔。
constexpr uint64_t kTranslateDelayUsec = 500 * 1000;
// 定时器精度。fcitx5 底下是 sd-event，传 0 等于默认的 250ms，50ms 的轮询实际一秒只有 4 次
constexpr uint64_t kTimerAccuracyUsec = 1000;
constexpr uint64_t kTranslatePollUsec = 50 * 1000;

std::string userConfigDir() {
    if (const char *config = std::getenv("XDG_CONFIG_HOME"); config && *config) {
        return std::string(config) + "/wowtype";
    }
    if (const char *home = std::getenv("HOME"); home && *home) {
        return std::string(home) + "/.config/wowtype";
    }
    return {};
}

/// 这段文字以句末标点（或换行）结尾：一句话多半打完了，马上翻译。
bool endsSentence(const std::string &text) {
    for (const char *end : {"。", "！", "？", "…", ".", "!", "?", "\n"}) {
        const std::string_view e(end);
        if (text.size() >= e.size() && text.compare(text.size() - e.size(), e.size(), e) == 0) {
            return true;
        }
    }
    return false;
}

// 语音浮条：WowType 的 GNOME 扩展注册这个名字，插件把语音状态发给它画。
// 信号 State(u 状态, s 文字, i 音量 0–100, i x, i y, i w, i h, b 相对窗口, d 缩放)，
// x/y/w/h 是光标矩形，和 kimpanel 的 SetSpotRect / SetRelativeSpotRectV2 同一个意思。
constexpr const char *kOverlayService = "io.github.gloridust.WowType.VoiceOverlay";
constexpr const char *kOverlayPath = "/io/github/gloridust/WowType";
constexpr const char *kOverlayInterface = "io.github.gloridust.WowType.Voice1";
constexpr uint32_t kOverlayHide = 0;
constexpr uint32_t kOverlayListening = 1;
constexpr uint32_t kOverlayRecognizing = 2;
constexpr uint32_t kOverlayDone = 3;
constexpr uint32_t kOverlayError = 4;

/// 用户输入习惯（词的热度、词搭配）和用户词库放在同一个目录：history.tsv。
std::string historyPathFor(const std::string &userDict) {
    if (const char *env = std::getenv("WOWTYPE_HISTORY"); env && *env) {
        return env;
    }
    if (userDict.empty()) {
        return {};
    }
    return (std::filesystem::path(userDict).parent_path() / "history.tsv").string();
}

/// 在后台线程里做的事：载入词库、语言模型、各种开关和用户词。
WowtypeEngineHandle *loadCore(const std::string &userDict) {
    std::string lexicon = findDataFile("WOWTYPE_LEXICON", "lexicon.tsv");
    if (lexicon.empty()) {
        lexicon = std::string(kSystemDataDir) + "/demo_lexicon.tsv";
        WLOG_W() << "WowType: 没找到 lexicon.tsv，用 demo 词典（只有几十个词）";
    }
    // 词级语言模型：wowtype-lmbuild 生成的 words.lm；没有就找旧的 bigram.tsv
    std::string lm = findDataFile("WOWTYPE_LM", "words.lm");
    if (lm.empty()) {
        lm = findDataFile("WOWTYPE_LM", "bigram.tsv");
    }
    const auto started = std::chrono::steady_clock::now();
    WowtypeEngineHandle *core =
        wowtype_engine_new(lexicon.c_str(), lm.empty() ? nullptr : lm.c_str());
    if (!core && !lm.empty()) {
        // 语言模型坏了（版本不对、文件不完整）不该让输入法整个用不了：不带它再试一次
        WLOG_W() << "WowType: 语言模型载入失败，不用它，文件=" << lm << "，错误="
                     << (wowtype_last_error() ? wowtype_last_error() : "unknown");
        lm.clear();
        core = wowtype_engine_new(lexicon.c_str(), nullptr);
    }
    if (!core) {
        WLOG_E() << "WowType: 初始化 Rust 核心失败，词典=" << lexicon
                      << "，错误="
                      << (wowtype_last_error() ? wowtype_last_error() : "unknown");
        return nullptr;
    }

    const std::string english = findDataFile("WOWTYPE_ENGLISH", "english.txt");
    if (!english.empty()) {
        const int loaded = wowtype_engine_load_english(core, english.c_str());
        if (loaded > 0) {
            WLOG_I() << "WowType: 载入英文词 " << loaded << " 个";
        }
    }
    // 微信输入法的字级神经语言模型（不随 WowType 分发，本机有才用）
    if (const std::string nnlm = findDataFile("WOWTYPE_NNLM", "wetype/nlrgpt2_nnlm.bin");
        !nnlm.empty()) {
        const int loaded = wowtype_engine_load_nnlm(core, nnlm.c_str());
        if (loaded > 0) {
            WLOG_I() << "WowType: 载入神经语言模型（" << loaded << " 字）";
        } else {
            WLOG_W() << "WowType: 神经语言模型载入失败 " << nnlm << "："
                         << (wowtype_last_error() ? wowtype_last_error() : "unknown");
        }
    }
    if (!userDict.empty()) {
        const int loaded = wowtype_engine_load_user_dict(core, userDict.c_str());
        if (loaded > 0) {
            WLOG_I() << "WowType: 载入用户词 " << loaded << " 条";
        }
    }
    if (const std::string history = historyPathFor(userDict);
        !history.empty() && std::filesystem::exists(history)) {
        const int loaded = wowtype_engine_load_history(core, history.c_str());
        if (loaded >= 0) {
            WLOG_I() << "WowType: 载入输入习惯 " << loaded << " 条";
        } else {
            WLOG_W() << "WowType: 输入习惯载入失败 " << history << "："
                         << (wowtype_last_error() ? wowtype_last_error() : "unknown");
        }
    }
    const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                        std::chrono::steady_clock::now() - started)
                        .count();
    WLOG_I() << "WowType: 词典 " << lexicon << " 载入完成，用时 " << ms << " ms"
                 << (lm.empty() ? "（没有语言模型）" : "，语言模型 " + lm);
    return core;
}

/// 候选窗里显示的样子：自定义词里的换行、制表符画成 ⏎、⇥，不把候选窗撑乱。
std::string shownText(const std::string &text) {
    if (text.find_first_of("\n\t") == std::string::npos) {
        return text;
    }
    std::string out;
    for (const char c : text) {
        if (c == '\n') {
            out += "⏎";
        } else if (c == '\t') {
            out += "⇥";
        } else {
            out.push_back(c);
        }
    }
    return out;
}

/// V 模式计算器认的字符（数字、运算符、括号），小键盘也算。不是的话返回 0。
char calcChar(const fcitx::Key &key) {
    const auto sym = key.sym();
    if (sym >= FcitxKey_0 && sym <= FcitxKey_9) {
        return static_cast<char>('0' + (sym - FcitxKey_0));
    }
    if (sym >= FcitxKey_KP_0 && sym <= FcitxKey_KP_9) {
        return static_cast<char>('0' + (sym - FcitxKey_KP_0));
    }
    switch (sym) {
    case FcitxKey_plus:
    case FcitxKey_KP_Add:
        return '+';
    case FcitxKey_minus:
    case FcitxKey_KP_Subtract:
        return '-';
    case FcitxKey_asterisk:
    case FcitxKey_KP_Multiply:
        return '*';
    case FcitxKey_slash:
    case FcitxKey_KP_Divide:
        return '/';
    case FcitxKey_period:
    case FcitxKey_KP_Decimal:
        return '.';
    case FcitxKey_percent:
        return '%';
    case FcitxKey_asciicircum:
        return '^';
    case FcitxKey_parenleft:
        return '(';
    case FcitxKey_parenright:
        return ')';
    default:
        return 0;
    }
}

class WowtypeCandidateWord final : public fcitx::CandidateWord {
public:
    WowtypeCandidateWord(WowtypeEngine *engine, WowtypeState *state,
                         std::size_t index, const std::string &text)
        : engine_(engine), state_(state), index_(index) {
        setText(fcitx::Text(shownText(text)));
    }

    void select(fcitx::InputContext *inputContext) const override {
        engine_->commitCandidate(inputContext, state_, index_);
    }

private:
    WowtypeEngine *engine_;
    WowtypeState *state_;
    std::size_t index_;
};

/// 展开面板的一行（一行里有好几个词）。
class WowtypeGridRow final : public fcitx::CandidateWord {
public:
    WowtypeGridRow(WowtypeEngine *engine, WowtypeState *state, std::size_t row,
                   const std::string &text)
        : engine_(engine), state_(state), row_(row) {
        setText(fcitx::Text(text));
    }

    void select(fcitx::InputContext *inputContext) const override {
        engine_->selectGridRow(inputContext, state_, row_);
    }

private:
    WowtypeEngine *engine_;
    WowtypeState *state_;
    std::size_t row_;
};

/// 工具栏列表里的一项（菜单、剪贴板历史、常用语）。
class WowtypeToolWord final : public fcitx::CandidateWord {
public:
    WowtypeToolWord(WowtypeEngine *engine, WowtypeState *state, std::size_t index,
                    const std::string &text)
        : engine_(engine), state_(state), index_(index) {
        setText(fcitx::Text(text));
    }

    void select(fcitx::InputContext *inputContext) const override {
        engine_->selectTool(inputContext, state_, index_);
    }

private:
    WowtypeEngine *engine_;
    WowtypeState *state_;
    std::size_t index_;
};

/// 显示宽度（半角为 1、其他为 2），用来把展开面板的各列对齐。
/// emoji 序列（变体选择符、肤色、零宽连接、旗帜）按一个宽字符算。
std::size_t displayWidth(const std::string &text) {
    std::size_t width = 0;
    bool joinNext = false;
    bool pendingFlag = false;
    for (std::size_t i = 0; i < text.size();) {
        const unsigned char c = static_cast<unsigned char>(text[i]);
        const std::size_t len = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;
        char32_t cp = len == 1 ? c : c & (0xFF >> (len + 1));
        for (std::size_t k = 1; k < len && i + k < text.size(); ++k) {
            cp = (cp << 6) | (static_cast<unsigned char>(text[i + k]) & 0x3F);
        }
        i += len;
        if (cp == 0x200D) {
            joinNext = true;
            continue;
        }
        const bool zeroWidth = cp == 0xFE0F || cp == 0xFE0E || cp == 0x20E3 ||
                               (cp >= 0x1F3FB && cp <= 0x1F3FF) ||
                               (cp >= 0xE0020 && cp <= 0xE007F);
        if (zeroWidth || joinNext) {
            joinNext = false;
            continue;
        }
        if (cp >= 0x1F1E6 && cp <= 0x1F1FF) { // 两个地区指示符拼成一面旗
            if (pendingFlag) {
                pendingFlag = false;
                continue;
            }
            pendingFlag = true;
            width += 2;
            continue;
        }
        pendingFlag = false;
        width += cp < 0x80 ? 1 : 2;
    }
    return width;
}

/// 用全角空格（宽 2）和半角空格（宽 1）补到 width。
void padTo(std::string &out, std::size_t have, std::size_t width) {
    while (have + 2 <= width) {
        out += "\u3000";
        have += 2;
    }
    if (have < width) {
        out += "\u2002";
    }
}

} // namespace

/// 已经选好、还没上屏的一个词（长句先选开头的词）。
struct WowtypeSelection {
    std::string text;
    std::string pinyin;
    /// 用掉的原始输入字节数。
    std::size_t bytes = 0;
};

struct WowtypeCandidate {
    std::string text;
    std::string pinyin;
    /// 用掉了剩余输入的多少字节；小于剩余长度说明是句首词候选。
    std::size_t consumed = 0;
    /// emoji 候选：选中时上屏 commit，记进最近用过的 emoji，不学习选词。
    bool emoji = false;
    std::string commit;
    /// emoji 本身（打字推荐的候选显示的是「开心😊」，这里是「😊」）。
    std::string emojiText;
    /// 日期时间、计算结果这类：选中时原样上屏，不学习选词。
    bool plain = false;
};

/// 每个输入上下文独立保存的缓冲区和候选。
class WowtypeState final : public fcitx::InputContextProperty {
public:
    /// 全部原始输入（包括已经选过词的部分）。
    std::string buffer_;
    std::vector<WowtypeSelection> selections_;
    std::vector<WowtypeCandidate> candidates_;
    /// 下键展开的候选面板；gridCursor_ 是光标所在候选的全局下标。
    bool expanded_ = false;
    std::size_t gridCursor_ = 0;
    /// 收起面板后普通候选列表的光标位置（刷新候选时归零）。
    std::size_t panelCursor_ = 0;
    /// 表情面板开着：buffer_ 里是搜索词（可以为空）。
    bool emojiPanel_ = false;
    /// 表情面板是从工具栏的「符号」打开的：没有搜索词时列全部符号。
    bool symbolPanel_ = false;
    /// 工具栏开着（菜单、剪贴板、常用语）：候选在 candidates_ 里，光标是 panelCursor_。
    WowtypeTool tool_ = WowtypeTool::None;
    /// 互译模式下攒着的原文（选好的字、标点）。上屏拼音后 clear() 不动它。
    std::string tsource_;
    /// 输入框里现在显示的译文（原文改了、新译文还没赶上时还是上一句的）。
    std::string tshown_;
    /// 按了回车但译文还没好：好了就上屏。
    bool tpending_ = false;
    /// 光标前一个字符是数字（应用不报告周围文字时，靠这个判断小数点）。
    bool afterDigit_ = false;
    /// emit 上屏次数，用来判断一次按键有没有自己上屏东西。
    unsigned emits_ = 0;

    std::size_t selectedBytes() const {
        std::size_t total = 0;
        for (const auto &selection : selections_) {
            total += selection.bytes;
        }
        return total;
    }
    /// 还没选词的那部分输入。
    std::string remaining() const {
        const std::size_t used = selectedBytes();
        return used >= buffer_.size() ? std::string() : buffer_.substr(used);
    }
    std::string selectedText() const {
        std::string text;
        for (const auto &selection : selections_) {
            text += selection.text;
        }
        return text;
    }
    bool composing() const { return !buffer_.empty(); }
    void clear() {
        emojiPanel_ = false;
        symbolPanel_ = false;
        tool_ = WowtypeTool::None;
        buffer_.clear();
        selections_.clear();
        candidates_.clear();
        expanded_ = false;
        gridCursor_ = 0;
        panelCursor_ = 0;
    }
};

WowtypeEngine::WowtypeEngine(fcitx::Instance *instance)
    : instance_(instance),
      core_(nullptr),
      factory_([](fcitx::InputContext &) { return new WowtypeState(); }) {
    instance_->inputContextManager().registerProperty("wowtype", &factory_);
    WLOG_I() << "WowType " << WOWTYPE_ADDON_VERSION << " 启动（fcitx5 " << fcitx::Instance::version()
             << "）";
    // 全量词库载入要几百毫秒，放后台，别卡住 fcitx 启动
    loading_ = std::async(std::launch::async, loadCore, userDictPath());
    fcitx::readAsIni(config_, kConfigFile);
    applyConfig();
    setupVoiceOverlay();
}

void WowtypeEngine::setupVoiceOverlay() {
    // WOWTYPE_VOICE_OVERLAY=0：不用 GNOME 扩展的浮条，一直用候选框里的文字提示
    if (!envFlag("WOWTYPE_VOICE_OVERLAY", true)) {
        return;
    }
    try {
        auto bus = std::make_unique<fcitx::dbus::Bus>(fcitx::dbus::BusType::Session);
        if (!bus->isOpen()) {
            return;
        }
        bus->attachEventLoop(&instance_->eventLoop());
        overlayBus_ = std::move(bus);
        overlayWatcher_ = std::make_unique<fcitx::dbus::ServiceWatcher>(*overlayBus_);
        overlayWatch_ = overlayWatcher_->watchService(
            kOverlayService,
            [this](const std::string &, const std::string &, const std::string &owner) {
                if (owner != overlayOwner_) {
                    overlayOwner_ = owner;
                    WLOG_I() << "WowType: 语音浮条" << (owner.empty() ? "不在了" : "就绪");
                }
            });
    } catch (const std::exception &e) {
        // 没有会话总线（比如测试里）：用文字提示
        WLOG_I() << "WowType: 连不上会话总线，语音用文字提示：" << e.what();
        overlayWatch_.reset();
        overlayWatcher_.reset();
        overlayBus_.reset();
    }
}

void WowtypeEngine::sendVoiceOverlay(fcitx::InputContext *ic, uint32_t state,
                                     const std::string &label, int level) {
    if (!overlayBus_ || overlayOwner_.empty()) {
        return;
    }
    int32_t x = 0, y = 0, w = 0, h = 0;
    bool relative = false;
    double scale = 1.0;
    if (ic) {
        const fcitx::Rect &rect = ic->cursorRect();
        x = rect.left();
        y = rect.top();
        w = rect.width();
        h = rect.height();
        relative = ic->capabilityFlags().test(fcitx::CapabilityFlag::RelativeRect);
        scale = ic->scaleFactor();
    }
    auto msg = overlayBus_->createSignal(kOverlayPath, kOverlayInterface, "State");
    msg.setDestination(overlayOwner_);
    msg << state << label << static_cast<int32_t>(std::clamp(level, 0, 100)) << x << y << w << h
        << relative << scale;
    msg.send();
}

void WowtypeEngine::setConfig(const fcitx::RawConfig &config) {
    config_.load(config, true);
    fcitx::safeSaveAsIni(config_, kConfigFile);
    applyConfig();
}

void WowtypeEngine::reloadConfig() {
    // 文件里没写的项回到默认值（设置界面删掉一项就是想恢复默认）
    config_ = WowtypeConfig();
    fcitx::readAsIni(config_, kConfigFile);
    applyConfig();
}

void WowtypeEngine::applyConfig() {
    const auto envOr = [](const char *name, bool configured) {
        return envFlag(name, configured);
    };
    horizontal_ = !envOr("WOWTYPE_VERTICAL", *config_.layout == WowtypeLayout::Vertical);
    pageSize_ = static_cast<std::size_t>(std::clamp(*config_.pageSize, 3, 9));
    pageMinus_ = *config_.pageKeysMinus;
    pageBracket_ = *config_.pageKeysBracket;
    pageComma_ = *config_.pageKeysComma;
    pageTab_ = *config_.pageKeysTab;
    if (const char *env = std::getenv("WOWTYPE_PAGE_KEYS"); env && *env) {
        // 逗号分隔：minus,bracket,comma,tab
        const std::string keys = std::string(",") + env + ",";
        pageMinus_ = keys.find(",minus,") != std::string::npos;
        pageBracket_ = keys.find(",bracket,") != std::string::npos;
        pageComma_ = keys.find(",comma,") != std::string::npos;
        pageTab_ = keys.find(",tab,") != std::string::npos;
    }
    fuzzy_ = envOr("WOWTYPE_FUZZY", *config_.fuzzy);
    // 位掩码，和核心的 syllable::fuzzy 一致
    fuzzyGroups_ = (*config_.fuzzyZh ? 1u : 0u) | (*config_.fuzzyCh ? 2u : 0u) |
                   (*config_.fuzzySh ? 4u : 0u) | (*config_.fuzzyNL ? 8u : 0u) |
                   (*config_.fuzzyFH ? 16u : 0u) | (*config_.fuzzyRL ? 32u : 0u) |
                   (*config_.fuzzyAn ? 64u : 0u) | (*config_.fuzzyEn ? 128u : 0u) |
                   (*config_.fuzzyIn ? 256u : 0u) | (*config_.fuzzyIan ? 512u : 0u) |
                   (*config_.fuzzyUan ? 1024u : 0u) | (*config_.fuzzyUn ? 2048u : 0u);
    if (const char *env = std::getenv("WOWTYPE_FUZZY_GROUPS"); env && *env) {
        fuzzyGroups_ = static_cast<unsigned>(std::strtoul(env, nullptr, 0));
    }
    selectKeys_ = *config_.selectKeys;
    if (const char *env = std::getenv("WOWTYPE_SELECT_KEYS"); env && *env) {
        const std::string name = env;
        selectKeys_ = name == "semicolon"   ? WowtypeSelectKeys::Semicolon
                      : name == "quote"     ? WowtypeSelectKeys::SemicolonQuote
                                            : WowtypeSelectKeys::Off;
    }
    dateTime_ = envOr("WOWTYPE_DATETIME", *config_.dateTime);
    calculator_ = envOr("WOWTYPE_CALC", *config_.calculator);
    toolbar_ = envOr("WOWTYPE_TOOLBAR", *config_.toolbar);
    clipboardHistory_ = envOr("WOWTYPE_CLIPBOARD_HISTORY", *config_.clipboardHistory);
    if (!clipboardHistory_) {
        wowtype_clipboard_clear();
    }
    autoSpaceFlags_ = *config_.autoSpace ? (*config_.autoSpaceLetters ? 1 : 0) |
                                               (*config_.autoSpaceDigits ? 2 : 0)
                                         : 0;
    if (const char *env = std::getenv("WOWTYPE_AUTOSPACE"); env && *env) {
        autoSpaceFlags_ = static_cast<int>(std::strtol(env, nullptr, 0)) & 3;
    }
    typo_ = envOr("WOWTYPE_TYPO", *config_.typo);
    shuangpin_ = envOr("WOWTYPE_SHUANGPIN", *config_.shuangpin);
    shuangpinScheme_ = WowtypeShuangpinSchemeToString(*config_.shuangpinScheme);
    if (const char *env = std::getenv("WOWTYPE_SHUANGPIN_SCHEME"); env && *env) {
        // 环境变量设了方案就当作打开双拼（方便测试）
        shuangpinScheme_ = env;
        shuangpin_ = true;
    }
    shuangpinSemicolon_ = wowtype_shuangpin_uses_semicolon(shuangpinScheme_.c_str()) == 1;
    shiftToggle_ = *config_.shiftToggle;
    if (const char *env = std::getenv("WOWTYPE_SHIFT_TOGGLE"); env && *env) {
        const std::string name = env;
        shiftToggle_ = name == "left"    ? WowtypeShiftToggle::Left
                       : name == "right" ? WowtypeShiftToggle::Right
                       : name == "off" || name == "0" ? WowtypeShiftToggle::Off
                                                      : WowtypeShiftToggle::Both;
    }
    if (shiftToggle_ == WowtypeShiftToggle::Off) {
        asciiMode_ = false;
        translateMode_ = false;
    }
    punctStyle_ = *config_.punctStyle;
    if (const char *env = std::getenv("WOWTYPE_PUNCT_STYLE"); env && *env) {
        const std::string name = env;
        punctStyle_ = name == "half" || name == "halfwidth" ? WowtypePunctStyle::Halfwidth
                                                            : WowtypePunctStyle::Fullwidth;
    }
    traditional_ = envOr("WOWTYPE_TRADITIONAL", *config_.traditional);
    emojiSuggest_ = envOr("WOWTYPE_EMOJI", *config_.emojiSuggest);
    emojiKey_ = *config_.emojiKey;

    // 语音热键：WOWTYPE_VOICE_KEY（fcitx 键名，如 Alt_R、Control_R、F8）优先，none 关掉
    fcitx::Key key = *config_.voice ? *config_.voiceKey : fcitx::Key();
    if (const char *env = std::getenv("WOWTYPE_VOICE_KEY"); env && *env) {
        const std::string name = env;
        key = name == "none" || name == "0" ? fcitx::Key() : fcitx::Key(name);
        if (key.sym() == FcitxKey_None && name != "none" && name != "0") {
            WLOG_W() << "WowType: 不认识语音热键 " << name << "，改用 Alt_R";
            key = fcitx::Key(FcitxKey_Alt_R);
        }
    }
    if (key.sym() != voiceKey_.sym() || key.states() != voiceKey_.states()) {
        if (voiceActive()) {
            cancelVoice();
        }
        voiceKeyDown_ = false;
    }
    voiceKey_ = key;
    voiceCopy_ = envOr("WOWTYPE_VOICE_COPY", *config_.voiceCopy);
    if (voiceKey_.sym() != FcitxKey_None && !voice_) {
        // 只建句柄：不开麦克风、不下载模型，第一次按热键时才做
        const char *dir = std::getenv("WOWTYPE_VOICE_MODEL_DIR");
        voice_ = wowtype_voice_new(dir);
    }
    // 互译：环境变量 WOWTYPE_TRANSLATE_URL / _MODEL / _TARGET / _KEY_FILE 覆盖（测试用）
    translateEnabled_ = envOr("WOWTYPE_TRANSLATE", *config_.translate);
    std::string translateUrl = *config_.translateBaseUrl;
    std::string translateModel = *config_.translateModel;
    std::string translateTarget = WowtypeTranslateTargetToString(*config_.translateTarget);
    if (const char *env = std::getenv("WOWTYPE_TRANSLATE_URL"); env && *env) {
        translateUrl = env;
    }
    if (const char *env = std::getenv("WOWTYPE_TRANSLATE_MODEL"); env && *env) {
        translateModel = env;
    }
    if (const char *env = std::getenv("WOWTYPE_TRANSLATE_TARGET"); env && *env) {
        translateTarget = env;
    }
    if (translateEnabled_ && !translator_) {
        translator_ = wowtype_translate_new();
    }
    if (translator_) {
        wowtype_translate_configure(translator_, translateUrl.c_str(), translateModel.c_str(),
                                    translateTarget.c_str(), *config_.translateFormal ? 1 : 0,
                                    translateKeyFile().c_str());
    }
    if (translateMode_ && !translateAvailable()) {
        translateMode_ = false;
    }

    WLOG_I() << "WowType: 设置 " << (horizontal_ ? "横排" : "竖排") << " 每页" << pageSize_
             << " 模糊音=" << fuzzy_ << "(" << fuzzyGroups_ << ")" << " 纠错=" << typo_ << " 双拼=" << shuangpin_
             << "(" << shuangpinScheme_ << ")" << " Shift切换=" << static_cast<int>(shiftToggle_)
             << " 繁体=" << traditional_ << " 语音键=" << voiceKey_.toString()
             << " emoji推荐=" << emojiSuggest_ << " 表情键=" << emojiKey_.toString()
             << " 选词键=" << static_cast<int>(selectKeys_) << " 日期时间=" << dateTime_
             << " 计算器=" << calculator_ << " 工具栏=" << toolbar_
             << " 剪贴板历史=" << clipboardHistory_ << " 互译=" << translateEnabled_ << "("
             << (translateAvailable() ? translateModel + " → " + translateTarget : "未配置")
             << ")"
             << " 检查更新=" << *config_.checkUpdate;
    if (core_) {
        applyCoreSettings();
    }
}

void WowtypeEngine::applyCoreSettings() {
    // 前两页是排好序的整句、词和句首词，后面把能对上的同音词、句首词、单字全补上，
    // 翻页能一直翻到生僻字（每次按键多花不到 1ms）
    wowtype_engine_set_max_candidates(core_, kMaxCandidates);
    wowtype_engine_set_fuzzy(core_, fuzzy_ ? 1 : 0);
    wowtype_engine_set_fuzzy_groups(core_, fuzzyGroups_);
    wowtype_engine_set_shuangpin(core_, shuangpin_ ? 1 : 0);
    if (wowtype_engine_set_shuangpin_scheme(core_, shuangpinScheme_.c_str()) != 0) {
        WLOG_W() << "WowType: 不认识双拼方案 " << shuangpinScheme_ << "，用自然码";
        wowtype_engine_set_shuangpin_scheme(core_, "ziranma");
        shuangpinSemicolon_ = false;
    }
    wowtype_engine_set_typo_correction(core_, typo_ ? 1 : 0);
    if (traditional_ && !conversionLoaded_) {
        const std::string s2t = findDataFile("WOWTYPE_S2T", "s2t.tsv");
        const int loaded =
            s2t.empty() ? -1 : wowtype_engine_load_conversion(core_, s2t.c_str());
        if (loaded > 0) {
            conversionLoaded_ = true;
            WLOG_I() << "WowType: 载入简繁表 " << loaded << " 条";
        } else {
            WLOG_W() << "WowType: 简繁表载入失败 " << s2t;
        }
    }
    wowtype_engine_set_traditional(core_, traditional_ && conversionLoaded_ ? 1 : 0);

    if (const std::string custom = customWordsPath(); !custom.empty()) {
        const int loaded = wowtype_engine_load_custom_words(core_, custom.c_str());
        if (loaded < 0) {
            WLOG_W() << "WowType: 自定义词载入失败 " << custom << "："
                         << (wowtype_last_error() ? wowtype_last_error() : "unknown");
        } else if (loaded > 0) {
            WLOG_I() << "WowType: 载入自定义词 " << loaded << " 条";
        }
    }
}

std::string WowtypeEngine::customWordsPath() const {
    if (const char *env = std::getenv("WOWTYPE_CUSTOM"); env && *env) {
        return env;
    }
    const std::string dir = userDataDir();
    return dir.empty() ? std::string() : dir + "/custom.tsv";
}

bool WowtypeEngine::isVoiceKey(const fcitx::Key &key) const {
    if (voiceKey_.sym() == FcitxKey_None || key.sym() != voiceKey_.sym()) {
        return false;
    }
    // 单按修饰键（右 Alt 等）不管状态位；松开时状态位里会带着它自己
    if (voiceKey_.isModifier() || voiceKeyDown_) {
        return true;
    }
    const fcitx::KeyStates mask{fcitx::KeyState::SimpleMask};
    return (key.states() & mask) == (voiceKey_.states() & mask);
}

bool WowtypeEngine::isEmojiKey(const fcitx::Key &key) const {
    return emojiKey_.sym() != FcitxKey_None && key.checkKeyList(fcitx::KeyList{emojiKey_});
}

WowtypeEngine::~WowtypeEngine() {
    if (loading_.valid()) {
        core_ = loading_.get();
    }
    if (core_) {
        maybeSaveUserDict(true);
        wowtype_engine_free(core_);
        core_ = nullptr;
    }
    voiceTimer_.reset();
    if (voice_) {
        wowtype_voice_free(voice_);
        voice_ = nullptr;
    }
    translateTimer_.reset();
    if (translator_) {
        wowtype_translate_free(translator_);
        translator_ = nullptr;
    }
}

bool WowtypeEngine::coreReady() {
    if (core_) {
        return true;
    }
    if (loading_.valid() &&
        loading_.wait_for(std::chrono::seconds(0)) == std::future_status::ready) {
        core_ = loading_.get();
        if (core_) {
            applyCoreSettings();
            if (!recent_.empty()) {
                wowtype_engine_set_context(core_, recent_.c_str());
            }
        }
    }
    return core_ != nullptr;
}

std::string WowtypeEngine::userDictPath() const {
    if (const char *env = std::getenv("WOWTYPE_USER_DICT"); env && *env) {
        return env;
    }
    const std::string dir = userDataDir();
    if (dir.empty()) {
        return {};
    }
    std::error_code ec;
    std::filesystem::create_directories(dir, ec);
    return dir + "/user.tsv";
}

void WowtypeEngine::maybeSaveUserDict(bool force) {
    if (!core_ || (!force && unsavedCommits_ < kSaveEvery) || unsavedCommits_ == 0) {
        return;
    }
    const std::string path = userDictPath();
    if (path.empty()) {
        return;
    }
    const bool dictSaved = wowtype_engine_save_user_dict(core_, path.c_str()) == 0;
    const std::string history = historyPathFor(path);
    const bool historySaved =
        !history.empty() && wowtype_engine_save_history(core_, history.c_str()) == 0;
    if (!historySaved) {
        WLOG_W() << "WowType: 输入习惯保存失败 " << history << "："
                     << (wowtype_last_error() ? wowtype_last_error() : "unknown");
    }
    if (dictSaved && historySaved) {
        unsavedCommits_ = 0;
    }
}

void WowtypeEngine::rememberContext(const std::string &text) {
    recent_ = utf8Tail(recent_ + text, kContextBytes);
    if (core_) {
        wowtype_engine_set_context(core_, recent_.c_str());
    }
}

void WowtypeEngine::commitPlain(fcitx::InputContext *ic, const std::string &text) {
    if (!ic || text.empty()) {
        return;
    }
    emit(ic, text);
    rememberContext(text);
}

void WowtypeEngine::commitAll(fcitx::InputContext *ic, WowtypeState *state,
                              const std::string &tail,
                              const std::string &tailPinyin) {
    if (!ic) {
        return;
    }
    const std::string text = state->selectedText() + tail;
    if (!text.empty()) {
        emit(ic, text);
    }
    if (core_ && !text.empty()) {
        // 带上拼音：选够次数后引擎会自动把这个词收进用户词库
        if (!tail.empty()) {
            wowtype_engine_record_selection_ex(
                core_, tail.c_str(), tailPinyin.empty() ? nullptr : tailPinyin.c_str());
        }
        if (!state->selections_.empty() && !tail.empty() && !tailPinyin.empty()) {
            // 分几次选出来的整句也记一次，下次能一次打出来
            std::string pinyin;
            for (const auto &selection : state->selections_) {
                pinyin += selection.pinyin + " ";
            }
            pinyin += tailPinyin;
            wowtype_engine_record_selection_ex(core_, text.c_str(), pinyin.c_str());
        }
        ++unsavedCommits_;
    }
    state->clear();
    rememberContext(text);
    maybeSaveUserDict(false);
}

void WowtypeEngine::refreshCandidates(WowtypeState *state) {
    state->candidates_.clear();
    state->expanded_ = false;
    state->gridCursor_ = 0;
    state->panelCursor_ = 0;
    const std::string input = state->remaining();
    if (input.empty() || !coreReady()) {
        return;
    }
    if (calcActive(state) && input.size() > 1) {
        // V 模式：v 后面是算式，候选是结果和「算式=结果」
        if (WowtypeCandidates *raw = wowtype_calc_candidates(input.c_str() + 1)) {
            for (std::size_t i = 0; i < wowtype_candidates_len(raw); ++i) {
                if (const char *text = wowtype_candidates_text(raw, i)) {
                    WowtypeCandidate candidate{text, "", input.size()};
                    candidate.plain = true;
                    state->candidates_.push_back(std::move(candidate));
                }
            }
            wowtype_candidates_free(raw);
        }
        return;
    }

    WowtypeCandidates *raw = nullptr;
    {
        // 已经选了开头的词时，把它当上文，剩下的部分排序更准
        const std::string context = utf8Tail(recent_ + state->selectedText(), kContextBytes);
        wowtype_engine_set_context(core_, context.c_str());
        raw = wowtype_engine_input(core_, input.c_str());
    }
    if (!raw) {
        return;
    }

    const std::size_t count = wowtype_candidates_len(raw);
    for (std::size_t i = 0; i < count; ++i) {
        const char *text = wowtype_candidates_text(raw, i);
        if (!text) {
            continue;
        }
        const char *pinyin = wowtype_candidates_pinyin(raw, i);
        std::size_t consumed = wowtype_candidates_consumed(raw, i);
        if (consumed == 0 || consumed > input.size()) {
            consumed = input.size();
        }
        WowtypeCandidate candidate{text, pinyin ? pinyin : "", consumed};
        // 自定义词里带换行的，不往用户词库里记（词库是一行一条）
        candidate.plain = candidate.text.find_first_of("\n\t") != std::string::npos;
        state->candidates_.push_back(std::move(candidate));
    }
    wowtype_candidates_free(raw);
    if (emojiSuggest_) {
        addEmojiSuggestions(state, input);
        addKeycapSuggestion(state, input);
    }
    if (dateTime_ && state->selections_.empty()) {
        addDateTimeCandidates(state, input);
    }
}

void WowtypeEngine::addDateTimeCandidates(WowtypeState *state, const std::string &input) {
    auto &all = state->candidates_;
    if (all.empty()) {
        return;
    }
    // 全拼看打的字母（riqi、rq、date 等）；双拼看首选的拼音
    std::string key;
    if (shuangpin_) {
        if (all.front().consumed < input.size()) {
            return;
        }
        key = all.front().pinyin;
    } else {
        key = input;
    }
    const std::time_t now = std::time(nullptr);
    std::tm local{};
    if (!localtime_r(&now, &local)) {
        return;
    }
    WowtypeCandidates *raw = wowtype_datetime_candidates(
        key.c_str(), local.tm_year + 1900, local.tm_mon + 1, local.tm_mday, local.tm_hour,
        local.tm_min, local.tm_sec, local.tm_wday);
    if (!raw) {
        return;
    }
    std::vector<WowtypeCandidate> extra;
    for (std::size_t i = 0; i < wowtype_candidates_len(raw); ++i) {
        if (const char *text = wowtype_candidates_text(raw, i)) {
            WowtypeCandidate candidate{text, "", input.size()};
            candidate.plain = true;
            extra.push_back(std::move(candidate));
        }
    }
    wowtype_candidates_free(raw);
    // 首选还是那个词（日期、时间），格式从第二个开始
    all.insert(all.begin() + 1, extra.begin(), extra.end());
}

void WowtypeEngine::commitPlainCandidate(fcitx::InputContext *ic, WowtypeState *state,
                                         std::size_t index) {
    if (!ic || index >= state->candidates_.size()) {
        return;
    }
    const std::string text = state->selectedText() + state->candidates_[index].text;
    if (!text.empty()) {
        emit(ic, text);
        rememberContext(text);
    }
    state->clear();
    updateInputPanel(ic, state);
}

void WowtypeEngine::addEmojiSuggestions(WowtypeState *state, const std::string &input) {
    auto &all = state->candidates_;
    if (all.empty() || all.front().consumed < input.size()) {
        return;
    }
    const std::string top = all.front().text;
    WowtypeCandidates *raw = wowtype_emoji_recommend(top.c_str(), 1);
    if (!raw) {
        return;
    }
    std::vector<WowtypeCandidate> emoji;
    for (std::size_t i = 0; i < wowtype_candidates_len(raw); ++i) {
        const char *text = wowtype_candidates_text(raw, i);
        const char *commit = wowtype_candidates_commit(raw, i);
        if (!text || !commit) {
            continue;
        }
        WowtypeCandidate candidate{text, "", input.size()};
        candidate.emoji = true;
        candidate.commit = commit;
        // 句尾对上时 commit 是「整句 + emoji」
        candidate.emojiText = candidate.commit.rfind(top, 0) == 0
                                  ? candidate.commit.substr(top.size())
                                  : candidate.commit;
        emoji.push_back(std::move(candidate));
    }
    wowtype_candidates_free(raw);
    const std::size_t at = std::min(kEmojiSlot, all.size());
    all.insert(all.begin() + static_cast<std::ptrdiff_t>(at), emoji.begin(), emoji.end());
}

void WowtypeEngine::addKeycapSuggestion(WowtypeState *state, const std::string &input) {
    auto &all = state->candidates_;
    // 第一页里有数字字就在它后面跟按键 emoji：打 ba 是「吧 八 8️⃣ 把」，和手机输入法一样
    const std::size_t window = std::min(all.size(), pageSize_);
    for (std::size_t i = 0; i < window; ++i) {
        if (all[i].emoji || all[i].consumed < input.size()) {
            continue;
        }
        const char *keycap = wowtype_emoji_keycap(all[i].text.c_str());
        if (!keycap) {
            continue;
        }
        WowtypeCandidate candidate{keycap, "", input.size()};
        candidate.emoji = true;
        candidate.commit = keycap;
        candidate.emojiText = keycap;
        all.insert(all.begin() + static_cast<std::ptrdiff_t>(i + 1), std::move(candidate));
        return;
    }
}

std::string WowtypeEngine::recentEmojiPath() const {
    const std::string dir = userDataDir();
    return dir.empty() ? std::string() : dir + "/emoji-recent.txt";
}

void WowtypeEngine::rememberEmoji(const std::string &emoji) {
    if (emoji.empty()) {
        return;
    }
    recentEmoji_.erase(std::remove(recentEmoji_.begin(), recentEmoji_.end(), emoji),
                       recentEmoji_.end());
    recentEmoji_.insert(recentEmoji_.begin(), emoji);
    if (recentEmoji_.size() > kRecentEmoji) {
        recentEmoji_.resize(kRecentEmoji);
    }
    const std::string path = recentEmojiPath();
    if (path.empty()) {
        return;
    }
    std::error_code ec;
    std::filesystem::create_directories(std::filesystem::path(path).parent_path(), ec);
    std::ofstream out(path, std::ios::trunc);
    for (const auto &item : recentEmoji_) {
        out << item << '\n';
    }
}

void WowtypeEngine::openEmojiPanel(fcitx::InputContext *ic, WowtypeState *state) {
    if (!recentEmojiLoaded_) {
        recentEmojiLoaded_ = true;
        std::ifstream in(recentEmojiPath());
        std::string line;
        while (recentEmoji_.size() < kRecentEmoji && std::getline(in, line)) {
            if (!line.empty()) {
                recentEmoji_.push_back(line);
            }
        }
    }
    // 打了一半的拼音拿来当搜索词（xiao + 快捷键 -> 笑相关的 emoji）
    std::string query;
    if (state->composing()) {
        if (state->selections_.empty()) {
            for (char c : state->remaining()) {
                if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) {
                    query.push_back(static_cast<char>(c | 0x20));
                }
            }
        } else {
            commitAll(ic, state, state->remaining(), {});
        }
    }
    state->clear();
    state->emojiPanel_ = true;
    state->buffer_ = query;
    refreshEmojiPanel(state);
    updateInputPanel(ic, state);
}

void WowtypeEngine::refreshEmojiPanel(WowtypeState *state) {
    state->candidates_.clear();
    state->gridCursor_ = 0;
    state->expanded_ = true;
    const std::string &query = state->buffer_;
    auto add = [&](const std::string &text) {
        for (const auto &have : state->candidates_) {
            if (have.text == text) {
                return;
            }
        }
        WowtypeCandidate candidate{text, "", 0};
        candidate.emoji = true;
        candidate.commit = text;
        candidate.emojiText = text;
        state->candidates_.push_back(std::move(candidate));
    };
    if (query.empty() && state->symbolPanel_) {
        if (WowtypeCandidates *all = wowtype_symbol_list()) {
            const std::size_t count = wowtype_candidates_len(all);
            for (std::size_t i = 0; i < count; ++i) {
                if (const char *text = wowtype_candidates_text(all, i)) {
                    add(text);
                }
            }
            wowtype_candidates_free(all);
        }
        return;
    }
    if (query.empty()) {
        for (const auto &emoji : recentEmoji_) {
            add(emoji);
        }
    }
    WowtypeCandidates *raw =
        wowtype_engine_emoji_search(coreReady() ? core_ : nullptr, query.c_str(), kMaxEmoji);
    if (!raw) {
        return;
    }
    for (std::size_t i = 0; i < wowtype_candidates_len(raw); ++i) {
        if (const char *text = wowtype_candidates_text(raw, i)) {
            add(text);
        }
    }
    wowtype_candidates_free(raw);
}

void WowtypeEngine::closeEmojiPanel(fcitx::InputContext *ic, WowtypeState *state) {
    state->clear();
    updateInputPanel(ic, state);
}

void WowtypeEngine::openSymbolPanel(fcitx::InputContext *ic, WowtypeState *state) {
    state->clear();
    state->emojiPanel_ = true;
    state->symbolPanel_ = true;
    refreshEmojiPanel(state);
    updateInputPanel(ic, state);
}

namespace {
constexpr std::size_t kToolPageSize = 9;
const char *const kToolMenu[] = {"剪贴板", "常用语", "符号", "表情"};

/// 列表里一行显示的样子：换行、制表符换成符号，太长的截断。
std::string toolLine(const std::string &text) {
    constexpr std::size_t kMaxChars = 40;
    std::string out;
    std::size_t chars = 0;
    for (std::size_t i = 0; i < text.size() && chars < kMaxChars;) {
        const unsigned char c = static_cast<unsigned char>(text[i]);
        const std::size_t len = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;
        if (c == '\n') {
            out += "⏎"; // ⏎
        } else if (c == '\t' || c == '\r') {
            out += ' ';
        } else {
            out.append(text, i, len);
        }
        i += len;
        if (++chars == kMaxChars && i < text.size()) {
            out += "…";
        }
    }
    return out;
}
} // namespace

void WowtypeEngine::sampleClipboard(fcitx::InputContext *ic) {
    if (!clipboardHistory_ || !ic) {
        return;
    }
    // 密码框里不记（clipboard 插件自己也不记标成密码的内容）
    if (ic->capabilityFlags().testAny(fcitx::CapabilityFlag::PasswordOrSensitive)) {
        return;
    }
    auto *addon = instance_->addonManager().addon("clipboard");
    if (!addon) {
        return;
    }
    const std::string text = addon->call<fcitx::IClipboard::clipboard>(ic);
    if (!text.empty()) {
        wowtype_clipboard_remember(text.c_str());
    }
}

void WowtypeEngine::openTool(fcitx::InputContext *ic, WowtypeState *state, WowtypeTool tool) {
    state->clear();
    state->tool_ = tool;
    auto add = [state](const std::string &shown, const std::string &commit) {
        WowtypeCandidate candidate{shown, "", 0};
        candidate.commit = commit;
        candidate.plain = true;
        state->candidates_.push_back(std::move(candidate));
    };
    auto addAll = [&](WowtypeCandidates *raw, bool withCode) {
        if (!raw) {
            return;
        }
        const std::size_t count = wowtype_candidates_len(raw);
        for (std::size_t i = 0; i < count; ++i) {
            const char *text = wowtype_candidates_text(raw, i);
            const char *commit = wowtype_candidates_commit(raw, i);
            const char *code = wowtype_candidates_pinyin(raw, i);
            if (!text || !commit) {
                continue;
            }
            std::string shown = toolLine(text);
            if (withCode && code && *code) {
                shown = std::string(code) + "　" + shown;
            }
            add(shown, commit);
        }
        wowtype_candidates_free(raw);
    };
    switch (tool) {
    case WowtypeTool::Menu:
        for (const char *item : kToolMenu) {
            add(item, "");
        }
        break;
    case WowtypeTool::Clipboard:
        sampleClipboard(ic);
        addAll(wowtype_clipboard_history(), false);
        break;
    case WowtypeTool::Phrases:
        if (coreReady()) {
            addAll(wowtype_engine_custom_phrases(core_), true);
        }
        break;
    case WowtypeTool::None:
        break;
    }
    updateInputPanel(ic, state);
}

void WowtypeEngine::fillToolPanel(fcitx::InputPanel &panel, WowtypeState *state) {
    std::string aux;
    switch (state->tool_) {
    case WowtypeTool::Menu:
        aux = "工具栏：数字键选择，Esc 关闭";
        break;
    case WowtypeTool::Clipboard:
        aux = state->candidates_.empty()
                  ? (clipboardHistory_ ? "剪贴板：还没有记录，复制过的文字会出现在这里"
                                       : "剪贴板：设置里关掉了剪贴板历史")
                  : "剪贴板：选一条上屏，退格返回";
        break;
    case WowtypeTool::Phrases:
        aux = state->candidates_.empty() ? "常用语：还没有，在设置的「自定义词」里添加"
                                         : "常用语：选一条上屏，退格返回";
        break;
    case WowtypeTool::None:
        return;
    }
    panel.setAuxUp(fcitx::Text(aux));
    if (state->candidates_.empty()) {
        return;
    }
    const std::size_t n = state->candidates_.size();
    state->panelCursor_ = std::min(state->panelCursor_, n - 1);
    auto list = std::make_unique<fcitx::CommonCandidateList>();
    list->setLayoutHint(fcitx::CandidateLayoutHint::Vertical);
    list->setPageSize(static_cast<int>(kToolPageSize));
    list->setSelectionKey(fcitx::Key::keyListFromString("1 2 3 4 5 6 7 8 9"));
    for (std::size_t i = 0; i < n; ++i) {
        list->append<WowtypeToolWord>(this, state, i, state->candidates_[i].text);
    }
    list->setGlobalCursorIndex(static_cast<int>(state->panelCursor_));
    panel.setCandidateList(std::move(list));
}

void WowtypeEngine::selectTool(fcitx::InputContext *ic, WowtypeState *state, std::size_t index) {
    if (!ic || index >= state->candidates_.size()) {
        return;
    }
    switch (state->tool_) {
    case WowtypeTool::Menu:
        switch (index) {
        case 0:
            openTool(ic, state, WowtypeTool::Clipboard);
            break;
        case 1:
            openTool(ic, state, WowtypeTool::Phrases);
            break;
        case 2:
            openSymbolPanel(ic, state);
            break;
        default:
            state->clear();
            openEmojiPanel(ic, state);
            break;
        }
        return;
    case WowtypeTool::Clipboard:
    case WowtypeTool::Phrases: {
        const std::string text = state->candidates_[index].commit;
        state->clear();
        if (!text.empty()) {
            emit(ic, text);
        }
        updateInputPanel(ic, state);
        return;
    }
    case WowtypeTool::None:
        return;
    }
}

bool WowtypeEngine::handleToolKey(fcitx::InputContext *ic, WowtypeState *state,
                                  const fcitx::Key &key) {
    const auto sym = key.sym();
    if (key.isModifier()) {
        return false;
    }
    if (key.states().testAny(fcitx::KeyStates{fcitx::KeyState::Ctrl, fcitx::KeyState::Alt,
                                              fcitx::KeyState::Super})) {
        // 别的组合键（复制粘贴等）：收起工具栏，交给应用
        state->clear();
        updateInputPanel(ic, state);
        return false;
    }
    const std::size_t n = state->candidates_.size();
    std::size_t &cursor = state->panelCursor_;
    if (sym == FcitxKey_Escape) {
        state->clear();
    } else if (sym == FcitxKey_BackSpace) {
        if (state->tool_ == WowtypeTool::Menu) {
            state->clear();
        } else {
            openTool(ic, state, WowtypeTool::Menu);
            return true;
        }
    } else if (key.isDigit() && key.digit() >= 1) {
        const std::size_t pick = cursor / kToolPageSize * kToolPageSize + key.digit() - 1;
        if (pick < n) {
            selectTool(ic, state, pick);
            return true;
        }
    } else if (sym == FcitxKey_space || sym == FcitxKey_Return || sym == FcitxKey_KP_Enter) {
        if (n == 0) {
            state->clear();
        } else {
            selectTool(ic, state, std::min(cursor, n - 1));
            return true;
        }
    } else if (n > 0 && (sym == FcitxKey_Down || sym == FcitxKey_Right)) {
        cursor = std::min(cursor + 1, n - 1);
    } else if (n > 0 && (sym == FcitxKey_Up || sym == FcitxKey_Left)) {
        cursor = cursor == 0 ? 0 : cursor - 1;
    } else if (n > 0 && (sym == FcitxKey_Page_Down || sym == FcitxKey_equal ||
                         sym == FcitxKey_period || sym == FcitxKey_bracketright)) {
        const std::size_t next = cursor / kToolPageSize * kToolPageSize + kToolPageSize;
        if (next < n) {
            cursor = next;
        }
    } else if (n > 0 && (sym == FcitxKey_Page_Up || sym == FcitxKey_minus ||
                         sym == FcitxKey_comma || sym == FcitxKey_bracketleft)) {
        const std::size_t page = cursor / kToolPageSize * kToolPageSize;
        cursor = page >= kToolPageSize ? page - kToolPageSize : 0;
    }
    // 其他键吃掉，免得打进应用
    updateInputPanel(ic, state);
    return true;
}

bool WowtypeEngine::handleEmojiPanelKey(fcitx::InputContext *ic, WowtypeState *state,
                                        const fcitx::Key &key) {
    const auto sym = key.sym();
    if (key.states().test(fcitx::KeyState::Ctrl) || key.states().test(fcitx::KeyState::Alt) ||
        key.states().test(fcitx::KeyState::Super)) {
        // 别的组合键（复制粘贴等）：收起面板，交给应用
        closeEmojiPanel(ic, state);
        return false;
    }
    if (sym == FcitxKey_Escape) {
        closeEmojiPanel(ic, state);
        return true;
    }
    if (sym == FcitxKey_BackSpace) {
        if (state->buffer_.empty()) {
            closeEmojiPanel(ic, state);
            return true;
        }
        state->buffer_.pop_back();
    } else if ((sym >= FcitxKey_a && sym <= FcitxKey_z) ||
               (sym >= FcitxKey_A && sym <= FcitxKey_Z)) {
        state->buffer_.push_back(static_cast<char>(sym | 0x20));
    } else if (sym == FcitxKey_Return || sym == FcitxKey_KP_Enter || sym == FcitxKey_space) {
        if (state->candidates_.empty()) {
            closeEmojiPanel(ic, state);
        } else {
            commitEmoji(ic, state, std::min(state->gridCursor_, state->candidates_.size() - 1));
        }
        return true;
    } else if (sym == FcitxKey_Up && state->gridCursor_ < kGridCols) {
        return true; // 第一行再往上：不收起
    } else if (!state->candidates_.empty() &&
               (key.isDigit() || key.isCursorMove() || sym == FcitxKey_minus ||
                sym == FcitxKey_equal)) {
        handleGridKey(ic, state, key);
        return true;
    } else {
        return true; // 其他键吃掉，免得打进应用
    }
    refreshEmojiPanel(state);
    updateInputPanel(ic, state);
    return true;
}

void WowtypeEngine::commitEmoji(fcitx::InputContext *ic, WowtypeState *state,
                                std::size_t index) {
    if (!ic || index >= state->candidates_.size()) {
        return;
    }
    const WowtypeCandidate chosen = state->candidates_[index];
    const std::string text = state->selectedText() + chosen.commit;
    if (!text.empty()) {
        emit(ic, text);
        rememberContext(text);
    }
    if (!state->symbolPanel_) {
        rememberEmoji(chosen.emojiText);
    }
    state->clear();
    updateInputPanel(ic, state);
}

/// 还没选词的拼音，按第一个用完它的候选分好音节（hengxiang -> heng'xiang）。
/// 显示的还是用户打的字母；英文、双拼等切不了的原样显示。
std::string WowtypeEngine::segmentedRemaining(WowtypeState *state) const {
    const std::string input = state->remaining();
    if (shuangpin_ && core_) {
        // 双拼显示成全拼（vsgo -> zhong'guo），和微信输入法一样
        if (const char *shown = wowtype_engine_shuangpin_display(core_, input.c_str());
            shown && *shown) {
            return shown;
        }
        return input;
    }
    for (const auto &candidate : state->candidates_) {
        if (candidate.consumed >= input.size()) {
            if (const char *shown =
                    wowtype_segment_input(input.c_str(), candidate.pinyin.c_str())) {
                return shown;
            }
            break;
        }
    }
    return input;
}

bool WowtypeEngine::inlinePreedit(fcitx::InputContext *ic) const {
    return instance_->globalConfig().preeditEnabledByDefault() &&
           ic->capabilityFlags().test(fcitx::CapabilityFlag::Preedit);
}

void WowtypeEngine::sendPreedit(fcitx::InputContext *ic,
                                const fcitx::Text &preedit) {
    auto &panel = ic->inputPanel();
    if (inlinePreedit(ic)) {
        panel.setClientPreedit(preedit);
    } else {
        panel.setPreedit(preedit);
    }
}

void WowtypeEngine::updateInputPanel(fcitx::InputContext *ic,
                                     WowtypeState *state) {
    auto &panel = ic->inputPanel();
    panel.reset();

    if (state->emojiPanel_) {
        fcitx::Text preedit;
        preedit.append(state->buffer_, fcitx::TextFormatFlag::Underline);
        preedit.setCursor(static_cast<int>(preedit.textLength()));
        sendPreedit(ic, preedit);
        std::string aux = state->symbolPanel_ ? "符号" : "表情";
        if (state->buffer_.empty()) {
            aux += "：打拼音或英文搜索，Esc 关闭";
        } else if (state->candidates_.empty()) {
            aux += "：没找到「" + state->buffer_ + "」";
        } else {
            aux += "：" + state->buffer_;
        }
        panel.setAuxUp(fcitx::Text(aux));
        if (!state->candidates_.empty()) {
            fillGridPanel(panel, state);
        }
        ic->updatePreedit();
        ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
        return;
    }

    if (state->tool_ != WowtypeTool::None) {
        sendPreedit(ic, fcitx::Text());
        fillToolPanel(panel, state);
        ic->updatePreedit();
        ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
        return;
    }

    const bool translate = translating(ic) && translator_;
    if (!state->composing()) {
        if (translate && !state->tsource_.empty()) {
            fillTranslateView(ic, state, panel);
        }
        ic->updatePreedit();
        ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
        return;
    }

    if (translate) {
        // 原文和拼音在候选框里，输入框里是译文
        fillTranslateView(ic, state, panel);
    } else {
        // 编辑区：已选的词 + 还没选的拼音（带下划线）
        fcitx::Text preedit;
        preedit.append(state->selectedText());
        preedit.append(segmentedRemaining(state), fcitx::TextFormatFlag::Underline);
        preedit.setCursor(static_cast<int>(preedit.textLength()));
        sendPreedit(ic, preedit);
    }

    if (state->expanded_ && !state->candidates_.empty()) {
        fillGridPanel(panel, state);
    } else if (!state->candidates_.empty()) {
        auto candidates = std::make_unique<fcitx::CommonCandidateList>();
        candidates->setLayoutHint(horizontal_
                                      ? fcitx::CandidateLayoutHint::Horizontal
                                      : fcitx::CandidateLayoutHint::Vertical);
        candidates->setPageSize(static_cast<int>(pageSize_));
        candidates->setSelectionKey(fcitx::KeyList{
            fcitx::Key(FcitxKey_1), fcitx::Key(FcitxKey_2), fcitx::Key(FcitxKey_3),
            fcitx::Key(FcitxKey_4), fcitx::Key(FcitxKey_5), fcitx::Key(FcitxKey_6),
            fcitx::Key(FcitxKey_7), fcitx::Key(FcitxKey_8), fcitx::Key(FcitxKey_9)});
        candidates->setCursorPositionAfterPaging(
            fcitx::CursorPositionAfterPaging::ResetToFirst);
        for (std::size_t i = 0; i < state->candidates_.size(); ++i) {
            candidates->append<WowtypeCandidateWord>(this, state, i,
                                                    state->candidates_[i].text);
        }
        candidates->setGlobalCursorIndex(static_cast<int>(
            std::min(state->panelCursor_, state->candidates_.size() - 1)));
        panel.setCandidateList(std::move(candidates));
    }

    ic->updatePreedit();
    ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
}

/// 展开的候选面板：竖排列表的每一项是一行（kGridCols 个词），一屏 kGridRows 行。
///
/// 照微信输入法的样子：光标所在行标 １–６，光标处的词用〔〕框起来；同一屏里各列
/// 按最宽的词补齐，这样上下键在同一列里走。classic UI 和 kimpanel 都只会画一行或
/// 一列，画不了真正的网格，所以用全角字符拼出来。
void WowtypeEngine::fillGridPanel(fcitx::InputPanel &panel, WowtypeState *state) {
    static const char *kLabels[] = {"\uFF11", "\uFF12", "\uFF13",
                                    "\uFF14", "\uFF15", "\uFF16"};
    static_assert(sizeof(kLabels) / sizeof(kLabels[0]) == kGridCols);
    const auto &all = state->candidates_;
    const std::size_t n = all.size();
    state->gridCursor_ = std::min(state->gridCursor_, n - 1);
    const std::size_t rows = (n + kGridCols - 1) / kGridCols;
    const std::size_t cursorRow = state->gridCursor_ / kGridCols;

    auto list = std::make_unique<fcitx::CommonCandidateList>();
    list->setLayoutHint(fcitx::CandidateLayoutHint::Vertical);
    list->setPageSize(static_cast<int>(kGridRows));
    list->setSelectionKey(fcitx::KeyList{}); // 不要行号：编号画在行里
    for (std::size_t pageStart = 0; pageStart < rows; pageStart += kGridRows) {
        const std::size_t pageEnd = std::min(rows, pageStart + kGridRows);
        std::size_t widths[kGridCols] = {};
        for (std::size_t r = pageStart; r < pageEnd; ++r) {
            for (std::size_t c = 0; c < kGridCols && r * kGridCols + c < n; ++c) {
                widths[c] = std::max(widths[c], displayWidth(shownText(all[r * kGridCols + c].text)));
            }
        }
        for (std::size_t r = pageStart; r < pageEnd; ++r) {
            std::string line;
            for (std::size_t c = 0; c < kGridCols && r * kGridCols + c < n; ++c) {
                const std::size_t index = r * kGridCols + c;
                const bool here = index == state->gridCursor_;
                line += r == cursorRow ? kLabels[c] : "\u3000";
                line += here ? "\u3014" : "\u3000";
                line += shownText(all[index].text);
                if (here) {
                    line += "\u3015";
                    padTo(line, displayWidth(shownText(all[index].text)), widths[c]);
                } else {
                    padTo(line, displayWidth(shownText(all[index].text)), widths[c]);
                    line += "\u3000";
                }
            }
            list->append<WowtypeGridRow>(this, state, r, line);
        }
    }
    list->setGlobalCursorIndex(static_cast<int>(cursorRow));
    panel.setCandidateList(std::move(list));
}

bool WowtypeEngine::handleGridKey(fcitx::InputContext *ic, WowtypeState *state,
                                  const fcitx::Key &key) {
    const auto sym = key.sym();
    const std::size_t n = state->candidates_.size();
    if (n == 0) {
        state->expanded_ = false;
        return false;
    }
    std::size_t &cursor = state->gridCursor_;
    const std::size_t screen = kGridCols * kGridRows;
    auto collapse = [&]() {
        state->expanded_ = false;
        state->panelCursor_ = cursor;
        updateInputPanel(ic, state);
    };
    switch (sym) {
    case FcitxKey_Left:
        if (cursor > 0) {
            --cursor;
        }
        break;
    case FcitxKey_Right:
        if (cursor + 1 < n) {
            ++cursor;
        }
        break;
    case FcitxKey_Up:
        if (cursor < kGridCols) {
            collapse(); // 第一行再往上：收起
            return true;
        }
        cursor -= kGridCols;
        break;
    case FcitxKey_Down:
        if (cursor + kGridCols < n) {
            cursor += kGridCols;
        } else if (cursor / kGridCols + 1 < (n + kGridCols - 1) / kGridCols) {
            cursor = n - 1; // 最后一行不满时落到最后一个
        }
        break;
    case FcitxKey_Page_Down:
    case FcitxKey_equal:
        cursor = std::min(n - 1, cursor + screen);
        break;
    case FcitxKey_Page_Up:
    case FcitxKey_minus:
        cursor = cursor >= screen ? cursor - screen : cursor % kGridCols;
        break;
    case FcitxKey_Escape:
        collapse();
        return true;
    case FcitxKey_space:
        commitCandidate(ic, state, cursor);
        return true;
    default:
        if (key.isDigit()) {
            const int digit = key.digit();
            const std::size_t index = cursor / kGridCols * kGridCols + digit - 1;
            if (digit >= 1 && digit <= static_cast<int>(kGridCols) && index < n) {
                commitCandidate(ic, state, index);
            }
            return true;
        }
        // 打字、退格、回车、标点：先收起，再照常处理
        collapse();
        return false;
    }
    updateInputPanel(ic, state);
    return true;
}

void WowtypeEngine::selectGridRow(fcitx::InputContext *ic, WowtypeState *state,
                                  std::size_t row) {
    if (!state || state->candidates_.empty()) {
        return;
    }
    const std::size_t index = state->gridCursor_ / kGridCols == row
                                  ? state->gridCursor_
                                  : row * kGridCols;
    commitCandidate(ic, state, std::min(index, state->candidates_.size() - 1));
}

void WowtypeEngine::commitCandidate(fcitx::InputContext *ic,
                                    WowtypeState *state, std::size_t index) {
    if (!ic || !state || index >= state->candidates_.size()) {
        return;
    }
    if (state->candidates_[index].emoji) {
        commitEmoji(ic, state, index);
        return;
    }
    if (state->candidates_[index].plain &&
        state->candidates_[index].consumed >= state->remaining().size()) {
        commitPlainCandidate(ic, state, index);
        return;
    }
    const WowtypeCandidate chosen = state->candidates_[index];
    const std::string input = state->remaining();
    if (chosen.consumed < input.size()) {
        // 句首词：先放进已选栈，剩下的拼音继续选
        state->selections_.push_back({chosen.text, chosen.pinyin, chosen.consumed});
        if (core_) {
            wowtype_engine_record_selection_ex(
                core_, chosen.text.c_str(),
                chosen.pinyin.empty() ? nullptr : chosen.pinyin.c_str());
        }
        refreshCandidates(state);
    } else {
        commitAll(ic, state, chosen.text, chosen.pinyin);
    }
    updateInputPanel(ic, state);
}

void WowtypeEngine::commitCurrent(fcitx::InputContext *ic, WowtypeState *state) {
    if (auto list = ic->inputPanel().candidateList(); list && list->size() > 0) {
        const int cursor = list->cursorIndex();
        list->candidate(cursor >= 0 && cursor < list->size() ? cursor : 0).select(ic);
        return;
    }
    commitAll(ic, state, state->remaining(), {});
    updateInputPanel(ic, state);
}

void WowtypeEngine::keyEvent(const fcitx::InputMethodEntry & /*entry*/,
                             fcitx::KeyEvent &event) {
    auto *ic = event.inputContext();
    if (!ic) {
        return;
    }
    auto *state = ic->propertyFor(&factory_);
    const fcitx::Key key = event.key();
    const auto sym = key.sym();

    if (voice_ && handleVoiceKey(ic, state, event)) {
        return;
    }

    // 单按 Shift 切中英文（WowType 自己的英文模式）。fcitx 的「临时切换输入法」热键
    // （默认左 Shift）生效时 fcitx 会先把 Shift 吃掉，这里就收不到，两者不会重复切换。
    if (handleShiftToggle(ic, state, event)) {
        return;
    }
    if (event.isRelease()) {
        return;
    }

    // 记下光标前是不是数字（数字后的 . 是小数点）：这次按键自己没上屏东西时，
    // 原样交给应用的数字键算数字，其他键（退格、方向键……）就不知道了，当不是。
    struct DigitTracker {
        WowtypeState *state;
        unsigned emits;
        bool digit;
        bool modifier;
        ~DigitTracker() {
            if (state->emits_ == emits && !modifier) {
                state->afterDigit_ = digit;
            }
        }
    } digitTracker{state, state->emits_,
                   key.isDigit() && !state->composing() &&
                       !key.states().testAny(fcitx::KeyStates{fcitx::KeyState::Ctrl,
                                                              fcitx::KeyState::Alt,
                                                              fcitx::KeyState::Super}),
                   key.isModifier()};

    if (isEmojiKey(key)) {
        if (state->emojiPanel_) {
            closeEmojiPanel(ic, state);
        } else {
            openEmojiPanel(ic, state);
        }
        event.filterAndAccept();
        return;
    }
    if (state->emojiPanel_) {
        if (handleEmojiPanelKey(ic, state, key)) {
            event.filterAndAccept();
        }
        return;
    }
    if (state->tool_ != WowtypeTool::None) {
        if (handleToolKey(ic, state, key)) {
            event.filterAndAccept();
        }
        return;
    }

    // 互译模式、没在打拼音：回车上屏译文、上下键选译法、数字进原文……
    if (translating(ic) && !state->composing() && handleTranslateKey(ic, state, key)) {
        event.filterAndAccept();
        return;
    }

    // 英文模式：按键原样交给应用（字母、半角标点都直接上屏）
    if (asciiMode_ && !state->composing()) {
        if (autoSpaceKey(ic, key)) {
            event.filterAndAccept();
        }
        return;
    }

    // 带 Ctrl/Alt/Super 的组合键交给应用或 fcitx 的其他处理器。
    if (key.states().test(fcitx::KeyState::Ctrl) ||
        key.states().test(fcitx::KeyState::Alt) ||
        key.states().test(fcitx::KeyState::Super)) {
        return;
    }

    if (state->composing()) {
        if (state->expanded_ && handleGridKey(ic, state, key)) {
            event.filterAndAccept();
            return;
        }
        if (sym == FcitxKey_BackSpace) {
            if (!state->selections_.empty()) {
                // 选过词先撤销最后一次选词，拼音回到编辑区（后面还没选的拼音不动），
                // 和微信输入法一样；没有选词了才删字母
                state->selections_.pop_back();
            } else {
                popUtf8(state->buffer_);
            }
            if (state->buffer_.empty()) {
                state->clear();
            }
            refreshCandidates(state);
            updateInputPanel(ic, state);
            event.filterAndAccept();
            return;
        }
        if (sym == FcitxKey_Escape) {
            state->clear();
            updateInputPanel(ic, state);
            event.filterAndAccept();
            return;
        }
        if (sym == FcitxKey_space) {
            // 只打了一个 v 再按空格：打开工具栏（vim、vscode 这些照常打字）
            if (toolbar_ && !shuangpin_ && state->buffer_ == "v" && state->selections_.empty()) {
                openTool(ic, state, WowtypeTool::Menu);
                event.filterAndAccept();
                return;
            }
            commitCurrent(ic, state);
            event.filterAndAccept();
            return;
        }
        if (sym == FcitxKey_Return || sym == FcitxKey_KP_Enter) {
            // 回车：已选的词 + 原始字母上屏
            commitAll(ic, state, state->remaining(), {});
            updateInputPanel(ic, state);
            event.filterAndAccept();
            return;
        }
        if (calculator_ && !shuangpin_) {
            // V 模式：v 后面的数字、运算符进编辑区（不选词、不翻页、不当标点）
            if (sym == FcitxKey_equal && calcActive(state) && state->buffer_.size() > 1) {
                // = 上屏计算结果（第一个候选）
                commitCurrent(ic, state);
                event.filterAndAccept();
                return;
            }
            if (const char c = calcChar(key); c != 0 && calcActive(state)) {
                state->buffer_.push_back(c);
                refreshCandidates(state);
                updateInputPanel(ic, state);
                event.filterAndAccept();
                return;
            }
        }
        if (const int nth = selectKeyIndex(sym); nth > 0) {
            // 分号选第 2 个、引号选第 3 个（设置里打开时）；没这么多候选就什么都不做
            if (auto list = ic->inputPanel().candidateList(); list && nth <= list->size()) {
                list->candidate(nth - 1).select(ic);
            }
            event.filterAndAccept();
            return;
        }
        if (key.isDigit()) {
            // 数字按当前页选词
            const int digit = key.digit();
            if (auto list = ic->inputPanel().candidateList(); list && digit >= 1 &&
                                                              digit <= list->size()) {
                list->candidate(digit - 1).select(ic);
            }
            event.filterAndAccept();
            return;
        }

        // 微软、搜狗、紫光双拼用分号当 ing：等第二个键时分号进编辑区，不当标点
        if (sym == FcitxKey_semicolon && semicolonIsKey(state)) {
            state->buffer_.push_back(';');
            refreshCandidates(state);
            updateInputPanel(ic, state);
            event.filterAndAccept();
            return;
        }

        // fcitx5 全局设置里的翻页、移动候选热键（[Hotkey/PrevPage] 等，比如 , . 翻页）。
        // 按了就算翻不动也吃掉，不让它变成标点把字上屏。方向键（fcitx 默认上下翻页）
        // 照横排/竖排走下面自己的规则（横排下键展开候选面板）。
        const bool arrow = sym == FcitxKey_Up || sym == FcitxKey_Down ||
                           sym == FcitxKey_Left || sym == FcitxKey_Right;
        if (auto list = ic->inputPanel().candidateList();
            !arrow && list && list->size() > 0) {
            const auto &global = instance_->globalConfig();
            auto *pageable = list->toPageable();
            auto *movable = list->toCursorMovable();
            bool matched = true;
            if (key.checkKeyList(global.defaultPrevPage())) {
                if (pageable && pageable->hasPrev()) {
                    pageable->prev();
                }
            } else if (key.checkKeyList(global.defaultNextPage())) {
                if (pageable && pageable->hasNext()) {
                    pageable->next();
                }
            } else if (key.checkKeyList(global.defaultPrevCandidate())) {
                if (movable) {
                    movable->prevCandidate();
                }
            } else if (key.checkKeyList(global.defaultNextCandidate())) {
                if (movable) {
                    movable->nextCandidate();
                }
            } else {
                matched = false;
            }
            if (matched) {
                event.filterAndAccept();
                ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
                return;
            }
        }

        // 候选翻页/移动。fcitx5 的 CandidateList 没有 keyEvent，
        // 引擎需要自己把按键映射到 prev/next/prevCandidate/nextCandidate。
        if (auto list = ic->inputPanel().candidateList(); list && list->size() > 0) {
            auto *pageable = list->toPageable();
            auto *movable = list->toCursorMovable();
            // 横排时左右键移动候选、上下键翻页；竖排反过来
            const bool horizontal = horizontal_;
            const auto prevKey = horizontal ? FcitxKey_Left : FcitxKey_Up;
            const auto nextKey = horizontal ? FcitxKey_Right : FcitxKey_Down;
            const auto prevPageKey = horizontal ? FcitxKey_Up : FcitxKey_Left;
            const auto nextPageKey = horizontal ? FcitxKey_Down : FcitxKey_Right;
            bool handled = false;
            if (horizontal && sym == FcitxKey_Down && state->candidates_.size() > 1) {
                // 横排时下键展开候选面板（照微信输入法），光标停在当前选中的词上
                int cursor = list->cursorIndex();
                if (auto *common = dynamic_cast<fcitx::CommonCandidateList *>(list.get())) {
                    cursor = common->globalCursorIndex();
                }
                state->expanded_ = true;
                state->gridCursor_ = cursor > 0 ? static_cast<std::size_t>(cursor) : 0;
                updateInputPanel(ic, state);
                event.filterAndAccept();
                return;
            }
            if (movable && sym == prevKey) {
                movable->prevCandidate();
                handled = true;
            } else if (movable && sym == nextKey) {
                movable->nextCandidate();
                handled = true;
            } else if (pageable) {
                // 设置里能选的翻页键（- =、[ ]、, .、Shift+Tab Tab）
                const bool shift = key.states().test(fcitx::KeyState::Shift);
                const bool tabPrev =
                    pageTab_ && (sym == FcitxKey_ISO_Left_Tab || (sym == FcitxKey_Tab && shift));
                const bool tabNext = pageTab_ && sym == FcitxKey_Tab && !shift;
                const bool charPrev = (pageMinus_ && sym == FcitxKey_minus) ||
                                      (pageBracket_ && sym == FcitxKey_bracketleft) ||
                                      (pageComma_ && sym == FcitxKey_comma) || tabPrev;
                const bool charNext = (pageMinus_ && sym == FcitxKey_equal) ||
                                      (pageBracket_ && sym == FcitxKey_bracketright) ||
                                      (pageComma_ && sym == FcitxKey_period) || tabNext;
                if ((sym == FcitxKey_Page_Up || sym == prevPageKey || charPrev) &&
                    pageable->hasPrev()) {
                    pageable->prev();
                    handled = true;
                } else if ((sym == FcitxKey_Page_Down || sym == nextPageKey || charNext) &&
                           pageable->hasNext()) {
                    pageable->next();
                    handled = true;
                } else if ((charPrev || charNext) && (pageable->hasPrev() || pageable->hasNext())) {
                    // 已经在第一页/最后一页：吃掉，不当标点上屏（只有一页时照常当标点）
                    handled = true;
                }
            }
            if (handled) {
                event.filterAndAccept();
                ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
                return;
            }
        }

        // 打字途中按标点：先上屏当前候选，再上屏标点（全角样式是中文标点）
        if (wowtype_fullwidth_punct(static_cast<int>(sym)) && sym != FcitxKey_apostrophe) {
            // 光标停在句首词上时，选完它还剩半句：接着选第一个候选，直到整句上屏
            for (int guard = 0; state->composing() && guard < 16; ++guard) {
                commitCurrent(ic, state);
            }
            std::string text = punctFor(ic, state, sym);
            if (text.empty()) {
                text.assign(1, static_cast<char>(sym));
            }
            commitPlain(ic, text);
            if (translating(ic)) {
                updateInputPanel(ic, state);
            }
            event.filterAndAccept();
            return;
        }

        // 其他可见字符（/ " + _ 等）：先上屏当前候选，再原样上屏这个字符
        if (sym > FcitxKey_space && sym < FcitxKey_asciitilde + 1 && sym != FcitxKey_apostrophe &&
            !((sym >= FcitxKey_a && sym <= FcitxKey_z) || (sym >= FcitxKey_A && sym <= FcitxKey_Z))) {
            const std::string text(1, static_cast<char>(sym));
            for (int guard = 0; state->composing() && guard < 16; ++guard) {
                commitCurrent(ic, state);
            }
            commitPlain(ic, text);
            if (translating(ic)) {
                updateInputPanel(ic, state);
            }
            event.filterAndAccept();
            return;
        }

        // 编辑区里光标没法移动，这些键吃掉，免得应用里的光标乱跑
        if (key.isCursorMove() || sym == FcitxKey_Tab || sym == FcitxKey_Delete) {
            event.filterAndAccept();
            return;
        }
    } else {
        // 汉字后面直接打数字（第5章）：要补空格就自己上屏，否则照常交给应用
        if (key.isDigit() && autoSpaceKey(ic, key)) {
            event.filterAndAccept();
            return;
        }
        // 没有正在输入的拼音时，把 ASCII 标点转成中文标点（映射表在 Rust 侧）。
        // 没收录的（/ " + 等）、半角样式、数字后的小数点不处理，原样交给应用。
        if (const std::string punct = punctFor(ic, state, sym); !punct.empty()) {
            commitPlain(ic, punct);
            if (translating(ic)) {
                updateInputPanel(ic, state);
            }
            event.filterAndAccept();
            return;
        }
    }

    char input = 0;
    if ((sym >= FcitxKey_a && sym <= FcitxKey_z) ||
        (sym >= FcitxKey_A && sym <= FcitxKey_Z)) {
        // 大写字母原样保留：Hello、iPhone 这类英文候选要用到
        input = static_cast<char>(sym);
    } else if (sym == FcitxKey_apostrophe && state->composing()) {
        // 隔音符（xi'an）；开头的隔音符没有意义
        input = '\'';
    }

    if (input != 0) {
        state->buffer_.push_back(input);
        refreshCandidates(state);
        updateInputPanel(ic, state);
        event.filterAndAccept();
    }
}

void WowtypeEngine::activate(const fcitx::InputMethodEntry & /*entry*/,
                             fcitx::InputContextEvent &event) {
    auto *ic = event.inputContext();
    if (!ic) {
        return;
    }
    auto *state = ic->propertyFor(&factory_);
    state->clear();
    clearTranslation(state);
    coreReady();
    sampleClipboard(ic);
    maybeCheckUpdate();
}

/// 后台的小事交给设置界面（wowtype-config --startup）：第一次用时打开 WowType 主题、
/// 检查更新（它自己看「自动检查更新」开关，限一天一次，有新版本时发桌面通知）。
/// 插件这边只是每次 fcitx5 运行里第一次切到 WowType 时叫它一下。
void WowtypeEngine::maybeCheckUpdate() {
#ifdef WOWTYPE_CONFIG_TOOL
    if (updateChecked_ || std::getenv("WOWTYPE_NO_UPDATE_CHECK")) {
        return;
    }
    updateChecked_ = true;
    std::error_code ec;
    if (std::filesystem::exists(WOWTYPE_CONFIG_TOOL, ec)) {
        fcitx::startProcess({WOWTYPE_CONFIG_TOOL, "--startup"});
    }
#endif
}

void WowtypeEngine::deactivate(const fcitx::InputMethodEntry &entry,
                               fcitx::InputContextEvent &event) {
    // 打到一半切换输入法（比如按 Shift 切英文）：已选的词 + 原始字母原样上屏，
    // 不要把用户打的东西吞掉。失去焦点时不上屏，免得送进别的窗口。
    if (auto *ic = event.inputContext();
        ic && event.type() == fcitx::EventType::InputContextSwitchInputMethod) {
        auto *state = ic->propertyFor(&factory_);
        if (state->composing()) {
            commitAll(ic, state, state->remaining(), {});
        }
        // 互译攒着的原文也原样上屏
        if (!state->tsource_.empty()) {
            commitTranslateSource(ic, state);
        }
    }
    if (voiceActive() && voiceIc_.get() == event.inputContext()) {
        cancelVoice();
    }
    reset(entry, event);
    maybeSaveUserDict(true);
}

void WowtypeEngine::reset(const fcitx::InputMethodEntry & /*entry*/,
                          fcitx::InputContextEvent &event) {
    auto *ic = event.inputContext();
    if (!ic) {
        return;
    }
    // 原文和拼音一样只在输入法里：应用重置输入框（点了别处、失去焦点）就丢掉。
    // 有的应用重置时会自己把预编辑的字上屏，留着会重复。
    auto *state = ic->propertyFor(&factory_);
    state->clear();
    clearTranslation(state);
    ic->inputPanel().reset();
    ic->updatePreedit();
    ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
}

std::string WowtypeEngine::subMode(const fcitx::InputMethodEntry & /*entry*/,
                                   fcitx::InputContext & /*ic*/) {
    return translateMode_ ? "互译" : asciiMode_ ? "英文" : "";
}

std::string WowtypeEngine::subModeLabelImpl(const fcitx::InputMethodEntry & /*entry*/,
                                            fcitx::InputContext & /*ic*/) {
    return translateMode_ ? "译" : asciiMode_ ? "英" : "";
}

int WowtypeEngine::selectKeyIndex(fcitx::KeySym sym) const {
    if (selectKeys_ == WowtypeSelectKeys::Off) {
        return 0;
    }
    if (sym == FcitxKey_semicolon) {
        // 微软、搜狗、紫光双拼里分号是 ing 键，不能拿来选词
        return shuangpin_ && shuangpinSemicolon_ ? 0 : 2;
    }
    if (sym == FcitxKey_apostrophe && selectKeys_ == WowtypeSelectKeys::SemicolonQuote) {
        return 3;
    }
    return 0;
}

bool WowtypeEngine::calcActive(WowtypeState *state) const {
    if (!calculator_ || shuangpin_ || !state->selections_.empty()) {
        return false;
    }
    const std::string &buffer = state->buffer_;
    if (buffer.empty() || buffer[0] != 'v') {
        return false;
    }
    for (std::size_t i = 1; i < buffer.size(); ++i) {
        const char c = buffer[i];
        if (!((c >= '0' && c <= '9') || std::string_view("+-*/%^.()").find(c) !=
                                            std::string_view::npos)) {
            return false;
        }
    }
    return true;
}

bool WowtypeEngine::semicolonIsKey(WowtypeState *state) const {
    if (!shuangpin_ || !shuangpinSemicolon_ || !state->composing()) {
        return false;
    }
    std::size_t keys = 0;
    for (const char c : state->remaining()) {
        if (c != '\'') {
            ++keys;
        }
    }
    return keys % 2 == 1;
}

/// 按下 Shift 记下来，松开时中间没按别的键（也没按太久）就切中英文。
std::string WowtypeEngine::punctFor(fcitx::InputContext *ic, WowtypeState *state,
                                    unsigned sym) const {
    int prev = state->afterDigit_ ? '0' : 0;
    // 没在打拼音时，应用报告了周围文字就以它为准（鼠标挪过光标也对）
    if (!state->composing() &&
        ic->capabilityFlags().test(fcitx::CapabilityFlag::SurroundingText) &&
        ic->surroundingText().isValid()) {
        const auto &surrounding = ic->surroundingText();
        const std::string &text = surrounding.text();
        const unsigned cursor = surrounding.cursor();
        // cursor 按字符数算：找到光标前那个字符的首字节。只关心它是不是 ASCII 数字，
        // 非 ASCII 字符一律当成「不是数字」。
        prev = 0;
        unsigned chars = 0;
        std::size_t last = std::string::npos;
        for (std::size_t i = 0; i < text.size() && chars < cursor; ++i) {
            if ((static_cast<unsigned char>(text[i]) & 0xC0) != 0x80) {
                last = i;
                ++chars;
            }
        }
        if (chars == cursor && last != std::string::npos) {
            const auto byte = static_cast<unsigned char>(text[last]);
            prev = byte < 0x80 ? byte : 0x4E00;
        }
    }
    const char *punct = wowtype_punct(static_cast<int>(sym),
                                      punctStyle_ == WowtypePunctStyle::Halfwidth ? 1 : 0, prev);
    return punct ? punct : std::string();
}

bool WowtypeEngine::handleShiftToggle(fcitx::InputContext *ic, WowtypeState *state,
                                      fcitx::KeyEvent &event) {
    const auto sym = event.key().sym();
    const bool isShift = sym == FcitxKey_Shift_L || sym == FcitxKey_Shift_R;
    const bool wanted =
        isShift && (shiftToggle_ == WowtypeShiftToggle::Both ||
                    (shiftToggle_ == WowtypeShiftToggle::Left && sym == FcitxKey_Shift_L) ||
                    (shiftToggle_ == WowtypeShiftToggle::Right && sym == FcitxKey_Shift_R));
    if (!event.isRelease()) {
        const auto states = event.key().states();
        const bool otherModifier = states.test(fcitx::KeyState::Ctrl) ||
                                   states.test(fcitx::KeyState::Alt) ||
                                   states.test(fcitx::KeyState::Super);
        if (wanted && !otherModifier && !state->emojiPanel_ &&
            state->tool_ == WowtypeTool::None) {
            shiftDown_ = sym;
            shiftDownAt_ = fcitx::now(CLOCK_MONOTONIC);
        } else {
            shiftDown_ = FcitxKey_None;
        }
        return false;
    }
    if (!wanted || sym != shiftDown_) {
        if (!isShift) {
            shiftDown_ = FcitxKey_None;
        }
        return false;
    }
    shiftDown_ = FcitxKey_None;
    // 按住 Shift 超过 0.5 秒多半是想打大写或者犹豫了，不切
    if (fcitx::now(CLOCK_MONOTONIC) - shiftDownAt_ > 500000) {
        return false;
    }
    toggleAsciiMode(ic, state);
    event.filterAndAccept();
    return true;
}

void WowtypeEngine::toggleAsciiMode(fcitx::InputContext *ic, WowtypeState *state) {
    if (translateMode_) {
        // 译 → 中：攒着的原文原样上屏，正在打的拼音留着接着打
        if (!state->tsource_.empty()) {
            const std::string source = state->tsource_;
            clearTranslation(state);
            ic->commitString(source);
        }
        translateMode_ = false;
        updateInputPanel(ic, state);
    } else if (asciiMode_) {
        // 英 → 译（配置了翻译服务才有这一档）或 → 中
        asciiMode_ = false;
        translateMode_ = translateAvailable();
    } else {
        asciiMode_ = true;
        if (state->composing()) {
            // 打到一半切英文：已选的词 + 打的字母原样上屏（和微信输入法一样）
            commitAll(ic, state, state->remaining(), {});
            state->clear();
            updateInputPanel(ic, state);
        }
    }
    const char *name = translateMode_ ? "互译" : asciiMode_ ? "英文" : "中文";
    WLOG_I() << "WowType: 切到" << name;
#ifdef WOWTYPE_HAVE_CUSTOM_IM_INFO
    std::string label = translateMode_ ? "译" : asciiMode_ ? "英" : "中";
    if (translateMode_ && translator_) {
        label += " ";
        label += wowtype_translate_tag(translator_, "");
    }
    instance_->showCustomInputMethodInformation(ic, label);
#else
    instance_->showInputMethodInformation(ic);
#endif
    ic->updateUserInterface(fcitx::UserInterfaceComponent::StatusArea);
}

bool WowtypeEngine::handleVoiceKey(fcitx::InputContext *ic, WowtypeState *state,
                                   fcitx::KeyEvent &event) {
    const fcitx::Key key = event.key();
    if (isVoiceKey(key)) {
        if (event.isRelease()) {
            if (!voiceKeyDown_) {
                return false;
            }
            voiceKeyDown_ = false;
            event.filterAndAccept();
            if (voiceActive()) {
                wowtype_voice_key_up(voice_);
                pollVoice();
            }
            return true;
        }
        if (voiceKeyDown_) {
            // 按住时的自动重复
            event.filterAndAccept();
            return true;
        }
        // 正在打拼音时不抢这个键
        if (state->composing() && !voiceActive()) {
            return false;
        }
        voiceKeyDown_ = true;
        event.filterAndAccept();
        if (!voiceActive()) {
            voiceIc_ = ic->watch();
            voiceShowing_ = true;
            voiceErrorUntil_ = 0;
        }
        wowtype_voice_key_down(voice_);
        pollVoice();
        if (!voiceTimer_) {
            voiceTimer_ = instance_->eventLoop().addTimeEvent(
                CLOCK_MONOTONIC, fcitx::now(CLOCK_MONOTONIC) + kVoicePollUsec, kTimerAccuracyUsec,
                [this](fcitx::EventSourceTime *source, uint64_t) {
                    if (pollVoice()) {
                        source->setNextInterval(kVoicePollUsec);
                        source->setOneShot();
                    }
                    return true;
                });
        } else {
            voiceTimer_->setNextInterval(kVoicePollUsec);
            voiceTimer_->setOneShot();
        }
        return true;
    }

    if (!voiceActive() || event.isRelease()) {
        return false;
    }
    if (key.sym() == FcitxKey_Escape) {
        cancelVoice();
        event.filterAndAccept();
        return true;
    }
    // 修饰键单独按下（比如按住热键时碰到 Shift）不打断
    if (key.isModifier()) {
        return false;
    }
    // 说话途中打别的键：不要这次的语音，键照常处理
    cancelVoice();
    return false;
}

bool WowtypeEngine::pollVoice() {
    if (!voice_ || !voiceShowing_) {
        return false;
    }
    auto *ic = voiceIc_.get();
    if (!ic) {
        // 输入框没了
        cancelVoice();
        return false;
    }
    const int phase = wowtype_voice_poll(voice_);
    const std::string text = wowtype_voice_text(voice_);
    switch (phase) {
    case WOWTYPE_VOICE_LISTENING: {
        const int level = wowtype_voice_level(voice_);
        const bool downloading =
            wowtype_voice_model_state(voice_) == WOWTYPE_VOICE_MODEL_DOWNLOADING;
        if (voiceOverlay()) {
            // 浮条由 GNOME 扩展画，这里只留编辑区里识别到一半的字
            showVoice(ic, {}, text);
            sendVoiceOverlay(ic, kOverlayListening, downloading ? "下载语音模型…" : "正在听…",
                             level);
            return true;
        }
        // 不写字，只画麦克风 + 跟着音量滚动的波形；第一次下载模型要很久，才写一句
        voiceLevels_.push_back(level);
        if (voiceLevels_.size() > kVoiceBars) {
            voiceLevels_.erase(voiceLevels_.begin());
        }
        std::string status = "🎙 " + voiceWave(voiceLevels_);
        if (downloading) {
            status += " 下载语音模型…";
        }
        showVoice(ic, status + " ", text);
        return true;
    }
    case WOWTYPE_VOICE_RECOGNIZING: {
        if (voiceOverlay()) {
            showVoice(ic, {}, text);
            sendVoiceOverlay(ic, kOverlayRecognizing, "识别中…", 0);
            return true;
        }
        static const char *const kDots[] = {"·    ", "··   ", "···  ", "···· ", "·····"};
        showVoice(ic, std::string("🎙 ") + kDots[(voiceFrame_++ / 3) % 5] + " ", text);
        return true;
    }
    case WOWTYPE_VOICE_RESULT:
        clearVoice(true);
        commitPlain(ic, text);
        // 上屏以后再复制，复制不成也不影响上屏；密码框里说的话不进剪贴板
        if (voiceCopy_ && !ic->capabilityFlags().testAny(fcitx::CapabilityFlag::PasswordOrSensitive) &&
            !wowtype::copyToClipboard(text)) {
            WLOG_I() << "WowType: 没能复制到剪贴板（要装 wl-clipboard，X11 下装 xclip 或 xsel）";
        }
        if (translating(ic)) {
            // 互译模式：说的话进了原文
            updateInputPanel(ic, ic->propertyFor(&factory_));
        }
        return false;
    case WOWTYPE_VOICE_ERROR:
        WLOG_I() << "WowType: 语音 " << text;
        if (voiceOverlay()) {
            showVoice(ic, {}, {});
            sendVoiceOverlay(ic, kOverlayError, text, 0);
        } else {
            showVoice(ic, "🎙 " + text, {});
        }
        voiceErrorUntil_ = fcitx::now(CLOCK_MONOTONIC) + kVoiceErrorUsec;
        return true;
    default:
        if (voiceErrorUntil_ && fcitx::now(CLOCK_MONOTONIC) < voiceErrorUntil_) {
            return true;
        }
        clearVoice();
        return false;
    }
}

void WowtypeEngine::showVoice(fcitx::InputContext *ic, const std::string &status,
                              const std::string &partial) {
    auto &panel = ic->inputPanel();
    panel.reset();
    if (translating(ic)) {
        // 互译模式：说的话接在原文框里攒着的原文后面，输入框里留着译文
        auto *state = ic->propertyFor(&factory_);
        fcitx::Text box;
        box.append(state->tsource_);
        box.append(partial, fcitx::TextFormatFlag::Underline);
        box.setCursor(static_cast<int>(box.textLength()));
        panel.setPreedit(box);
        if (inlinePreedit(ic) && !state->tshown_.empty()) {
            fcitx::Text shown;
            shown.append(state->tshown_, fcitx::TextFormatFlag::Underline);
            shown.setCursor(static_cast<int>(shown.textLength()));
            panel.setClientPreedit(shown);
        }
    } else if (!partial.empty()) {
        fcitx::Text preedit;
        preedit.append(partial, fcitx::TextFormatFlag::Underline);
        preedit.setCursor(static_cast<int>(preedit.textLength()));
        sendPreedit(ic, preedit);
    }
    if (!status.empty()) {
        panel.setAuxUp(fcitx::Text(status));
    }
    ic->updatePreedit();
    ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
}

void WowtypeEngine::clearVoice(bool done) {
    if (voiceShowing_ && voiceOverlay()) {
        sendVoiceOverlay(voiceIc_.get(), done ? kOverlayDone : kOverlayHide,
                         done ? "识别完成" : "", 0);
    }
    voiceShowing_ = false;
    voiceLevels_.clear();
    voiceFrame_ = 0;
    voiceErrorUntil_ = 0;
    if (auto *ic = voiceIc_.get()) {
        // 回到说话前的样子（互译模式下还有原文和译文）
        updateInputPanel(ic, ic->propertyFor(&factory_));
    }
    voiceIc_.unwatch();
}

void WowtypeEngine::cancelVoice() {
    if (voice_) {
        wowtype_voice_cancel(voice_);
    }
    clearVoice();
}

// ---------------------------------------------------------------------------
// 互译模式
//
// 照微信输入法的样子：打的字（选好的词、标点、语音识别结果）都经 emit() 攒进
// state->tsource_，显示在候选框里（当原文框用），不交给应用；原文停下来 0.5 秒
// （句末标点立刻）就发请求，译文边出边写在应用的输入框里（编辑区，带下划线）。
// 回车 / 空格上屏译文，Shift+回车上屏原文，Esc 清空。

bool WowtypeEngine::translateAvailable() const {
    return translateEnabled_ && translator_ && wowtype_translate_ready(translator_) == 1;
}

bool WowtypeEngine::translating(fcitx::InputContext *ic) const {
    if (!translateMode_ || !ic || !translator_) {
        return false;
    }
    // 密码框之类：照常打中文，不往外发
    const auto flags = ic->capabilityFlags();
    return !flags.test(fcitx::CapabilityFlag::Password) &&
           !flags.test(fcitx::CapabilityFlag::Sensitive);
}

std::string WowtypeEngine::translateKeyFile() const {
    if (const char *env = std::getenv("WOWTYPE_TRANSLATE_KEY_FILE"); env && *env) {
        return env;
    }
    const std::string dir = userConfigDir();
    return dir.empty() ? std::string() : dir + "/translate.key";
}

void WowtypeEngine::emit(fcitx::InputContext *ic, const std::string &text) {
    if (!ic || text.empty()) {
        return;
    }
    auto *st = ic->propertyFor(&factory_);
    st->afterDigit_ = text.back() >= '0' && text.back() <= '9';
    ++st->emits_;
    if (!translating(ic)) {
        ic->commitString(needsAutoSpace(ic, text) ? " " + text : text);
        return;
    }
    auto *state = ic->propertyFor(&factory_);
    state->tsource_ += text;
    translateSourceChanged(ic, state, endsSentence(text));
}

bool WowtypeEngine::needsAutoSpace(fcitx::InputContext *ic, const std::string &next) const {
    if (!autoSpaceFlags_ || !ic || next.empty()) {
        return false;
    }
    // 读不到光标前的文字就不猜；密码框、网址、邮箱输入框不动
    const auto caps = ic->capabilityFlags();
    if (!caps.test(fcitx::CapabilityFlag::SurroundingText) ||
        caps.testAny(fcitx::CapabilityFlags{fcitx::CapabilityFlag::PasswordOrSensitive,
                                            fcitx::CapabilityFlag::Url,
                                            fcitx::CapabilityFlag::Email})) {
        return false;
    }
    const auto &surrounding = ic->surroundingText();
    if (!surrounding.isValid()) {
        return false;
    }
    // 光标位置按字算；选中了文字时看选区前面那个字
    const unsigned pos = std::min(surrounding.cursor(), surrounding.anchor());
    const std::string &before = surrounding.text();
    if (pos == 0 || pos > fcitx::utf8::length(before)) {
        return false;
    }
    const auto offset = fcitx::utf8::ncharByteLength(before.begin(), pos - 1);
    const uint32_t prev = fcitx::utf8::getChar(before.begin() + offset, before.end());
    const uint32_t first = fcitx::utf8::getChar(next.begin(), next.end());
    if (!fcitx::utf8::isValidChar(prev) || !fcitx::utf8::isValidChar(first)) {
        return false;
    }
    return wowtype_autospace(static_cast<int>(prev), static_cast<int>(first), autoSpaceFlags_) == 1;
}

bool WowtypeEngine::autoSpaceKey(fcitx::InputContext *ic, const fcitx::Key &key) {
    if (!autoSpaceFlags_ || key.states().testAny(fcitx::KeyStates{
                                fcitx::KeyState::Ctrl, fcitx::KeyState::Alt,
                                fcitx::KeyState::Super})) {
        return false;
    }
    const auto sym = key.sym();
    const bool letter = (sym >= FcitxKey_a && sym <= FcitxKey_z) ||
                        (sym >= FcitxKey_A && sym <= FcitxKey_Z);
    const bool digit = sym >= FcitxKey_0 && sym <= FcitxKey_9;
    if (!letter && !digit) {
        return false;
    }
    const std::string text(1, static_cast<char>(sym));
    if (!needsAutoSpace(ic, text)) {
        return false;
    }
    ic->commitString(" " + text);
    return true;
}

void WowtypeEngine::translateSourceChanged(fcitx::InputContext *ic, WowtypeState *state,
                                           bool now) {
    state->tpending_ = false;
    if (state->tsource_.empty()) {
        clearTranslation(state);
        return;
    }
    if (translateIc_.get() != ic) {
        translateIc_ = ic->watch();
    }
    translateAt_ = fcitx::now(CLOCK_MONOTONIC) + (now ? 0 : kTranslateDelayUsec);
    ensureTranslateTimer();
}

void WowtypeEngine::clearTranslation(WowtypeState *state) {
    state->tsource_.clear();
    state->tshown_.clear();
    state->tpending_ = false;
    auto *ic = translateIc_.get();
    if (ic && ic->propertyFor(&factory_) == state) {
        translateAt_ = 0;
        translateDrawn_.clear();
        if (translator_) {
            wowtype_translate_cancel(translator_);
        }
        translateIc_.unwatch();
    }
}

void WowtypeEngine::ensureTranslateTimer() {
    if (!translateTimer_) {
        translateTimer_ = instance_->eventLoop().addTimeEvent(
            CLOCK_MONOTONIC, fcitx::now(CLOCK_MONOTONIC) + kTranslatePollUsec, kTimerAccuracyUsec,
            [this](fcitx::EventSourceTime *source, uint64_t) {
                if (pollTranslate()) {
                    source->setNextInterval(kTranslatePollUsec);
                    source->setOneShot();
                }
                return true;
            });
    } else {
        translateTimer_->setNextInterval(kTranslatePollUsec);
        translateTimer_->setOneShot();
    }
}

bool WowtypeEngine::pollTranslate() {
    auto *ic = translateIc_.get();
    if (!ic || !translator_) {
        translateAt_ = 0;
        return false;
    }
    auto *state = ic->propertyFor(&factory_);
    if (state->tsource_.empty()) {
        translateAt_ = 0;
        wowtype_translate_cancel(translator_);
        return false;
    }
    if (translateAt_ && fcitx::now(CLOCK_MONOTONIC) >= translateAt_) {
        translateAt_ = 0;
        wowtype_translate_start(translator_, state->tsource_.c_str());
    }
    const int phase = wowtype_translate_poll(translator_);
    const bool fresh = state->tsource_ == wowtype_translate_source(translator_);
    if (fresh && phase == WOWTYPE_TRANSLATE_ERROR && state->tpending_) {
        state->tpending_ = false;
        WLOG_I() << "WowType: " << wowtype_translate_error(translator_);
    }
    if (state->tpending_ && fresh && phase == WOWTYPE_TRANSLATE_DONE) {
        // 按过回车：译好了，上屏
        commitTranslation(ic, state);
        return false;
    }

    // 结果变了才重画（现在画的是什么由 fillTranslateView 记在 translateDrawn_ 里）。
    // 只换编辑区和提示行：正在打拼音时候选列表（和翻到的页、光标）不动
    if (translateSignature(state, phase, fresh) != translateDrawn_) {
        fillTranslateView(ic, state, ic->inputPanel());
        ic->updatePreedit();
        ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
    }
    return translateAt_ != 0 || phase == WOWTYPE_TRANSLATE_RUNNING || state->tpending_;
}

std::string WowtypeEngine::translateSignature(WowtypeState *state, int phase, bool fresh) const {
    std::string out = std::to_string(fresh ? phase : -1) + "|" + std::to_string(state->tpending_) +
                      "|" + state->tsource_;
    if (fresh) {
        out += "|";
        out += wowtype_translate_text(translator_);
    }
    if (fresh && phase == WOWTYPE_TRANSLATE_ERROR) {
        out += "|";
        out += wowtype_translate_error(translator_);
    }
    return out;
}

void WowtypeEngine::fillTranslateView(fcitx::InputContext *ic, WowtypeState *state,
                                      fcitx::InputPanel &panel) {
    const int phase = wowtype_translate_poll(translator_);
    const bool fresh =
        !state->tsource_.empty() && state->tsource_ == wowtype_translate_source(translator_);
    const bool failed = fresh && phase == WOWTYPE_TRANSLATE_ERROR;
    const bool done = fresh && phase == WOWTYPE_TRANSLATE_DONE;
    const std::string text = fresh && !failed ? wowtype_translate_text(translator_) : "";
    translateDrawn_ = translateSignature(state, phase, fresh);

    // 输入框里的译文：原文改了、新译文还没写到上一句那么长时先留着上一句，免得一闪一闪
    if (state->tsource_.empty() || failed) {
        state->tshown_.clear();
    } else if (done || text.size() >= state->tshown_.size()) {
        state->tshown_ = text;
    }

    // 原文框：攒着的原文 + 已选的词 + 还没选的拼音
    fcitx::Text box;
    box.append(state->tsource_);
    if (state->composing()) {
        box.append(state->selectedText());
        box.append(segmentedRemaining(state), fcitx::TextFormatFlag::Underline);
    }
    box.setCursor(static_cast<int>(box.textLength()));
    panel.setPreedit(box);
    panel.setAuxUp(fcitx::Text(std::string(wowtype_translate_tag(translator_, state->tsource_.c_str())) +
                               " 互译："));

    // 底下一行：状态，或者怎么上屏
    std::string status;
    if (failed) {
        status = std::string(wowtype_translate_error(translator_)) + "（回车重试）";
    } else if (state->tpending_) {
        status = "翻译中…好了就上屏";
    } else if (!state->tsource_.empty() && !done) {
        status = "翻译中…";
    } else if (!state->tsource_.empty() && !state->composing()) {
        status = "回车上屏 · Shift+回车上屏原文 · Esc 清空";
    }
    if (inlinePreedit(ic)) {
        fcitx::Text shown;
        shown.append(state->tshown_, fcitx::TextFormatFlag::Underline);
        shown.setCursor(static_cast<int>(shown.textLength()));
        panel.setClientPreedit(shown);
    } else if (!state->tshown_.empty() && !failed) {
        // 应用不让把编辑区画在输入框里：译文写在候选框底下
        status = state->tshown_ + (done ? "" : "…");
    }
    panel.setAuxDown(fcitx::Text(status));
}

bool WowtypeEngine::handleTranslateKey(fcitx::InputContext *ic, WowtypeState *state,
                                       const fcitx::Key &key) {
    const auto sym = key.sym();
    const auto states = key.states();
    if (states.test(fcitx::KeyState::Ctrl) || states.test(fcitx::KeyState::Alt) ||
        states.test(fcitx::KeyState::Super)) {
        return false;
    }
    if (!state->tsource_.empty()) {
        switch (sym) {
        case FcitxKey_Return:
        case FcitxKey_KP_Enter:
            if (states.test(fcitx::KeyState::Shift)) {
                commitTranslateSource(ic, state);
            } else {
                commitTranslation(ic, state);
            }
            return true;
        case FcitxKey_space:
            commitTranslation(ic, state);
            return true;
        case FcitxKey_Escape:
            clearTranslation(state);
            updateInputPanel(ic, state);
            return true;
        case FcitxKey_BackSpace:
            popUtf8(state->tsource_);
            translateSourceChanged(ic, state, false);
            updateInputPanel(ic, state);
            return true;
        default:
            if (key.isCursorMove() || sym == FcitxKey_Delete || sym == FcitxKey_Page_Up ||
                sym == FcitxKey_Page_Down || sym == FcitxKey_Tab || sym == FcitxKey_ISO_Left_Tab) {
                return true; // 原文里没有光标，别让应用里的光标乱跑
            }
            break;
        }
    }
    // 数字和没有中文写法的符号（/ + = 等）平时直接交给应用；互译时要进原文，免得插到前面
    if (sym > FcitxKey_space && sym <= FcitxKey_asciitilde &&
        !((sym >= FcitxKey_a && sym <= FcitxKey_z) || (sym >= FcitxKey_A && sym <= FcitxKey_Z)) &&
        !wowtype_fullwidth_punct(static_cast<int>(sym))) {
        const std::string text(1, static_cast<char>(sym));
        emit(ic, text);
        rememberContext(text);
        updateInputPanel(ic, state);
        return true;
    }
    return false;
}

void WowtypeEngine::commitTranslation(fcitx::InputContext *ic, WowtypeState *state) {
    if (!ic || !translator_ || state->tsource_.empty()) {
        return;
    }
    const int phase = wowtype_translate_poll(translator_);
    const bool fresh = state->tsource_ == wowtype_translate_source(translator_);
    if (fresh && phase == WOWTYPE_TRANSLATE_DONE) {
        const std::string text = wowtype_translate_text(translator_);
        clearTranslation(state);
        ic->commitString(text);
        updateInputPanel(ic, state);
        return;
    }
    // 还没译好（或出错了，回车就是重试）：记下来，好了再上屏
    state->tpending_ = true;
    if (translateIc_.get() != ic) {
        translateIc_ = ic->watch();
    }
    if (!fresh || phase == WOWTYPE_TRANSLATE_ERROR || phase == WOWTYPE_TRANSLATE_IDLE) {
        wowtype_translate_start(translator_, state->tsource_.c_str());
        translateAt_ = 0;
    }
    ensureTranslateTimer();
    updateInputPanel(ic, state);
}

void WowtypeEngine::commitTranslateSource(fcitx::InputContext *ic, WowtypeState *state) {
    if (!ic || state->tsource_.empty()) {
        return;
    }
    const std::string source = state->tsource_;
    clearTranslation(state);
    ic->commitString(source);
    updateInputPanel(ic, state);
}

class WowtypeFactory final : public fcitx::AddonFactory {
public:
    fcitx::AddonInstance *create(fcitx::AddonManager *manager) override {
        if (!manager) {
            return nullptr;
        }
        return new WowtypeEngine(manager->instance());
    }
};

// _V2 是 fcitx5 5.1.8 起才有的；Ubuntu 24.04 自带 5.1.7，只能用旧宏
#ifdef FCITX_ADDON_FACTORY_V2
FCITX_ADDON_FACTORY_V2(wowtype, WowtypeFactory)
#else
FCITX_ADDON_FACTORY(WowtypeFactory)
#endif
