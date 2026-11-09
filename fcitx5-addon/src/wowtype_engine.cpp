#include "wowtype_engine.h"
#include "wowtype_log.h"

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>
#include <system_error>
#include <utility>

#include <fcitx-config/iniparser.h>
#include <fcitx/addonfactory.h>
#include <fcitx/addonmanager.h>
#include <fcitx/candidatelist.h>
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
#include <fcitx-utils/textformatflags.h>

namespace {

constexpr const char *kSystemDataDir = "/usr/share/wowtype";
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

class WowtypeCandidateWord final : public fcitx::CandidateWord {
public:
    WowtypeCandidateWord(WowtypeEngine *engine, WowtypeState *state,
                         std::size_t index, const std::string &text)
        : engine_(engine), state_(state), index_(index) {
        setText(fcitx::Text(text));
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
    fuzzy_ = envOr("WOWTYPE_FUZZY", *config_.fuzzy);
    typo_ = envOr("WOWTYPE_TYPO", *config_.typo);
    shuangpin_ = envOr("WOWTYPE_SHUANGPIN", *config_.shuangpin);
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
    if (voiceKey_.sym() != FcitxKey_None && !voice_) {
        // 只建句柄：不开麦克风、不下载模型，第一次按热键时才做
        const char *dir = std::getenv("WOWTYPE_VOICE_MODEL_DIR");
        voice_ = wowtype_voice_new(dir);
    }
    WLOG_I() << "WowType: 设置 " << (horizontal_ ? "横排" : "竖排") << " 每页" << pageSize_
             << " 模糊音=" << fuzzy_ << " 纠错=" << typo_ << " 双拼=" << shuangpin_
             << " 繁体=" << traditional_ << " 语音键=" << voiceKey_.toString()
             << " emoji推荐=" << emojiSuggest_ << " 表情键=" << emojiKey_.toString()
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
    wowtype_engine_set_shuangpin(core_, shuangpin_ ? 1 : 0);
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
    ic->commitString(text);
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
        ic->commitString(text);
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
        state->candidates_.push_back({text, pinyin ? pinyin : "", consumed});
    }
    wowtype_candidates_free(raw);
    if (emojiSuggest_) {
        addEmojiSuggestions(state, input);
    }
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
        ic->commitString(text);
        rememberContext(text);
    }
    rememberEmoji(chosen.emojiText);
    state->clear();
    updateInputPanel(ic, state);
}

/// 还没选词的拼音，按第一个用完它的候选分好音节（hengxiang -> heng'xiang）。
/// 显示的还是用户打的字母；英文、双拼等切不了的原样显示。
std::string WowtypeEngine::segmentedRemaining(WowtypeState *state) const {
    const std::string input = state->remaining();
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

void WowtypeEngine::updateInputPanel(fcitx::InputContext *ic,
                                     WowtypeState *state) {
    auto &panel = ic->inputPanel();
    panel.reset();

    if (state->emojiPanel_) {
        fcitx::Text preedit;
        preedit.append(state->buffer_, fcitx::TextFormatFlag::Underline);
        preedit.setCursor(static_cast<int>(preedit.textLength()));
        panel.setPreedit(preedit);
        std::string aux = "表情";
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

    if (!state->composing()) {
        ic->updatePreedit();
        ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
        return;
    }

    // 编辑区：已选的词 + 还没选的拼音（带下划线）
    fcitx::Text preedit;
    preedit.append(state->selectedText());
    preedit.append(segmentedRemaining(state), fcitx::TextFormatFlag::Underline);
    preedit.setCursor(static_cast<int>(preedit.textLength()));
    panel.setPreedit(preedit);

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
                widths[c] = std::max(widths[c], displayWidth(all[r * kGridCols + c].text));
            }
        }
        for (std::size_t r = pageStart; r < pageEnd; ++r) {
            std::string line;
            for (std::size_t c = 0; c < kGridCols && r * kGridCols + c < n; ++c) {
                const std::size_t index = r * kGridCols + c;
                const bool here = index == state->gridCursor_;
                line += r == cursorRow ? kLabels[c] : "\u3000";
                line += here ? "\u3014" : "\u3000";
                line += all[index].text;
                if (here) {
                    line += "\u3015";
                    padTo(line, displayWidth(all[index].text), widths[c]);
                } else {
                    padTo(line, displayWidth(all[index].text), widths[c]);
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

    // 中英文切换交给 fcitx 自己的「临时切换输入法」热键（默认左 Shift），
    // 切走时 deactivate 会把打了一半的字母原样上屏。
    if (event.isRelease()) {
        return;
    }

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
            if (state->remaining().empty() && !state->selections_.empty()) {
                // 撤销最后一次选词，拼音回到编辑区
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
            } else if (pageable &&
                       (sym == FcitxKey_Page_Up || sym == FcitxKey_minus ||
                        sym == prevPageKey) &&
                       pageable->hasPrev()) {
                pageable->prev();
                handled = true;
            } else if (pageable &&
                       (sym == FcitxKey_Page_Down || sym == FcitxKey_equal ||
                        sym == nextPageKey) &&
                       pageable->hasNext()) {
                pageable->next();
                handled = true;
            }
            if (handled) {
                event.filterAndAccept();
                ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
                return;
            }
        }

        // 打字途中按标点：先上屏当前候选，再上屏中文标点
        if (const char *punct = wowtype_fullwidth_punct(static_cast<int>(sym));
            punct && sym != FcitxKey_apostrophe) {
            const std::string text = punct;
            // 光标停在句首词上时，选完它还剩半句：接着选第一个候选，直到整句上屏
            for (int guard = 0; state->composing() && guard < 16; ++guard) {
                commitCurrent(ic, state);
            }
            commitPlain(ic, text);
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
            event.filterAndAccept();
            return;
        }

        // 编辑区里光标没法移动，这些键吃掉，免得应用里的光标乱跑
        if (key.isCursorMove() || sym == FcitxKey_Tab || sym == FcitxKey_Delete) {
            event.filterAndAccept();
            return;
        }
    } else {
        // 没有正在输入的拼音时，把 ASCII 标点转成中文标点（映射表在 Rust 侧）。
        // 没收录的（/ " + 等）不处理，原样交给应用。
        if (const char *punct = wowtype_fullwidth_punct(static_cast<int>(sym))) {
            commitPlain(ic, punct);
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
    ic->propertyFor(&factory_)->clear();
    coreReady();
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
    ic->propertyFor(&factory_)->clear();
    ic->inputPanel().reset();
    ic->updatePreedit();
    ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
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
                CLOCK_MONOTONIC, fcitx::now(CLOCK_MONOTONIC) + kVoicePollUsec, 0,
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
        // 不写字，只画麦克风 + 跟着音量滚动的波形；第一次下载模型要很久，才写一句
        voiceLevels_.push_back(wowtype_voice_level(voice_));
        if (voiceLevels_.size() > kVoiceBars) {
            voiceLevels_.erase(voiceLevels_.begin());
        }
        std::string status = "🎙 " + voiceWave(voiceLevels_);
        if (wowtype_voice_model_state(voice_) == WOWTYPE_VOICE_MODEL_DOWNLOADING) {
            status += " 下载语音模型…";
        }
        showVoice(ic, status + " ", text);
        return true;
    }
    case WOWTYPE_VOICE_RECOGNIZING: {
        static const char *const kDots[] = {"·    ", "··   ", "···  ", "···· ", "·····"};
        showVoice(ic, std::string("🎙 ") + kDots[(voiceFrame_++ / 3) % 5] + " ", text);
        return true;
    }
    case WOWTYPE_VOICE_RESULT:
        clearVoice();
        commitPlain(ic, text);
        return false;
    case WOWTYPE_VOICE_ERROR:
        WLOG_I() << "WowType: 语音 " << text;
        showVoice(ic, "🎙 " + text, {});
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
    if (!partial.empty()) {
        fcitx::Text preedit;
        preedit.append(partial, fcitx::TextFormatFlag::Underline);
        preedit.setCursor(static_cast<int>(preedit.textLength()));
        panel.setPreedit(preedit);
    }
    panel.setAuxUp(fcitx::Text(status));
    ic->updatePreedit();
    ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
}

void WowtypeEngine::clearVoice() {
    voiceShowing_ = false;
    voiceLevels_.clear();
    voiceFrame_ = 0;
    voiceErrorUntil_ = 0;
    if (auto *ic = voiceIc_.get()) {
        ic->inputPanel().reset();
        ic->updatePreedit();
        ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
    }
    voiceIc_.unwatch();
}

void WowtypeEngine::cancelVoice() {
    if (voice_) {
        wowtype_voice_cancel(voice_);
    }
    clearVoice();
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
