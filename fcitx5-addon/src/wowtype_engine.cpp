#include "wowtype_engine.h"
#include "clipboard_copy.h"
#include "data_files.h"
#include "wowtype_log.h"

#include <algorithm>
#include <chrono>
#include <cstddef>
#include <ctime>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <fstream>
#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <system_error>
#include <thread>
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
constexpr unsigned int kMaxCandidates = 1000;
/// 每上屏这么多次保存一次用户词库（另外失去焦点和退出时也保存）。
constexpr int kSaveEvery = 20;
// 退出时等后台载入、后台存盘最多这么久（秒），再久就不等了（#244）
constexpr int kShutdownWaitSeconds = 3;
/// 打字推荐的 emoji 插在第几个候选（从 0 数）：不挤掉前两个词。

bool envFlag(const char *name, bool fallback) {
    const char *value = std::getenv(name);
    if (!value || !*value) {
        return fallback;
    }
    return *value != '0';
}

constexpr const char *kConfigFile = "conf/wowtype.conf";

/// 统计用的墙上时间（Unix 毫秒）：日界和 10 秒间隔都按它算。
int64_t statsNowMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::system_clock::now().time_since_epoch())
        .count();
}

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
/// 用户目录里那份是安装包自带数据的旧副本（版本不比系统目录的新，见 isStaleBundledCopy）时让给系统目录。
std::string findDataFile(const char *envName, const std::string &fileName) {
    if (const char *env = std::getenv(envName); env && *env) {
        return env;
    }
    std::error_code ec;
    const std::string user = userDataDir();
    const std::string system = std::string(kSystemDataDir) + "/" + fileName;
    if (!user.empty() && std::filesystem::exists(user + "/" + fileName, ec)) {
        const std::string mine = user + "/" + fileName;
        const std::string mineVersion = wowtype::dataFileVersion(mine, fileName);
        const std::string systemVersion = wowtype::dataFileVersion(system, fileName);
        const auto versionNote = [](const std::string &version) {
            return version.empty() ? std::string("没有版本标记") : "版本 " + version;
        };
        if (wowtype::isStaleBundledCopy(mine, system, fileName)) {
            WLOG_I() << "WowType: " << mine << "（" << versionNote(mineVersion)
                     << "）是安装包自带数据的旧副本，改用 " << system << "（" << versionNote(systemVersion)
                     << "；用户目录那份没在用，可以删掉）";
            return system;
        }
        // 用户自己放的（训练的 words.lm、自己做的词库、自己下的新数据）照旧优先
        if (wowtype::readDataMarker(mine)) {
            WLOG_I() << "WowType: 用 " << mine << "（" << versionNote(mineVersion) << "），安装包带的是 "
                     << versionNote(systemVersion);
            return mine;
        }
        // 没有标记的：比安装包带的旧时提一句
        std::error_code userEc;
        std::error_code systemEc;
        const auto userTime = std::filesystem::last_write_time(mine, userEc);
        const auto systemTime = std::filesystem::last_write_time(system, systemEc);
        if (!userEc && !systemEc && systemTime > userTime) {
            WLOG_W() << "WowType: 用的是 " << mine << "，它比 " << system
                     << " 旧；不是你自己放的话，删掉它就会用安装包带的新版";
        }
        return mine;
    }
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
/// 「没有语音模型，去设置里下载」这句提示显示多久。
constexpr uint64_t kVoiceHintUsec = 4000 * 1000;
// 定时器精度。fcitx5 底下是 sd-event，传 0 等于默认的 250ms，50ms 的轮询实际一秒只有 4 次
constexpr uint64_t kTimerAccuracyUsec = 1000;

/// 把编辑区画进输入框。每一段都标上 DontCommit：失去焦点、应用重置输入框时，GTK / Qt 的输入模块
/// （XIM 这类由 fcitx5 代劳）会把编辑区里没标 DontCommit 的字直接上屏，那样文档里会留下
/// 「ni'hao」这种带分隔符的拼音、选了一半的「你好zhong'guo」、没译完的译文。打到一半的是放弃
/// （和 IBus 的默认一样），外壳在 reset / deactivate 里清掉会话。
void setClientPreedit(fcitx::InputPanel &panel, const fcitx::Text &text) {
    fcitx::Text shown;
    for (std::size_t i = 0; i < text.size(); ++i) {
        shown.append(text.stringAt(i), text.formatAt(i) | fcitx::TextFormatFlag::DontCommit);
    }
    shown.setCursor(text.cursor());
    panel.setClientPreedit(shown);
}

std::string userConfigDir() {
    if (const char *config = std::getenv("XDG_CONFIG_HOME"); config && *config) {
        return std::string(config) + "/wowtype";
    }
    if (const char *home = std::getenv("HOME"); home && *home) {
        return std::string(home) + "/.config/wowtype";
    }
    return {};
}

// 语音浮条：WowType 的 GNOME 扩展注册这个名字，插件把语音状态发给它画。
// 信号 State(u 状态, s 文字, i 音量 0–100, i x, i y, i w, i h, b 相对窗口, d 缩放)，
// x/y/w/h 是光标矩形，和 kimpanel 的 SetSpotRect / SetRelativeSpotRectV2 同一个意思。
// 扩展画好了回一个 Ack(u 状态) 给插件；一次说话里等了 kOverlayAckUsec 还没有回执（扩展在这个
// GNOME 上画出错、或者是不会回执的旧版扩展），就改在候选框里提示，不会什么都不显示（#170）。
constexpr const char *kOverlayService = "io.github.gloridust.WowType.VoiceOverlay";
constexpr const char *kOverlayPath = "/io/github/gloridust/WowType";
constexpr const char *kOverlayInterface = "io.github.gloridust.WowType.Voice1";
constexpr uint32_t kOverlayHide = 0;
constexpr uint32_t kOverlayListening = 1;
constexpr uint32_t kOverlayRecognizing = 2;
constexpr uint32_t kOverlayDone = 3;
constexpr uint32_t kOverlayError = 4;
constexpr uint64_t kOverlayAckUsec = 800 * 1000;

// 展开面板的网格（#270）：GNOME 下 kimpanel 只会把整行涂绿，看不出光标在哪个词上。
// WowType 的扩展登记 kGridService，插件把这一屏的格子发给它画真正的 6×6 网格，只有光标处那一格高亮：
//   插件 -> 扩展  Show(u serial, as 格子, u 第一格的全局下标, u 光标的全局下标, u 列数, u 第几屏, u 共几屏,
//                      s 提示, i x, i y, i w, i h, b 相对窗口, d 缩放)
//                 Hide(u serial)
//   扩展 -> 插件  Ack(u serial)            画好了、显示出来了
//                 Select(u serial, u 下标)  点了一格（全局下标）
// 光标矩形和语音浮条、kimpanel 的一样。扩展回执期间 kimpanel 拿到的是一个空列表（提示、编辑区也挪进网格），
// 它的候选框整个不画；扩展没登记这个名字（没装、停用了、只会画语音浮条的旧版）就照旧把网格拼成几行给 kimpanel，
// 发了 kGridAckUsec 还没有回执也退回去。
constexpr const char *kGridService = "io.github.gloridust.WowType.CandidateGrid";
constexpr const char *kGridInterface = "io.github.gloridust.WowType.Grid1";
constexpr uint64_t kGridAckUsec = 500 * 1000;

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

/// 默认词库：用户数据目录或系统目录里的 lexicon.tsv（雾凇），都没有就用 demo 词典。
std::string defaultLexicon() {
    std::string lexicon = findDataFile("WOWTYPE_LEXICON", "lexicon.tsv");
    if (lexicon.empty()) {
        lexicon = std::string(kSystemDataDir) + "/demo_lexicon.tsv";
    }
    return lexicon;
}

/// 实际用哪个词库：环境变量 WOWTYPE_LEXICON > 配置里的 Lexicon（文件在才用）> 默认。
std::string resolveLexicon(const std::string &configured) {
    if (const char *env = std::getenv("WOWTYPE_LEXICON"); env && *env) {
        return env;
    }
    if (!configured.empty()) {
        std::string path = configured;
        if (path.rfind("~/", 0) == 0) {
            if (const char *home = std::getenv("HOME"); home && *home) {
                path = std::string(home) + path.substr(1);
            }
        }
        std::error_code ec;
        if (std::filesystem::is_regular_file(path, ec)) {
            return path;
        }
        WLOG_W() << "WowType: 配置里的词库 " << path << " 不在，用默认词库";
    }
    return defaultLexicon();
}

/// 文件的 (大小, 修改时间)，拿不到是 (0, 0)。
std::pair<std::uintmax_t, long long> fileStamp(const std::string &path) {
    std::error_code ec;
    const auto size = std::filesystem::file_size(path, ec);
    if (ec) {
        return {0, 0};
    }
    const auto time = std::filesystem::last_write_time(path, ec);
    if (ec) {
        return {0, 0};
    }
    return {size, static_cast<long long>(time.time_since_epoch().count())};
}

/// 整句增强模型（字级神经语言模型）用哪一份：环境变量 WOWTYPE_NNLM 指定了就只用它；否则先用用户导入的
/// 微信输入法模型（wetype/nlrgpt2_nnlm.bin，腾讯的，不随 WowType 分发），没有再用 nnlm.bin（安装包自带的
/// WowType 自己训的，在系统数据目录；用户目录里放了一份就先用那份）。都没有返回空。
/// what 写上是哪一份，给日志用。
std::string findNnlm(std::string &what) {
    if (const char *env = std::getenv("WOWTYPE_NNLM"); env && *env) {
        what = "环境变量 WOWTYPE_NNLM 指定的模型";
        return env;
    }
    if (std::string wetype = findDataFile("WOWTYPE_NNLM", "wetype/nlrgpt2_nnlm.bin"); !wetype.empty()) {
        what = "导入的微信输入法模型";
        return wetype;
    }
    if (std::string own = findDataFile("WOWTYPE_NNLM", "nnlm.bin"); !own.empty()) {
        what = own.starts_with(std::string(kSystemDataDir) + "/") ? "WowType 自带的整句增强模型"
                                                                    : "用户目录里的 nnlm.bin";
        return own;
    }
    what.clear();
    return {};
}

/// 认模型文件换没换：路径 + 大小 + 修改时间；没有模型是空串。
std::string nnlmStamp(const std::string &path) {
    if (path.empty()) {
        return {};
    }
    const auto [size, time] = fileStamp(path);
    return path + ":" + std::to_string(size) + ":" + std::to_string(time);
}

/// 用这个词库建核心；语言模型坏了（版本不对、文件不完整）不该让输入法整个用不了，
/// 不带它再试一次（这时 lm 清空）。
WowtypeEngineHandle *openCore(const std::string &lexicon, std::string &lm) {
    WowtypeEngineHandle *core =
        wowtype_engine_new(lexicon.c_str(), lm.empty() ? nullptr : lm.c_str());
    if (!core && !lm.empty()) {
        WLOG_W() << "WowType: 语言模型载入失败，不用它，文件=" << lm << "，错误="
                     << (wowtype_last_error() ? wowtype_last_error() : "unknown");
        lm.clear();
        core = wowtype_engine_new(lexicon.c_str(), nullptr);
    }
    return core;
}

/// 载入失败的文件（还在的话）改名成 <原名>.bad-<时间戳> 留着，免得接下来存的把它盖掉：
/// 盖上去的只有这次运行里学到的，原来攒的全没了。返回 true 表示可以往 path 存了
/// （改好名了，或者文件已经不在了）；改不了名返回 false，这次先不存。
bool setAsideUnreadFile(const std::string &path, const char *what) {
    std::error_code ec;
    if (!std::filesystem::exists(std::filesystem::symlink_status(path, ec))) {
        return true;
    }
    char stamp[32] = "0";
    const std::time_t now = std::time(nullptr);
    std::tm local{};
    if (localtime_r(&now, &local)) {
        std::strftime(stamp, sizeof(stamp), "%Y%m%d-%H%M%S", &local);
    }
    std::string backup = path + ".bad-" + stamp;
    for (int i = 2; std::filesystem::exists(std::filesystem::symlink_status(backup, ec)); ++i) {
        backup = path + ".bad-" + stamp + "-" + std::to_string(i);
    }
    std::filesystem::rename(path, backup, ec);
    if (ec) {
        WLOG_W() << "WowType: " << what << " " << path << " 启动时没读出来，想改名留着也没改成（"
                 << ec.message() << "），这次先不存，免得把它盖掉";
        return false;
    }
    WLOG_W() << "WowType: " << what << " " << path << " 启动时没读出来，原文件改名留在 " << backup
             << "，新学到的另存";
    return true;
}

/// 在后台线程里做的事：载入词库、语言模型、各种开关和用户词。
WowtypeLoaded loadCore(const std::string &userDict, std::string lexicon) {
    if (lexicon.ends_with("/demo_lexicon.tsv")) {
        WLOG_W() << "WowType: 没找到 lexicon.tsv，用 demo 词典（只有几十个词）";
    }
    // 词级语言模型：wowtype-lmbuild 生成的 words.lm；没有就找旧的 bigram.tsv
    std::string lm = findDataFile("WOWTYPE_LM", "words.lm");
    if (lm.empty()) {
        lm = findDataFile("WOWTYPE_LM", "bigram.tsv");
    }
    const std::string lmFile = lm;
    const auto started = std::chrono::steady_clock::now();
    WowtypeEngineHandle *core = openCore(lexicon, lm);
    if (!core) {
        // 选的词库（比如下载的万象）坏了：退回默认词库，别让输入法用不了
        if (const std::string fallback = defaultLexicon(); fallback != lexicon) {
            WLOG_W() << "WowType: 词库 " << lexicon << " 载入失败（"
                         << (wowtype_last_error() ? wowtype_last_error() : "unknown")
                         << "），改用默认词库 " << fallback;
            lexicon = fallback;
            lm = lmFile;
            core = openCore(lexicon, lm);
        }
    }
    if (!core) {
        WLOG_E() << "WowType: 初始化 Rust 核心失败，词典=" << lexicon
                      << "，错误="
                      << (wowtype_last_error() ? wowtype_last_error() : "unknown");
        return {};
    }
    WowtypeLoaded result;
    result.core = core;

    const std::string english = findDataFile("WOWTYPE_ENGLISH", "english.txt");
    if (!english.empty()) {
        const int loaded = wowtype_engine_load_english(core, english.c_str());
        if (loaded > 0) {
            WLOG_I() << "WowType: 载入英文词 " << loaded << " 个";
        }
    }
    // 整句增强模型：先用导入的微信输入法模型，没有再用安装包自带的 nnlm.bin（findNnlm）
    std::string nnlmWhat;
    if (const std::string nnlm = findNnlm(nnlmWhat); !nnlm.empty()) {
        const int loaded = wowtype_engine_load_nnlm(core, nnlm.c_str());
        if (loaded > 0) {
            WLOG_I() << "WowType: 载入整句增强模型：" << nnlmWhat << " " << nnlm << "（" << loaded << " 字）";
            result.nnlmStamp = nnlmStamp(nnlm);
        } else {
            WLOG_W() << "WowType: 整句增强模型载入失败（" << nnlmWhat << "）" << nnlm << "："
                         << (wowtype_last_error() ? wowtype_last_error() : "unknown");
        }
    } else {
        WLOG_I() << "WowType: 没有整句增强模型（没导入微信输入法的，安装包里也没有 nnlm.bin）";
    }
    // 用户自己训的领域词级模型（可选），和 words.lm 混着用
    if (const std::string domain = findDataFile("WOWTYPE_DOMAIN_LM", "words.domain.lm");
        !domain.empty()) {
        if (wowtype_engine_set_domain_lm(core, domain.c_str()) == 0) {
            WLOG_I() << "WowType: 载入领域词级模型 " << domain;
        } else {
            WLOG_W() << "WowType: 领域词级模型载入失败 " << domain << "："
                         << (wowtype_last_error() ? wowtype_last_error() : "unknown");
        }
    }
    // 文件在、却没读出来（读不了、不是 UTF-8……）：记下来，存之前先把原文件改名留着（maybeSaveUserDict），
    // 不然下次存盘会用只有这次运行里学到的内容把它盖掉。文件不在是第一次用，不算
    const auto present = [](const std::string &path) {
        std::error_code ec;
        return std::filesystem::exists(std::filesystem::symlink_status(path, ec));
    };
    if (!userDict.empty() && present(userDict)) {
        const int loaded = wowtype_engine_load_user_dict(core, userDict.c_str());
        if (loaded > 0) {
            WLOG_I() << "WowType: 载入用户词 " << loaded << " 条";
        } else if (loaded < 0) {
            result.userDictUnread = true;
            WLOG_W() << "WowType: 用户词库载入失败 " << userDict << "："
                         << (wowtype_last_error() ? wowtype_last_error() : "unknown");
        }
    }
    if (const std::string history = historyPathFor(userDict); !history.empty() && present(history)) {
        const int loaded = wowtype_engine_load_history(core, history.c_str());
        if (loaded >= 0) {
            WLOG_I() << "WowType: 载入输入习惯 " << loaded << " 条";
        } else {
            result.historyUnread = true;
            WLOG_W() << "WowType: 输入习惯载入失败 " << history << "："
                         << (wowtype_last_error() ? wowtype_last_error() : "unknown");
        }
    }
    const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                        std::chrono::steady_clock::now() - started)
                        .count();
    WLOG_I() << "WowType: 词典 " << lexicon << " 载入完成，用时 " << ms << " ms"
                 << (lm.empty() ? "（没有语言模型）" : "，语言模型 " + lm);
    return result;
}

/// 打字途中会话不管的键里，照常交给应用的那些：修饰键和锁定键本身（Shift / Ctrl / Alt / Super、
/// 大写锁定、数字锁定、AltGr、切换键盘布局的键），还有认不出来的键（没有 keysym）。别的都吃掉。
bool passesWhileComposing(fcitx::KeySym sym) {
    const auto value = static_cast<uint32_t>(sym);
    return sym == FcitxKey_None || sym == FcitxKey_VoidSymbol ||
           (value >= FcitxKey_Shift_L && value <= FcitxKey_Hyper_R) ||
           (value >= FcitxKey_ISO_Lock && value <= FcitxKey_ISO_Level5_Lock) ||
           sym == FcitxKey_Mode_switch || sym == FcitxKey_Num_Lock || sym == FcitxKey_Scroll_Lock;
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

class WowtypeCandidateWord final : public fcitx::CandidateWord {
public:
    /// shown 是 shownCandidate 画好的样子。
    WowtypeCandidateWord(WowtypeEngine *engine, WowtypeState *state,
                         std::size_t index, fcitx::Text shown)
        : engine_(engine), state_(state), index_(index) {
        setText(std::move(shown));
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
    WowtypeGridRow(WowtypeEngine *engine, WowtypeState *state, std::size_t row, fcitx::Text text)
        : engine_(engine), state_(state), row_(row) {
        setText(std::move(text));
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
        engine_->choosePanelItem(inputContext, state_, index_);
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
    /// 画在字后面的编码提示（五笔还要打的码、z 临时拼音反查的五笔码），不上屏。
    std::string comment;
};

namespace {

/// 候选框里一个候选的样子：字（换行画成 ⏎），后面空一格是斜体的编码提示，和字分得开。
/// fcitx5 5.1.9 以前候选没有注释位，经典界面也只认粗体、斜体、下划线、删除线，画不了浅色，
/// 斜体是各个版本都一样的那个。
fcitx::Text shownCandidate(const WowtypeCandidate &candidate) {
    fcitx::Text out(shownText(candidate.text));
    if (!candidate.comment.empty()) {
        out.append(" " + candidate.comment, fcitx::TextFormatFlag::Italic);
    }
    return out;
}

} // namespace

/// 每个输入上下文独立保存的缓冲区和候选。
class WowtypeState final : public fcitx::InputContextProperty {
public:
    WowtypeState() : session_(wowtype_session_new(nullptr, nullptr)) {}
    ~WowtypeState() override { wowtype_session_free(session_); }
    WowtypeState(const WowtypeState &) = delete;
    WowtypeState &operator=(const WowtypeState &) = delete;

    /// 核心的输入会话：编辑区的原始输入和已选词栈在这里（见 docs/PORTING.md）。
    /// 表情面板开着时，原始输入就是搜索词。
    WowtypeSession *session_;
    std::vector<WowtypeCandidate> candidates_;
    /// 展开的面板（普通候选下键展开，或表情面板）；gridCursor_ 是光标所在候选的全局下标。
    /// 普通候选的这些（连同下面的页码、光标）是会话的候选框状态的拷贝，见 syncView。
    bool expanded_ = false;
    std::size_t gridCursor_ = 0;
    /// 普通候选列表的页码和光标（全局下标，可以不在这一页上）；工具栏也用 panelCursor_。
    std::size_t panelPage_ = 0;
    std::size_t panelCursor_ = 0;
    /// candidates_ 抄的是会话第几次重算的候选（WowtypeSessionView.generation）。
    uint64_t candGeneration_ = UINT64_MAX;
    /// 开着的工具栏 / 表情面板（WOWTYPE_TOOL_*），会话管。
    int panel() const { return wowtype_session_open_panel(session_); }
    /// 会话开着上屏以后的联想（没在打字）。
    bool associating() const { return wowtype_session_association(session_) != 0; }
    /// 候选框上画着联想行：会话关掉了联想、键又交给了应用时要收起来。
    bool associationShown_ = false;

    /// 全部原始输入（包括已经选过词的部分）。
    std::string input() const { return wowtype_session_input(session_); }
    /// 还没选词的那部分输入。
    std::string remaining() const { return wowtype_session_remaining(session_); }
    std::string selectedText() const { return wowtype_session_selected_text(session_); }
    bool hasSelections() const { return !selectedText().empty(); }
    bool composing() const { return *wowtype_session_input(session_) != '\0'; }
    /// 交给会话处理一个按下的键（keysym 为 0 时只有动作）。先用 WowtypeEngine::sessionKey
    /// 同步引擎和设置。返回的 frame 归会话，下一次调会话前有效。
    /// prev_char：应用里光标前一个字（读不到给 0）；hints：WOWTYPE_KEY_HINT_*。
    const WowtypeFrame *sessionKey(uint32_t keysym, uint32_t modifiers, uint32_t action,
                                   uint32_t prevChar = 0, uint32_t hints = 0,
                                   uint64_t timeMs = 0, uint32_t nextChar = 0) {
        WowtypeKey raw{};
        raw.time_ms = timeMs;
        raw.size = sizeof(raw);
        raw.keysym = keysym;
        raw.modifiers = modifiers;
        raw.action = action;
        raw.prev_char = prevChar;
        raw.hints = hints;
        raw.next_char = nextChar;
        return wowtype_session_key(session_, &raw);
    }
    /// 清掉编辑区。返回 true：单按 Shift 还在等双击（#253），这一下照切了，外壳的全局模式要跟上。
    bool clear() {
        const WowtypeFrame *reset = wowtype_session_reset(session_, 0);
        bool modeChanged = reset && reset->mode_changed;
        // 按下了 Shift 还没松开，输入框就被重置、失去焦点（Shift+点鼠标选字、按着 Shift 换窗口）：和按住
        // Shift 时按了别的键一样报给会话，再松开就不算单按 Shift、不切中英文
        const WowtypeFrame *observed = sessionKey(FcitxKey_VoidSymbol, 0, WOWTYPE_KEY_ACTION_OBSERVE);
        modeChanged = modeChanged || (observed && observed->mode_changed);
        forgetCandidates();
        return modeChanged;
    }

    /// 只丢掉外壳抄的候选和候选框状态，会话的编辑区不动。
    void forgetCandidates() {
        candidates_.clear();
        candGeneration_ = UINT64_MAX;
        expanded_ = false;
        gridCursor_ = 0;
        panelPage_ = 0;
        panelCursor_ = 0;
    }
};

namespace {

/// 普通候选的列表：翻页、移动光标交给会话，再照会话的页码和光标摆好自己。
/// 键盘上的翻页键由会话直接处理；这里接的是鼠标点翻页按钮、滚轮，和直接调候选列表的。
class WowtypeSessionList final : public fcitx::CommonCandidateList {
public:
    explicit WowtypeSessionList(WowtypeState *state) : state_(state) {}

    void prev() override { act(WOWTYPE_KEY_ACTION_PREV_PAGE); }
    void next() override { act(WOWTYPE_KEY_ACTION_NEXT_PAGE); }
    void prevCandidate() override { act(WOWTYPE_KEY_ACTION_PREV_CANDIDATE); }
    void nextCandidate() override { act(WOWTYPE_KEY_ACTION_NEXT_CANDIDATE); }
    void setPage(int page) override {
        if (mirroring_) {
            // mirror 里调的 CommonCandidateList::next() 会走到这里：只摆自己，不再翻会话
            CommonCandidateList::setPage(page);
            return;
        }
        for (int guard = 0; guard < 1000 && page != currentPage(); ++guard) {
            const int before = currentPage();
            act(page < before ? WOWTYPE_KEY_ACTION_PREV_PAGE : WOWTYPE_KEY_ACTION_NEXT_PAGE);
            if (currentPage() == before) {
                break;
            }
        }
    }

    /// 照会话的页码和光标摆好（页码往后翻一页时用 next()，fcitx5 记得「用过下一页」）。
    void mirror(std::size_t page, std::size_t cursor) {
        mirroring_ = true;
        const int target = static_cast<int>(page);
        if (target != currentPage() && target >= 0 && target < totalPages()) {
            if (target == currentPage() + 1) {
                CommonCandidateList::next();
            } else {
                CommonCandidateList::setPage(target);
            }
        }
        if (static_cast<int>(cursor) < totalSize()) {
            setGlobalCursorIndex(static_cast<int>(cursor));
        }
        mirroring_ = false;
    }

private:
    void act(uint32_t action) {
        state_->sessionKey(0, 0, action);
        WowtypeSessionView view{};
        view.size = sizeof(view);
        if (wowtype_session_view(state_->session_, &view) != 0) {
            return;
        }
        state_->panelPage_ = view.page;
        state_->panelCursor_ = view.cursor;
        mirror(view.page, view.cursor);
    }

    WowtypeState *state_;
    bool mirroring_ = false;
};

/// 展开面板交给 GNOME 扩展画网格时给 kimpanel 的列表（#270）：一项也没有，kimpanel 就不画候选框。
/// 也是个记号：输入框上换成了别的列表，就是不再显示网格了，叫扩展收起。
class WowtypeGridOverlayList final : public fcitx::CommonCandidateList {};

/// 工具栏、表情面板、展开面板的列表：候选框上的翻页按钮、滚轮和直接调列表的，都和键盘上按
/// Page Up / Page Down、上下键一样交给会话，再照会话的光标整个重画（WowtypeEngine::panelListKey）。
/// 让 CommonCandidateList 自己翻的话只是换了显示的那一页，会话的光标还在原来那一页，接着按数字、
/// 空格选的是原来那页的。
class WowtypePanelList final : public fcitx::CommonCandidateList {
public:
    WowtypePanelList(WowtypeEngine *engine, fcitx::InputContext *ic, WowtypeState *state)
        : engine_(engine), ic_(ic->watch()), state_(state) {}

    void prev() override { act(FcitxKey_Page_Up); }
    void next() override { act(FcitxKey_Page_Down); }
    void prevCandidate() override {
        // 第一个（展开面板是第一行）上不再往上：展开面板里那是收起
        if (globalCursorIndex() > 0) {
            act(FcitxKey_Up);
        }
    }
    void nextCandidate() override { act(FcitxKey_Down); }
    void setPage(int page) override {
        // 一屏一屏翻会话。重画会换掉输入框的列表，翻完之前自己先留着
        const auto keep = shown();
        if (!keep) {
            return;
        }
        const int steps = page - currentPage();
        for (int i = 0; i < std::min(std::abs(steps), 1000) && ic_.get(); ++i) {
            engine_->panelListKey(ic_.get(), state_, steps < 0 ? FcitxKey_Page_Up : FcitxKey_Page_Down);
        }
    }

    /// 建列表时照会话的光标摆好（只摆自己）：setGlobalCursorIndex 只设光标、不翻页，先翻到光标那一页，
    /// 不然光标走到后面几页时看不到。
    void place(std::size_t page, std::size_t cursor) {
        CommonCandidateList::setPage(static_cast<int>(page));
        setGlobalCursorIndex(static_cast<int>(cursor));
    }

private:
    /// 输入框现在显示的就是这个列表才返回它（不是的话是一个过时的列表，不能拿它去翻会话）。
    std::shared_ptr<fcitx::CandidateList> shown() const {
        auto *ic = ic_.get();
        auto list = ic ? ic->inputPanel().candidateList() : nullptr;
        return list.get() == this ? list : nullptr;
    }

    void act(fcitx::KeySym sym) {
        if (const auto keep = shown()) {
            engine_->panelListKey(ic_.get(), state_, sym);
        }
    }

    WowtypeEngine *engine_;
    fcitx::TrackableObjectReference<fcitx::InputContext> ic_;
    WowtypeState *state_;
};

} // namespace

WowtypeEngine::WowtypeEngine(fcitx::Instance *instance)
    : instance_(instance),
      core_(nullptr),
      factory_([](fcitx::InputContext &) { return new WowtypeState(); }) {
    instance_->inputContextManager().registerProperty("wowtype", &factory_);
    WLOG_I() << "WowType " << WOWTYPE_ADDON_VERSION << " 启动（fcitx5 " << fcitx::Instance::version()
             << "）";
    fcitx::RawConfig raw;
    fcitx::readAsIni(raw, kConfigFile);
    loadWowtypeConfig(config_, raw);
    // 全量词库载入要几百毫秒，放后台，别卡住 fcitx 启动
    lexicon_ = wantedLexicon_ = resolveLexicon(*config_.lexicon);
    lexiconStamp_ = fileStamp(lexicon_);
    loading_ = std::async(std::launch::async, loadCore, userDictPath(), lexicon_);
    // 打字统计的记录器建好时是关着的（不读不建文件），applyConfig 按 TypingStats 打开
    if (const std::string statsDir = userDataDir(); !statsDir.empty()) {
        const std::string statsPath = statsDir + "/stats.json";
        stats_ = wowtype_stats_new(statsPath.c_str());
        if (!stats_) {
            WLOG_W() << "WowType: 建不了打字统计 " << statsPath << "："
                     << (wowtype_last_error() ? wowtype_last_error() : "unknown");
        }
    }
    applyConfig();
    setupOverlays();
    setupControl();
}

namespace {
constexpr char kControlService[] = "org.wowtype.Input";
constexpr char kControlPath[] = "/org/wowtype/Input";
constexpr char kControlInterface[] = "org.wowtype.Input1";
} // namespace

std::string WowtypeControl::mode() { return engine_->modeName(); }

std::string WowtypeControl::version() { return WOWTYPE_ADDON_VERSION; }

std::string WowtypeControl::setMode(const std::string &mode) {
    if (!engine_->setModeByName(mode)) {
        throw fcitx::dbus::MethodCallError("org.freedesktop.DBus.Error.InvalidArgs",
                                           ("不认识的模式或现在切不了：" + mode +
                                            "（可以是 zh、en、translate、toggle）")
                                               .c_str());
    }
    return engine_->modeName();
}

void WowtypeEngine::setupControl() {
    try {
        auto bus = std::make_unique<fcitx::dbus::Bus>(fcitx::dbus::BusType::Session);
        if (!bus->isOpen()) {
            return;
        }
        bus->attachEventLoop(&instance_->eventLoop());
        auto control = std::make_unique<WowtypeControl>(this);
        if (!bus->addObjectVTable(kControlPath, kControlInterface, *control) ||
            !bus->requestName(kControlService,
                              fcitx::Flags<fcitx::dbus::RequestNameFlag>{
                                  fcitx::dbus::RequestNameFlag::ReplaceExisting,
                                  fcitx::dbus::RequestNameFlag::AllowReplacement})) {
            WLOG_W() << "WowType: 登记 " << kControlService << " 失败，外部命令切不了模式";
            return;
        }
        controlBus_ = std::move(bus);
        control_ = std::move(control);
    } catch (const std::exception &e) {
        WLOG_I() << "WowType: 连不上会话总线，外部命令切不了模式：" << e.what();
    }
}

std::string WowtypeEngine::modeName() const {
    return translateMode_ ? "translate" : asciiMode_ ? "en" : "zh";
}

bool WowtypeEngine::setModeByName(const std::string &mode) {
    bool ascii = false;
    bool translate = false;
    if (mode == "en") {
        ascii = true;
    } else if (mode == "translate") {
        if (!translateAvailable()) {
            return false;
        }
        translate = true;
    } else if (mode == "toggle") {
        ascii = !asciiMode_ && !translateMode_;
    } else if (mode != "zh") {
        return false;
    }
    if (ascii == asciiMode_ && translate == translateMode_) {
        return true;
    }
    // 切的是最近用过的输入框（vim 所在的终端）；它没在用 WowType 时只改模式
    fcitx::InputContext *ic = instance_->mostRecentInputContext();
    WowtypeState *state = ic ? ic->propertyFor(&factory_) : nullptr;
    switchMode(ic, state, ascii, translate, false);
    return true;
}

void WowtypeEngine::setupOverlays() {
    // WOWTYPE_VOICE_OVERLAY=0：不用 GNOME 扩展的浮条，一直用候选框里的文字提示；
    // WOWTYPE_GRID_OVERLAY=0：展开面板一直拼成几行交给 kimpanel
    const bool voice = envFlag("WOWTYPE_VOICE_OVERLAY", true);
    const bool grid = envFlag("WOWTYPE_GRID_OVERLAY", true);
    if (!voice && !grid) {
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
        if (grid) {
            setupGridOverlay();
        }
        if (!voice) {
            return;
        }
        overlayWatch_ = overlayWatcher_->watchService(
            kOverlayService,
            [this](const std::string &, const std::string &, const std::string &owner) {
                if (owner != overlayOwner_) {
                    overlayOwner_ = owner;
                    // 换了一个扩展实例（重新登录、扩展重载）：再给浮条一次机会
                    overlayBroken_ = false;
                    overlayAcked_ = false;
                    overlaySentAt_ = 0;
                    WLOG_I() << "WowType: 语音浮条" << (owner.empty() ? "不在了" : "就绪");
                }
            });
        overlayAckSlot_ = overlayBus_->addMatch(
            fcitx::dbus::MatchRule(kOverlayService, kOverlayPath, kOverlayInterface, "Ack"),
            [this](fcitx::dbus::Message &msg) {
                uint32_t state = kOverlayHide;
                msg >> state;
                // 只算这次说话里、显示出来的状态的回执：上一次收起时的回执可能这时才到
                if (msg.sender() == overlayOwner_ && overlaySentAt_ && state != kOverlayHide &&
                    state != kOverlayDone) {
                    overlayAcked_ = true;
                }
                return true;
            });
    } catch (const std::exception &e) {
        // 没有会话总线（比如测试里）：用文字提示
        WLOG_I() << "WowType: 连不上会话总线，语音用文字提示：" << e.what();
        gridEventWatchers_.clear();
        gridSelectSlot_.reset();
        gridAckSlot_.reset();
        gridWatch_.reset();
        gridOwner_.clear();
        overlayAckSlot_.reset();
        overlayWatch_.reset();
        overlayWatcher_.reset();
        overlayBus_.reset();
    }
}

namespace {
/// 光标矩形，和 kimpanel 的 SetSpotRect / SetRelativeSpotRectV2 同一个意思（扩展照 kimpanel 的算法换成屏幕坐标）。
struct OverlayCursor {
    int32_t x = 0, y = 0, w = 0, h = 0;
    bool relative = false;
    double scale = 1.0;
};

OverlayCursor overlayCursor(fcitx::InputContext *ic) {
    OverlayCursor out;
    if (ic) {
        const fcitx::Rect &rect = ic->cursorRect();
        out.x = rect.left();
        out.y = rect.top();
        out.w = rect.width();
        out.h = rect.height();
        out.relative = ic->capabilityFlags().test(fcitx::CapabilityFlag::RelativeRect);
        out.scale = ic->scaleFactor();
    }
    return out;
}
} // namespace

void WowtypeEngine::sendVoiceOverlay(fcitx::InputContext *ic, uint32_t state,
                                     const std::string &label, int level) {
    if (!overlayBus_ || overlayOwner_.empty()) {
        return;
    }
    const OverlayCursor c = overlayCursor(ic);
    auto msg = overlayBus_->createSignal(kOverlayPath, kOverlayInterface, "State");
    msg.setDestination(overlayOwner_);
    msg << state << label << static_cast<int32_t>(std::clamp(level, 0, 100)) << c.x << c.y << c.w
        << c.h << c.relative << c.scale;
    msg.send();
    if (state != kOverlayHide && state != kOverlayDone && !overlaySentAt_) {
        overlaySentAt_ = fcitx::now(CLOCK_MONOTONIC);
    }
}

void WowtypeEngine::checkOverlayAck(fcitx::InputContext *ic) {
    if (!overlaySentAt_ || overlayAcked_ || overlayBroken_ ||
        fcitx::now(CLOCK_MONOTONIC) - overlaySentAt_ < kOverlayAckUsec) {
        return;
    }
    overlayBroken_ = true;
    WLOG_W() << "WowType: 语音浮条没有回应（GNOME 扩展画的时候出错了？），改在候选框里提示；"
                "重新登录后会再试浮条";
    // 正留着的错误提示马上换到候选框里；录音、识别中的提示下一轮就按候选框画
    if (voiceErrorUntil_ && !voiceErrorText_.empty()) {
        showVoice(ic, "🎙 " + voiceErrorText_, {});
    }
}

void WowtypeEngine::setupGridOverlay() {
    gridWatch_ = overlayWatcher_->watchService(
        kGridService, [this](const std::string &, const std::string &, const std::string &owner) {
            if (owner == gridOwner_) {
                return;
            }
            gridOwner_ = owner;
            // 换了一个扩展实例（重新登录、扩展重载）：再给网格一次机会
            gridBroken_ = false;
            gridAckedSerial_ = gridSerial_;
            gridPendingSince_ = 0;
            WLOG_I() << "WowType: 展开面板的网格" << (owner.empty() ? "不在了，用 kimpanel 的列表" : "就绪");
            // 正显示着网格时扩展没了（停用、重载）：马上照现在的样子重画，换回 kimpanel 的列表
            if (auto *ic = gridIc_.get()) {
                gridIc_.unwatch();
                updateInputPanel(ic, ic->propertyFor(&factory_));
            }
        });
    gridAckSlot_ = overlayBus_->addMatch(
        fcitx::dbus::MatchRule(kGridService, kOverlayPath, kGridInterface, "Ack"),
        [this](fcitx::dbus::Message &msg) {
            uint32_t serial = 0;
            msg >> serial;
            if (msg.sender() != gridOwner_ || serial == 0 || serial > gridSerial_) {
                return true;
            }
            if (gridBroken_) {
                // 回执迟到了（扩展只是慢）：下一次展开照样交给它
                gridBroken_ = false;
                WLOG_I() << "WowType: 展开面板的网格回执迟到了，下次照样由扩展画";
            }
            gridAckedSerial_ = std::max(gridAckedSerial_, serial);
            // 后面发的还没回执：从现在起再等一轮
            gridPendingSince_ = gridAckedSerial_ >= gridSerial_ ? 0 : fcitx::now(CLOCK_MONOTONIC);
            return true;
        });
    gridSelectSlot_ = overlayBus_->addMatch(
        fcitx::dbus::MatchRule(kGridService, kOverlayPath, kGridInterface, "Select"),
        [this](fcitx::dbus::Message &msg) {
            uint32_t serial = 0;
            uint32_t index = 0;
            msg >> serial >> index;
            if (msg && msg.sender() == gridOwner_) {
                selectGridCell(serial, index);
            }
            return true;
        });
    for (const auto type :
         {fcitx::EventType::InputContextUpdateUI, fcitx::EventType::InputContextFocusOut}) {
        gridEventWatchers_.push_back(instance_->watchEvent(
            type, fcitx::EventWatcherPhase::Default, [this](fcitx::Event &event) { onGridUiEvent(event); }));
    }
}

void WowtypeEngine::sendGridOverlay(fcitx::InputContext *ic, WowtypeState *state,
                                    const std::string &header) {
    const auto &all = state->candidates_;
    const std::size_t n = all.size();
    const std::size_t cursor = std::min(state->gridCursor_, n - 1);
    // 只发光标所在的这一屏（和 fillGridPanel 一样一屏 kGridRows 行）
    constexpr std::size_t perScreen = kGridCols * kGridRows;
    const std::size_t screen = cursor / perScreen;
    const std::size_t first = screen * perScreen;
    std::vector<std::string> cells;
    for (std::size_t i = first; i < std::min(n, first + perScreen); ++i) {
        cells.push_back(shownCandidate(all[i]).toString());
    }
    const OverlayCursor c = overlayCursor(ic);
    ++gridSerial_;
    auto msg = overlayBus_->createSignal(kOverlayPath, kGridInterface, "Show");
    msg.setDestination(gridOwner_);
    msg << gridSerial_ << cells << static_cast<uint32_t>(first) << static_cast<uint32_t>(cursor)
        << static_cast<uint32_t>(kGridCols) << static_cast<uint32_t>(screen)
        << static_cast<uint32_t>((n + perScreen - 1) / perScreen) << header << c.x << c.y << c.w << c.h
        << c.relative << c.scale;
    msg.send();
    gridIc_ = ic->watch();
    if (gridPendingSince_) {
        return; // 前面发的还在等回执，定时器已经开着
    }
    gridPendingSince_ = fcitx::now(CLOCK_MONOTONIC);
    if (!gridAckTimer_) {
        gridAckTimer_ = instance_->eventLoop().addTimeEvent(
            CLOCK_MONOTONIC, gridPendingSince_ + kGridAckUsec, kTimerAccuracyUsec,
            [this](fcitx::EventSourceTime *, uint64_t) {
                checkGridAck();
                return true;
            });
    } else {
        gridAckTimer_->setTime(gridPendingSince_ + kGridAckUsec);
        gridAckTimer_->setOneShot();
    }
}

void WowtypeEngine::hideGridOverlay() {
    gridIc_.unwatch();
    if (overlayBus_ && !gridOwner_.empty()) {
        auto msg = overlayBus_->createSignal(kOverlayPath, kGridInterface, "Hide");
        msg.setDestination(gridOwner_);
        msg << gridSerial_;
        msg.send();
    }
}

void WowtypeEngine::checkGridAck() {
    if (!gridPendingSince_ || gridBroken_) {
        return;
    }
    if (const uint64_t due = gridPendingSince_ + kGridAckUsec; fcitx::now(CLOCK_MONOTONIC) < due) {
        gridAckTimer_->setTime(due);
        gridAckTimer_->setOneShot();
        return;
    }
    gridBroken_ = true;
    gridPendingSince_ = 0;
    WLOG_W() << "WowType: 展开面板的网格没有回应（GNOME 扩展画的时候出错了？），改用 kimpanel 的列表";
    // 扩展要是晚一步画出来了，叫它收起；正显示着的这一屏马上换成 kimpanel 的列表
    auto *ic = gridIc_.get();
    hideGridOverlay();
    if (ic) {
        updateInputPanel(ic, ic->propertyFor(&factory_));
    }
}

void WowtypeEngine::selectGridCell(uint32_t serial, uint32_t index) {
    auto *ic = gridIc_.get();
    // 只认现在显示的这一屏上点的（点的时候面板已经变了的不算）
    if (!ic || serial != gridSerial_) {
        return;
    }
    commitCandidate(ic, ic->propertyFor(&factory_), index);
}

void WowtypeEngine::onGridUiEvent(fcitx::Event &event) {
    auto *shown = gridIc_.get();
    if (!shown || static_cast<fcitx::InputContextEvent &>(event).inputContext() != shown) {
        return;
    }
    if (event.type() == fcitx::EventType::InputContextUpdateUI) {
        const auto &update = static_cast<fcitx::InputContextUpdateUIEvent &>(event);
        if (update.component() != fcitx::UserInterfaceComponent::InputPanel ||
            dynamic_cast<WowtypeGridOverlayList *>(shown->inputPanel().candidateList().get())) {
            return; // 还是网格（光标、这一屏变了的已经发过了）
        }
    }
    hideGridOverlay();
}

void WowtypeEngine::setConfig(const fcitx::RawConfig &config) {
    config_.load(config, true);
    fcitx::safeSaveAsIni(config_, kConfigFile);
    applyConfig();
}

void WowtypeEngine::reloadConfig() {
    // 文件里没写的项回到默认值（设置界面删掉一项就是想恢复默认）
    config_ = WowtypeConfig();
    fcitx::RawConfig raw;
    fcitx::readAsIni(raw, kConfigFile);
    loadWowtypeConfig(config_, raw);
    applyConfig();
    wantedLexicon_ = resolveLexicon(*config_.lexicon);
    maybeSwitchLexicon();
    // 设置界面刚导入（或删掉）了微信输入法的模型（导入、删除完会让插件重新读设置）：要用的那份变了就载入，
    // 不用重启 fcitx5。删掉导入的以后换回安装包自带的 nnlm.bin；两份都没有时已经载入的留到下次重启。
    // 词库还在后台载入时不用管，载入那边会读到新文件
    if (core_) {
        std::string what;
        const std::string nnlm = findNnlm(what);
        const std::string stamp = nnlmStamp(nnlm);
        if (!stamp.empty() && stamp != nnlmStamp_) {
            if (wowtype_engine_load_nnlm(core_, nnlm.c_str()) > 0) {
                WLOG_I() << "WowType: 换用整句增强模型：" << what << " " << nnlm;
                nnlmStamp_ = stamp;
            } else {
                WLOG_W() << "WowType: 整句增强模型载入失败（" << what << "）" << nnlm << "："
                             << (wowtype_last_error() ? wowtype_last_error() : "unknown");
            }
        }
    }
}

void WowtypeEngine::maybeSwitchLexicon() {
    if (wantedLexicon_ == lexicon_ && fileStamp(lexicon_) == lexiconStamp_) {
        return;
    }
    if (loading_.valid()) {
        if (loading_.wait_for(std::chrono::seconds(0)) != std::future_status::ready) {
            return; // 还在载入上一个：coreReady() 载完时再来
        }
        takeLoaded();
    }
    if (core_) {
        // 新引擎载入时要读这两个文件：等写完
        maybeSaveUserDict(true, true);
    }
    // 候选、编辑区都是旧词库算出来的，先清掉
    instance_->inputContextManager().foreach([this](fcitx::InputContext *ic) {
        auto *state = ic->propertyFor(&factory_);
        state->clear();
        clearTranslation(state);
        // 会话借用引擎：先让它放开，再释放（ABI.md：引擎要比会话活得久）
        wowtype_session_set_engine(state->session_, nullptr);
        ic->inputPanel().reset();
        ic->updatePreedit();
        ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
        return true;
    });
    if (core_) {
        wowtype_engine_free(core_);
        core_ = nullptr;
        // 简繁表、五笔码表是载进这个引擎的，新引擎载好后 applyCoreSettings 再载
        conversionLoaded_ = false;
        wubiLoaded_ = false;
    }
    if (lexicon_ == wantedLexicon_) {
        WLOG_I() << "WowType: 词库文件换了，重新载入 " << lexicon_;
    } else {
        WLOG_I() << "WowType: 换词库 " << lexicon_ << " -> " << wantedLexicon_;
    }
    lexicon_ = wantedLexicon_;
    lexiconStamp_ = fileStamp(lexicon_);
    loading_ = std::async(std::launch::async, loadCore, userDictPath(), lexicon_);
}

void WowtypeEngine::applyConfig() {
    const auto envOr = [](const char *name, bool configured) {
        return envFlag(name, configured);
    };
    horizontal_ = !envOr("WOWTYPE_VERTICAL", *config_.layout == WowtypeLayout::Vertical);
    arrowKeys_ = *config_.arrowKeys;
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
                   (*config_.fuzzyUan ? 1024u : 0u) | (*config_.fuzzyUn ? 2048u : 0u) |
                   (*config_.fuzzyAnAi ? 4096u : 0u) | (*config_.fuzzyHuangWang ? 8192u : 0u) |
                   (*config_.fuzzyUnIong ? 16384u : 0u) | (*config_.fuzzyEngOng ? 32768u : 0u);
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
    pickChar_ = envOr("WOWTYPE_PICK_CHAR", *config_.pickChar);
    association_ = envOr("WOWTYPE_ASSOCIATION", *config_.association);
    typingStats_ = envOr("WOWTYPE_TYPING_STATS", *config_.typingStats);
    if (stats_) {
        // 关掉时记录器丢掉内存里还没写的计数，以后什么都不记
        wowtype_stats_set_enabled(stats_, typingStats_ ? 1 : 0);
    }
    dateTime_ = envOr("WOWTYPE_DATETIME", *config_.dateTime);
    calculator_ = envOr("WOWTYPE_CALC", *config_.calculator);
    toolbar_ = envOr("WOWTYPE_TOOLBAR", *config_.toolbar);
    clipboardHistory_ = envOr("WOWTYPE_CLIPBOARD_HISTORY", *config_.clipboardHistory);
    shuangpinShowKeys_ = *config_.shuangpinShowKeys;
    shuangpinAbbrev_ = envOr("WOWTYPE_SHUANGPIN_ABBREV", *config_.shuangpinAbbrev);
    if (!clipboardHistory_) {
        wowtype_clipboard_clear();
    }
    autoSpaceFlags_ = *config_.autoSpace ? (*config_.autoSpaceLetters ? 1 : 0) |
                                               (*config_.autoSpaceDigits ? 2 : 0)
                                         : 0;
    if (const char *env = std::getenv("WOWTYPE_AUTOSPACE"); env && *env) {
        autoSpaceFlags_ = static_cast<int>(std::strtol(env, nullptr, 0)) & 3;
    }
    autoPairPunct_ = envOr("WOWTYPE_AUTO_PAIR_PUNCT", *config_.autoPairPunct);
    typo_ = envOr("WOWTYPE_TYPO", *config_.typo);
    rareExt_ = envOr("WOWTYPE_RARE_EXT", *config_.rareExt);
    shuangpin_ = envOr("WOWTYPE_SHUANGPIN", *config_.inputScheme == WowtypeInputScheme::Shuangpin);
    shuangpinScheme_ = WowtypeShuangpinSchemeToString(*config_.shuangpinScheme);
    if (const char *env = std::getenv("WOWTYPE_SHUANGPIN_SCHEME"); env && *env) {
        // 环境变量设了方案就当作打开双拼（方便测试）
        shuangpinScheme_ = env;
        shuangpin_ = true;
    }
    // 双拼和五笔只能选一个（环境变量打开了双拼时就不是五笔）
    wubi_ = !shuangpin_ && *config_.inputScheme == WowtypeInputScheme::Wubi86;
    shiftToggle_ = *config_.shiftToggle;
    if (const char *env = std::getenv("WOWTYPE_SHIFT_TOGGLE"); env && *env) {
        const std::string name = env;
        shiftToggle_ = name == "left"    ? WowtypeShiftToggle::Left
                       : name == "right" ? WowtypeShiftToggle::Right
                       : name == "off" || name == "0" ? WowtypeShiftToggle::Off
                                                      : WowtypeShiftToggle::Both;
    }
    // 双击 Shift 不切换（#253，JetBrains 的双击 Shift）：单按先等 0.35 秒再切。设成 0 立刻切
    // （按键测试里大多数用例按这个测，见 key_harness）
    shiftDoubleTap_ = true;
    if (const char *env = std::getenv("WOWTYPE_SHIFT_DOUBLE_TAP"); env && *env) {
        const std::string value = env;
        shiftDoubleTap_ = !(value == "0" || value == "off");
    }
    toggleKey_ = *config_.toggleKey;
    translateModeKey_ = *config_.translateModeKey;
    if (!canToggleMode()) { // 切不回中文了，回到中文
        asciiMode_ = false;
        translateMode_ = false;
    }
    initialMode_ = *config_.initialMode;
    windowMode_ = *config_.windowMode;
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
        // 只建句柄：不开麦克风、不读模型，第一次按热键时才读。模型从来不在这里下载，
        // 没下载时按热键只提示去「WowType 设置 → 语音」里下载
        const char *dir = std::getenv("WOWTYPE_VOICE_MODEL_DIR");
        voice_ = wowtype_voice_new(dir);
    }
    if (voice_) {
        // 点按说话的静音超时（#285）：0 不自动结束，再点一下语音键结束
        wowtype_voice_set_silence_timeout(voice_, static_cast<unsigned>(*config_.voiceSilenceTimeout));
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
        std::string localModel;
        if (*config_.translateLocal) {
            localModel = *config_.translateLocalModel;
            if (localModel.empty()) {
                localModel = userDataDir() + "/models/HY-MT1.5-1.8B-Q4_K_M.gguf";
            }
            translateModel = "本地 HY-MT";
        }
        // 没选本地模型时传空串：不起进程、不占端口（已经起了的马上停掉）
        wowtype_translate_configure_local(
            translator_, localModel.c_str(), (*config_.translateLlamaServer).c_str(),
            static_cast<unsigned>(*config_.translateIdleMinutes) * 60u);
    }
    if (translateMode_ && !translateAvailable()) {
        translateMode_ = false;
    }

    WLOG_I() << "WowType: 设置 " << (horizontal_ ? "横排" : "竖排")
             << (arrowKeys_ == WowtypeArrowKeys::Caret ? " 左右键移光标" : "") << " 每页" << pageSize_
             << " 模糊音=" << fuzzy_ << "(" << fuzzyGroups_ << ")" << " 纠错=" << typo_ << " 扩展区生僻字=" << rareExt_ << " 双拼=" << shuangpin_
             << "(" << shuangpinScheme_ << (shuangpinAbbrev_ ? "，简拼" : "") << ")" << " 五笔=" << wubi_ << " Shift切换=" << static_cast<int>(shiftToggle_)
             << " 繁体=" << traditional_ << " 语音键=" << voiceKey_.toString()
             << " emoji推荐=" << emojiSuggest_ << " 表情键=" << emojiKey_.toString()
             << " 中英键=" << toggleKey_.toString() << " 互译键=" << translateModeKey_.toString()
             << " 选词键=" << static_cast<int>(selectKeys_) << " 日期时间=" << dateTime_
             << " 计算器=" << calculator_ << " 工具栏=" << toolbar_
             << " 剪贴板历史=" << clipboardHistory_ << " 互译=" << translateEnabled_ << "("
             << (translateAvailable() ? translateModel + " → " + translateTarget : "未配置")
             << ")"
             << " 检查更新=" << *config_.checkUpdate << " 打字统计=" << typingStats_;
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
    }
    wowtype_engine_set_shuangpin_abbrev(core_, shuangpinAbbrev_ ? 1 : 0);
    wowtype_engine_set_typo_correction(core_, typo_ ? 1 : 0);
    wowtype_engine_set_rare_ext_chars(core_, rareExt_ ? 1 : 0);
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
    if (wubi_ && !wubiLoaded_) {
        // 选了五笔才载（九万多条，约 20ms、3MB）；没有码表时会话照全拼打，候选框上方说为什么
        const std::string wubi = findDataFile("WOWTYPE_WUBI", "wubi86.tsv");
        const int loaded = wubi.empty() ? -1 : wowtype_engine_load_wubi(core_, wubi.c_str());
        if (loaded > 0) {
            wubiLoaded_ = true;
            WLOG_I() << "WowType: 载入五笔码表 " << wubi << "，" << loaded << " 条";
        } else {
            WLOG_W() << "WowType: 五笔码表载入失败 " << (wubi.empty() ? "（没有 wubi86.tsv）" : wubi)
                     << "，先按全拼打";
        }
    }

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

uint32_t WowtypeEngine::modeKeyAction(const fcitx::Key &key) const {
    auto is = [&key](const fcitx::Key &want) {
        return want.sym() != FcitxKey_None && key.checkKeyList(fcitx::KeyList{want});
    };
    return is(translateModeKey_) ? WOWTYPE_KEY_ACTION_TOGGLE_TRANSLATE
           : is(toggleKey_)      ? WOWTYPE_KEY_ACTION_TOGGLE_MODE
                                 : WOWTYPE_KEY_ACTION_NONE;
}

bool WowtypeEngine::canToggleMode() const {
    return shiftToggle_ != WowtypeShiftToggle::Off || toggleKey_.sym() != FcitxKey_None;
}

WowtypeEngine::~WowtypeEngine() {
    gridEventWatchers_.clear();
    if (gridIc_.get()) {
        hideGridOverlay();
    }
    // 退出时不能无限等（#244：桌面会话结束时 fcitx5 卡在这里，等到被 SIGTERM）。后台还在载入词库的，
    // 最多等几秒；还没好就交给一个分离的线程等它载完再释放，这里不管了（进程反正要退出）
    if (loading_.valid()) {
        if (loading_.wait_for(std::chrono::seconds(kShutdownWaitSeconds)) == std::future_status::ready) {
            takeLoaded();
        } else {
            WLOG_W() << "WowType: 退出时词库还在载入，不等了";
            std::thread([loading = std::move(loading_)]() mutable {
                const WowtypeLoaded loaded = loading.get();
                if (loaded.core) {
                    wowtype_engine_free(loaded.core);
                }
            }).detach();
        }
    }
    // 会话借用引擎和翻译器：先让它们放开，再释放（ABI.md：要比会话活得久）
    instance_->inputContextManager().foreach([this](fcitx::InputContext *ic) {
        auto *state = ic->propertyFor(&factory_);
        wowtype_session_set_translator(state->session_, nullptr);
        wowtype_session_set_engine(state->session_, nullptr);
        return true;
    });
    if (core_) {
        // 退出前把没存的交给后台存盘，最多等几秒（free 也会等写完，所以没写完时不 free：
        // 盘卡住了也别把 fcitx5 的退出拖住，进程退出时内存反正都还回去）
        maybeSaveUserDict(true, false);
        const int saved = wowtype_engine_save_wait(core_, kShutdownWaitSeconds * 1000);
        if (saved < 0) {
            WLOG_W() << "WowType: 用户词库或输入习惯保存失败："
                     << (wowtype_last_error() ? wowtype_last_error() : "unknown");
        }
        if (saved == 1) {
            WLOG_W() << "WowType: 退出时存盘 " << kShutdownWaitSeconds << " 秒还没写完，不等了";
        } else {
            wowtype_engine_free(core_);
        }
        core_ = nullptr;
    }
    if (stats_) {
        // 开着时交出最后攒着的、等写文件线程写完
        wowtype_stats_free(stats_);
        stats_ = nullptr;
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

void WowtypeEngine::takeLoaded() {
    const WowtypeLoaded loaded = loading_.get();
    core_ = loaded.core;
    userDictUnread_ = loaded.userDictUnread;
    historyUnread_ = loaded.historyUnread;
    nnlmStamp_ = loaded.nnlmStamp;
}

bool WowtypeEngine::coreReady() {
    if (core_) {
        return true;
    }
    if (loading_.valid() &&
        loading_.wait_for(std::chrono::seconds(0)) == std::future_status::ready) {
        takeLoaded();
        if (wantedLexicon_ != lexicon_ || fileStamp(lexicon_) != lexiconStamp_) {
            // 载入途中配置换了词库：这个不用了，换新的
            maybeSwitchLexicon();
            return false;
        }
        if (core_) {
            applyCoreSettings();
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

void WowtypeEngine::maybeSaveUserDict(bool force, bool wait) {
    if (!core_) {
        return;
    }
    // 存盘在核心的后台线程上（ABI 1.11）：这里只抄一份数据，不等两次 fsync。上次写失败了现在才知道：
    // 记下来，这次接着存（写的都是整份，存成了就补上了）
    if (wowtype_engine_save_wait(core_, 0) < 0) {
        WLOG_W() << "WowType: 用户词库或输入习惯保存失败："
                     << (wowtype_last_error() ? wowtype_last_error() : "unknown");
        unsavedCommits_ = std::max(unsavedCommits_, kSaveEvery);
    }
    const std::string path = userDictPath();
    if (!path.empty() && unsavedCommits_ > 0 && (force || unsavedCommits_ >= kSaveEvery)) {
        // 载入时没读出来的文件，第一次存之前先改名留着（只做一次；改不了名就先不存那个文件，下次再试）
        if (userDictUnread_ && setAsideUnreadFile(path, "用户词库")) {
            userDictUnread_ = false;
        }
        const std::string history = historyPathFor(path);
        if (historyUnread_ && (history.empty() || setAsideUnreadFile(history, "输入习惯"))) {
            historyUnread_ = false;
        }
        const bool dictQueued =
            !userDictUnread_ && wowtype_engine_save_user_dict_async(core_, path.c_str()) == 0;
        const bool historyQueued = !historyUnread_ && !history.empty() &&
                                   wowtype_engine_save_history_async(core_, history.c_str()) == 0;
        if (dictQueued && historyQueued) {
            unsavedCommits_ = 0;
        }
    }
    if (wait && wowtype_engine_save_wait(core_, -1) < 0) {
        WLOG_W() << "WowType: 用户词库或输入习惯保存失败："
                     << (wowtype_last_error() ? wowtype_last_error() : "unknown");
    }
}

bool WowtypeEngine::countLearned(const WowtypeFrame *frame) {
    if (!frame || !frame->learned || !core_) {
        return false;
    }
    ++unsavedCommits_;
    return true;
}

void WowtypeEngine::finishCommit(fcitx::InputContext *ic, WowtypeState *state,
                                 const WowtypeFrame *frame) {
    // 会话已经清空编辑区、记过选词和上文、补好了空格；这里上屏、攒着存用户词库
    const std::string text = frame && frame->commit ? frame->commit : "";
    const bool learned = countLearned(frame);
    if (ic && !text.empty()) {
        // 会话已经补好了空格；互译时攒原文也是会话做的，这里上屏的是译文、原文或不在互译时的字
        recordStats(ic, text, frame);
        ic->commitString(text);
    }
    // 会话上屏时已经清好了它上屏的那部分，这里从不 reset 会话（reset 会把还在打的丢掉）：只丢掉抄的候选，
    // 会话还在打字就重新抄（五笔顶字：首选上屏，新打的字母开始下一个码；离开「译」：拼音留着接着打）
    state->forgetCandidates();
    if (state->composing()) {
        syncView(state);
    }
    if (learned) {
        maybeSaveUserDict(false);
    }
}

void WowtypeEngine::commitInput(fcitx::InputContext *ic, WowtypeState *state) {
    if (!ic) {
        return;
    }
    finishCommit(ic, state, wowtype_session_reset(state->session_, 1));
}

void WowtypeEngine::syncSession(WowtypeState *state) {
    wowtype_session_set_engine(state->session_, core_);
    wowtype_session_set_translator(state->session_, translator_);
    WowtypeSessionConfig config{};
    config.size = sizeof(config);
    config.page_size = static_cast<uint32_t>(pageSize_);
    config.calculator = calculator_ ? 1 : 0;
    config.date_time = dateTime_ ? 1 : 0;
    config.emoji_suggest = emojiSuggest_ ? 1 : 0;
    config.horizontal = horizontal_ ? 1 : 0;
    config.arrow_keys = arrowKeys_ == WowtypeArrowKeys::Caret ? WOWTYPE_ARROW_KEYS_CARET
                                                             : WOWTYPE_ARROW_KEYS_CANDIDATES;
    config.page_keys = (pageMinus_ ? WOWTYPE_PAGE_KEYS_MINUS : 0u) |
                       (pageBracket_ ? WOWTYPE_PAGE_KEYS_BRACKET : 0u) |
                       (pageComma_ ? WOWTYPE_PAGE_KEYS_COMMA : 0u) |
                       (pageTab_ ? WOWTYPE_PAGE_KEYS_TAB : 0u);
    config.select_keys = selectKeys_ == WowtypeSelectKeys::Semicolon ? WOWTYPE_SELECT_KEYS_SEMICOLON
                         : selectKeys_ == WowtypeSelectKeys::SemicolonQuote
                             ? WOWTYPE_SELECT_KEYS_SEMICOLON_QUOTE
                             : WOWTYPE_SELECT_KEYS_OFF;
    config.pick_char = pickChar_ ? 1 : 0;
    config.punct_style = punctStyle_ == WowtypePunctStyle::Halfwidth ? 1 : 0;
    config.auto_space = static_cast<uint32_t>(autoSpaceFlags_);
    config.shift_toggle = shiftToggle_ == WowtypeShiftToggle::Left    ? WOWTYPE_SHIFT_TOGGLE_LEFT
                          : shiftToggle_ == WowtypeShiftToggle::Right ? WOWTYPE_SHIFT_TOGGLE_RIGHT
                          : shiftToggle_ == WowtypeShiftToggle::Off   ? WOWTYPE_SHIFT_TOGGLE_OFF
                                                                      : WOWTYPE_SHIFT_TOGGLE_BOTH;
    config.translate_mode = translateAvailable() ? 1 : 0;
    config.translate_key = translateModeKey_.sym() != FcitxKey_None ? 1 : 0;
    config.toolbar = toolbar_ ? 1 : 0;
    config.clipboard_history = clipboardHistory_ ? 1 : 0;
    config.shuangpin_keys = shuangpinShowKeys_ ? 1 : 0;
    config.wubi = wubi_ ? 1 : 0;
    config.wubi_auto_commit = *config_.wubiAutoCommit ? 1 : 0;
    config.wubi_hint = *config_.wubiHint ? 1 : 0;
    config.association = association_ ? 1 : 0;
    config.auto_pair_punct = autoPairPunct_ ? 1 : 0;
    // 等双击的单按在定时器（tickTranslate）、别的键的 OBSERVE（handleShiftKey）、重置（reset）里切，三处都跟上
    config.shift_double_tap = shiftDoubleTap_ ? 1 : 0;
    wowtype_session_configure(state->session_, &config);
}

const WowtypeFrame *WowtypeEngine::sessionKey(fcitx::InputContext *ic, WowtypeState *state,
                                              const fcitx::Key &key, uint32_t action) {
    coreReady();
    syncSession(state);
    syncMode(ic, state);
    uint32_t hints = 0;
    // 密码框、网址框、邮箱框不自动补空格；密码框里不翻译（「译」里也照常上屏、不往外发）
    if (!ic || ic->capabilityFlags().testAny(fcitx::CapabilityFlags{
                   fcitx::CapabilityFlag::PasswordOrSensitive, fcitx::CapabilityFlag::Url,
                   fcitx::CapabilityFlag::Email})) {
        hints |= WOWTYPE_KEY_HINT_NO_AUTO_SPACE;
    }
    if (ic && !translatable(ic)) {
        // fcitx5 的 Password / Sensitive 是这个输入框自己的能力位，确定是密码框：选的词也不学
        hints |= WOWTYPE_KEY_HINT_NO_TRANSLATE | WOWTYPE_KEY_HINT_NO_LEARN;
    }
    // 读得到周围文字时会话拿光标前的字核对自己记的上文（在应用里删过、改过就作废），
    // 自动配对拿光标后的字核对补好的右标点还在不在。这次按键开头刚挪过光标时，报来的还是挪之前的，不带
    const auto prev = surroundingStale_ ? std::nullopt : prevChar(ic);
    if (prev) {
        hints |= WOWTYPE_KEY_HINT_SURROUNDING;
    }
    const auto next = surroundingStale_ ? std::nullopt : nextChar(ic);
    if (next) {
        hints |= WOWTYPE_KEY_HINT_NEXT_CHAR;
    }
    const WowtypeFrame *frame =
        state->sessionKey(static_cast<uint32_t>(key.sym()), static_cast<uint32_t>(key.states()),
                          action, prev.value_or(0), hints, nowMs(), next.value_or(0));
    if (frame && frame->wake_after_ms > 0) {
        scheduleTick(ic, frame->wake_after_ms);
    }
    return frame;
}

std::optional<uint32_t> WowtypeEngine::prevChar(fcitx::InputContext *ic) const {
    // 应用报告了周围文字才知道光标前是什么；选中了文字时看选区前面那个字
    if (!ic || !ic->capabilityFlags().test(fcitx::CapabilityFlag::SurroundingText)) {
        return std::nullopt;
    }
    const auto &surrounding = ic->surroundingText();
    if (!surrounding.isValid()) {
        return std::nullopt;
    }
    const unsigned pos = std::min(surrounding.cursor(), surrounding.anchor());
    const std::string &before = surrounding.text();
    if (pos > fcitx::utf8::length(before)) {
        return std::nullopt;
    }
    if (pos == 0) {
        return 0;
    }
    const auto offset = fcitx::utf8::ncharByteLength(before.begin(), pos - 1);
    const uint32_t prev = fcitx::utf8::getChar(before.begin() + offset, before.end());
    return fcitx::utf8::isValidChar(prev) ? std::optional<uint32_t>(prev) : std::nullopt;
}

std::optional<uint32_t> WowtypeEngine::nextChar(fcitx::InputContext *ic) const {
    if (!ic || !ic->capabilityFlags().test(fcitx::CapabilityFlag::SurroundingText)) {
        return std::nullopt;
    }
    const auto &surrounding = ic->surroundingText();
    if (!surrounding.isValid() || surrounding.cursor() != surrounding.anchor()) {
        return std::nullopt;
    }
    const unsigned pos = surrounding.cursor();
    const std::string &text = surrounding.text();
    // 光标在报来的文字末尾不算「后面没有字」：有的应用只报光标前的字
    if (pos >= fcitx::utf8::length(text)) {
        return std::nullopt;
    }
    const auto offset = fcitx::utf8::ncharByteLength(text.begin(), pos);
    const uint32_t next = fcitx::utf8::getChar(text.begin() + offset, text.end());
    return fcitx::utf8::isValidChar(next) ? std::optional<uint32_t>(next) : std::nullopt;
}

uint32_t WowtypeEngine::keyAction(const fcitx::Key &key) const {
    const auto sym = key.sym();
    if (sym == FcitxKey_Up || sym == FcitxKey_Down || sym == FcitxKey_Left ||
        sym == FcitxKey_Right) {
        return WOWTYPE_KEY_ACTION_NONE;
    }
    const auto &global = instance_->globalConfig();
    if (key.checkKeyList(global.defaultPrevPage())) {
        return WOWTYPE_KEY_ACTION_PREV_PAGE;
    }
    if (key.checkKeyList(global.defaultNextPage())) {
        return WOWTYPE_KEY_ACTION_NEXT_PAGE;
    }
    if (key.checkKeyList(global.defaultPrevCandidate())) {
        return WOWTYPE_KEY_ACTION_PREV_CANDIDATE;
    }
    if (key.checkKeyList(global.defaultNextCandidate())) {
        return WOWTYPE_KEY_ACTION_NEXT_CANDIDATE;
    }
    return WOWTYPE_KEY_ACTION_NONE;
}

namespace {
/// 上屏以后等多久再发挪光标的键。Wayland 上上屏走 text-input、发键走虚拟键盘，同时发的话方向键常比
/// 上屏先到；下一个键来的时候不等这么久，先把攒着的发掉（别让应用先收到下一个字）。
constexpr uint64_t kCursorDelayUsec = 15000;
/// 自己给应用发键以后多久内来的重置算是应用对这几下键的反应。
constexpr uint64_t kOwnKeysResetUsec = 300000;
} // namespace

void WowtypeEngine::sendAppKeys(fcitx::InputContext *ic, fcitx::KeySym sym, int count) {
    if (!ic || count <= 0) {
        return;
    }
    // 带上 XKB 键码（evdev 的扫描码 + 8，Linux 上各种键盘布局都一样）：Electron、XWayland 这些前端
    // 不认键码为 0 的键，挪光标、删字都没反应（#259）。D-Bus 前端只看 keysym，带不带都一样
    int code = 0;
    switch (sym) {
    case FcitxKey_BackSpace: code = 22; break;
    case FcitxKey_Left: code = 113; break;
    case FcitxKey_Right: code = 114; break;
    case FcitxKey_Delete: code = 119; break;
    default: break;
    }
    const fcitx::Key key(sym, fcitx::KeyStates(), code);
    for (int i = 0; i < count; ++i) {
        ic->forwardKey(key, false);
        ic->forwardKey(key, true);
    }
    appKeysTarget_ = ic->watch();
    appKeysAtUsec_ = fcitx::now(CLOCK_MONOTONIC);
}

bool WowtypeEngine::flushCursorDelta() {
    if (cursorTimer_) {
        cursorTimer_->setEnabled(false);
    }
    const int delta = std::exchange(pendingCursorDelta_, 0);
    auto *target = cursorTarget_.get();
    if (!target || delta == 0) {
        return false;
    }
    sendAppKeys(target, delta < 0 ? FcitxKey_Left : FcitxKey_Right, delta < 0 ? -delta : delta);
    return true;
}

void WowtypeEngine::dropCursorDelta(fcitx::InputContext *ic) {
    if (cursorTarget_.get() != ic) {
        return;
    }
    if (cursorTimer_) {
        cursorTimer_->setEnabled(false);
    }
    pendingCursorDelta_ = 0;
}

void WowtypeEngine::applyCursorDelta(fcitx::InputContext *ic, const WowtypeFrame *frame,
                                     bool afterCommit) {
    if (!ic || !frame ||
        frame->size < offsetof(WowtypeFrame, cursor_delta) + sizeof(frame->cursor_delta) ||
        frame->cursor_delta == 0) {
        return;
    }
    if (cursorTarget_.get() != ic) {
        flushCursorDelta(); // 别的输入框攒着的先发掉
    }
    cursorTarget_ = ic->watch();
    pendingCursorDelta_ += frame->cursor_delta;
    const bool waiting = cursorTimer_ && cursorTimer_->isEnabled();
    if (!afterCommit) {
        // 没上屏（跳过右标点）：前面攒着的还在等上屏落到应用就一起发，不抢在前面；没有就马上发
        if (!waiting) {
            flushCursorDelta();
        }
        return;
    }
    if (!cursorTimer_) {
        cursorTimer_ = instance_->eventLoop().addTimeEvent(
            CLOCK_MONOTONIC, fcitx::now(CLOCK_MONOTONIC) + kCursorDelayUsec, kTimerAccuracyUsec,
            [this](fcitx::EventSourceTime *, uint64_t) {
                flushCursorDelta();
                return true;
            });
    } else {
        cursorTimer_->setNextInterval(kCursorDelayUsec);
    }
    cursorTimer_->setOneShot();
}

bool WowtypeEngine::pairDelete(fcitx::InputContext *ic, const WowtypeFrame *frame,
                               fcitx::KeyEvent &event) {
    if (!ic || !frame || frame->handled ||
        frame->size < offsetof(WowtypeFrame, delete_next) + sizeof(frame->delete_next) ||
        !frame->delete_next) {
        return false;
    }
    // 退格自己发，不放行：放行的退格和发的 Delete 在有的前端走两条路，先后说不准。
    // 都从 sendAppKeys 发，前面攒着的挪光标（按键开头已经发了）也在它前面
    event.filterAndAccept();
    flushCursorDelta();
    sendAppKeys(ic, FcitxKey_Delete, 1);
    sendAppKeys(ic, FcitxKey_BackSpace, 1);
    return true;
}

bool WowtypeEngine::resetFromOwnKeys(fcitx::InputContext *ic) const {
    return ic && appKeysTarget_.get() == ic && appKeysAtUsec_ != 0 &&
           fcitx::now(CLOCK_MONOTONIC) - appKeysAtUsec_ < kOwnKeysResetUsec;
}

void WowtypeEngine::applySessionFrame(fcitx::InputContext *ic, WowtypeState *state,
                                      const WowtypeFrame *frame) {
    if (frame && frame->size >= offsetof(WowtypeFrame, forgot) + sizeof(frame->forgot) &&
        frame->forgot) {
        // Ctrl+Delete 忘掉了学错的词：马上存，免得 fcitx5 退出前没存上、重启又回来
        ++unsavedCommits_;
        maybeSaveUserDict(true);
    }
    if (frame && frame->commit) {
        // 学没学到词看 frame->learned；选了 emoji 由会话记进最近用过。
        // 候选位置从 frame->choice_index 拿（1.11），统计用。
        finishCommit(ic, state, frame);
        updateInputPanel(ic, state);
        applyCursorDelta(ic, frame, true);
        return;
    }
    // 没有要上屏的字也可能学到了：「译」里选的词进了原文，不在 frame->commit 里。也记一次、攒够了存，
    // 不然只在「译」里打字的话，失去焦点、退出时一条都不存（frame 在下一次调会话前有效，先读出来）
    const bool learned = countLearned(frame);
    if (!state->composing()) {
        state->forgetCandidates();
        updateInputPanel(ic, state);
        if (learned) {
            maybeSaveUserDict(false);
        }
        applyCursorDelta(ic, frame, false);
        return;
    }
    const bool wasExpanded = state->expanded_;
    const bool recopied = syncView(state);
    if (learned) {
        maybeSaveUserDict(false);
    }
    if (recopied || wasExpanded || state->expanded_) {
        updateInputPanel(ic, state);
        return;
    }
    // 编辑区里的光标动了（左右键移进拼音，#129）：重画编辑区。只在左右键移光标时看
    //（「译」里画的是原文框和译文，光标一直在末尾）
    if (arrowKeys_ == WowtypeArrowKeys::Caret && !translating(ic) && frame && frame->preedit) {
        const fcitx::Text &shown =
            inlinePreedit(ic) ? ic->inputPanel().clientPreedit() : ic->inputPanel().preedit();
        if (shown.cursor() != frame->preedit_cursor) {
            updateInputPanel(ic, state);
            return;
        }
    }
    // 只是翻页、挪候选光标：原地摆好候选框
    if (auto *list = dynamic_cast<WowtypeSessionList *>(ic->inputPanel().candidateList().get())) {
        list->mirror(state->panelPage_, state->panelCursor_);
        ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
    } else {
        updateInputPanel(ic, state);
    }
}

bool WowtypeEngine::syncView(WowtypeState *state) {
    WowtypeSessionView view{};
    view.size = sizeof(view);
    if (wowtype_session_view(state->session_, &view) != 0) {
        return false;
    }
    const bool recopy = view.generation != state->candGeneration_;
    if (recopy) {
        refreshCandidates(state);
    }
    state->candGeneration_ = view.generation;
    state->panelPage_ = view.page;
    state->panelCursor_ = view.cursor;
    state->expanded_ = view.expanded != 0 && !state->candidates_.empty();
    state->gridCursor_ = view.grid_cursor;
    return recopy;
}

void WowtypeEngine::refreshCandidates(WowtypeState *state) {
    state->candidates_.clear();
    state->candGeneration_ = UINT64_MAX;
    state->expanded_ = false;
    state->gridCursor_ = 0;
    state->panelPage_ = 0;
    state->panelCursor_ = 0;
    const bool panelOpen = state->panel() != WOWTYPE_TOOL_NONE;
    if (!panelOpen && !state->associating() && (state->remaining().empty() || !coreReady())) {
        return;
    }
    // 候选（引擎候选 + 计算器、emoji 推荐、数字按键 emoji、日期时间，或者开着的工具栏 / 表情面板的条目）由会话算，
    // fcitx5 的候选框要整个列表，抄一份过来；点候选按这份拷贝的序号调会话
    syncSession(state);
    WowtypeSessionView view{};
    view.size = sizeof(view);
    if (wowtype_session_view(state->session_, &view) == 0) {
        state->candGeneration_ = view.generation;
        state->panelPage_ = view.page;
        state->panelCursor_ = view.cursor;
        state->gridCursor_ = view.grid_cursor;
    }
    const std::size_t total = wowtype_session_candidate_total(state->session_);
    state->candidates_.reserve(total);
    for (std::size_t i = 0; i < total; ++i) {
        WowtypeCandidateInfo info{};
        info.size = sizeof(info);
        if (wowtype_session_candidate_info(state->session_, i, &info) != 0) {
            continue;
        }
        WowtypeCandidate candidate{info.text, info.pinyin, info.consumed};
        candidate.comment = info.comment;
        candidate.plain = info.kind == WOWTYPE_CAND_PLAIN;
        if (info.kind == WOWTYPE_CAND_EMOJI) {
            candidate.emoji = true;
            candidate.commit = info.commit;
            candidate.emojiText = info.emoji;
        }
        state->candidates_.push_back(std::move(candidate));
    }
}

std::string WowtypeEngine::recentEmojiPath() const {
    const std::string dir = userDataDir();
    return dir.empty() ? std::string() : dir + "/emoji-recent.txt";
}

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

void WowtypeEngine::fillToolPanel(fcitx::InputContext *ic, WowtypeState *state) {
    // 工具栏（菜单、剪贴板、常用语）：竖排一列，一页 9 个，数字键选这一页的
    constexpr std::size_t kToolPageSize = 9;
    const std::size_t n = state->candidates_.size();
    if (n == 0) {
        return;
    }
    const std::size_t cursor = std::min(state->panelCursor_, n - 1);
    // 翻到哪一页由会话的光标定（鼠标翻页也交给会话），屏幕上的第 N 项就是按 N 选的那一项
    auto list = std::make_unique<WowtypePanelList>(this, ic, state);
    list->setLayoutHint(fcitx::CandidateLayoutHint::Vertical);
    list->setPageSize(static_cast<int>(kToolPageSize));
    list->setSelectionKey(fcitx::Key::keyListFromString("1 2 3 4 5 6 7 8 9"));
    for (std::size_t i = 0; i < n; ++i) {
        list->append<WowtypeToolWord>(this, state, i, state->candidates_[i].text);
    }
    list->place(cursor / kToolPageSize, cursor);
    ic->inputPanel().setCandidateList(std::move(list));
}

void WowtypeEngine::panelListKey(fcitx::InputContext *ic, WowtypeState *state, fcitx::KeySym sym) {
    if (!ic || !state) {
        return;
    }
    // 面板还开着才交给会话（没开着时这个键在会话里是别的意思）；不管怎样都照会话现在的样子重画
    WowtypeSessionView view{};
    view.size = sizeof(view);
    const bool expanded = state->composing() &&
                          wowtype_session_view(state->session_, &view) == 0 && view.expanded != 0;
    if (state->panel() != WOWTYPE_TOOL_NONE || expanded) {
        if (const WowtypeFrame *frame = sessionKey(ic, state, fcitx::Key(sym));
            frame && frame->handled) {
            applySessionFrame(ic, state, frame);
            return;
        }
    }
    updateInputPanel(ic, state);
}

void WowtypeEngine::choosePanelItem(fcitx::InputContext *ic, WowtypeState *state,
                                    std::size_t index) {
    // 点了工具栏 / 表情面板的一项：菜单进下一层，别的上屏（会话做，表情记进最近用过）
    if (!ic) {
        return;
    }
    if (state->panel() == WOWTYPE_TOOL_MENU) {
        sampleClipboard(ic);
    }
    const WowtypeFrame *frame = wowtype_session_choose(state->session_, index);
    if (frame && frame->handled) {
        applySessionFrame(ic, state, frame);
    }
}

/// 还没选词的拼音，按第一个用完它的候选分好音节（hengxiang -> heng'xiang）。
/// 显示的还是用户打的字母；英文、双拼等切不了的原样显示。
std::string WowtypeEngine::segmentedRemaining(WowtypeState *state) {
    // 会话的编辑区 = 已选的词 + 分好音节的剩余部分（双拼显示成全拼），这里只要后半截
    syncSession(state);
    const WowtypeFrame *frame = wowtype_session_frame(state->session_);
    const std::string selected = state->selectedText();
    const std::string shown = frame && frame->preedit ? frame->preedit : "";
    if (shown.compare(0, selected.size(), selected) == 0) {
        return shown.substr(selected.size());
    }
    return state->remaining();
}

bool WowtypeEngine::inlinePreedit(fcitx::InputContext *ic) const {
    return instance_->globalConfig().preeditEnabledByDefault() &&
           ic->capabilityFlags().test(fcitx::CapabilityFlag::Preedit);
}

void WowtypeEngine::sendPreedit(fcitx::InputContext *ic,
                                const fcitx::Text &preedit) {
    auto &panel = ic->inputPanel();
    if (inlinePreedit(ic)) {
        setClientPreedit(panel, preedit);
    } else {
        panel.setPreedit(preedit);
    }
}

void WowtypeEngine::updateInputPanel(fcitx::InputContext *ic,
                                     WowtypeState *state) {
    auto &panel = ic->inputPanel();
    panel.reset();
    state->associationShown_ = false;

    if (const int open = state->panel(); open != WOWTYPE_TOOL_NONE) {
        // 工具栏 / 表情面板：条目、光标、提示、搜索词都是会话给的
        syncView(state);
        const WowtypeFrame *frame = wowtype_session_frame(state->session_);
        fcitx::Text preedit;
        preedit.append(frame && frame->preedit ? frame->preedit : "", fcitx::TextFormatFlag::Underline);
        preedit.setCursor(static_cast<int>(preedit.textLength()));
        sendPreedit(ic, preedit);
        if (frame && frame->aux) {
            panel.setAuxUp(fcitx::Text(frame->aux));
        }
        if (!state->candidates_.empty()) {
            if (open == WOWTYPE_TOOL_EMOJI || open == WOWTYPE_TOOL_SYMBOLS) {
                fillGridPanel(ic, state);
            } else {
                fillToolPanel(ic, state);
            }
        }
        ic->updatePreedit();
        ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
        return;
    }

    const bool translate = translating(ic) && translator_;
    if (!state->composing()) {
        if (translate) {
            fillTranslateView(ic, state, panel);
        } else if (state->associating()) {
            fillAssociation(panel, state);
            state->associationShown_ = true;
        }
        ic->updatePreedit();
        ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
        return;
    }

    if (translate) {
        // 原文和拼音在候选框里，输入框里是译文
        fillTranslateView(ic, state, panel);
    } else {
        // 编辑区：已选的词 + 还没选的拼音（带下划线）；光标位置会话给（左右键能移到拼音中间，#129）
        fcitx::Text preedit;
        preedit.append(state->selectedText());
        preedit.append(segmentedRemaining(state), fcitx::TextFormatFlag::Underline);
        const WowtypeFrame *frame = wowtype_session_frame(state->session_);
        const std::size_t cursor = frame && frame->preedit ? frame->preedit_cursor : preedit.textLength();
        preedit.setCursor(static_cast<int>(std::min(cursor, preedit.textLength())));
        sendPreedit(ic, preedit);
        if (frame && frame->aux) {
            // 五笔的「空码」、选了五笔却没有码表（可以没有候选，只有这一行）
            panel.setAuxUp(fcitx::Text(frame->aux));
        }
    }

    if (state->expanded_ && !state->candidates_.empty()) {
        fillGridPanel(ic, state);
    } else if (!state->candidates_.empty()) {
        auto candidates = std::make_unique<WowtypeSessionList>(state);
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
                                                    shownCandidate(state->candidates_[i]));
        }
        // 页码和光标照会话的（展开面板里走到后面再收起时，会话翻到光标那一页）
        candidates->mirror(state->panelPage_,
                           std::min(state->panelCursor_, state->candidates_.size() - 1));
        panel.setCandidateList(std::move(candidates));
    }

    ic->updatePreedit();
    ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
}

/// 上屏以后的联想：会话给的一页，照普通候选框画，上方是会话给的提示。没按 Tab 进联想行时不画光标、
/// 不画序号（数字不选联想，照常交给应用）；进了以后光标和 1–9 照常。鼠标点了和普通候选一样走 commitCandidate。
void WowtypeEngine::fillAssociation(fcitx::InputPanel &panel, WowtypeState *state) {
    syncView(state);
    const WowtypeFrame *frame = wowtype_session_frame(state->session_);
    if (frame && frame->aux) {
        panel.setAuxUp(fcitx::Text(frame->aux));
    }
    const int cursor = frame ? frame->cand_cursor : -1;
    const std::size_t n = state->candidates_.size();
    if (n == 0) {
        return;
    }
    auto list = std::make_unique<fcitx::CommonCandidateList>();
    list->setLayoutHint(horizontal_ ? fcitx::CandidateLayoutHint::Horizontal
                                    : fcitx::CandidateLayoutHint::Vertical);
    list->setPageSize(static_cast<int>(n));
    if (cursor >= 0) {
        list->setSelectionKey(fcitx::Key::keyListFromString("1 2 3 4 5 6 7 8 9"));
    } else {
        list->setSelectionKey(fcitx::KeyList{});
    }
    for (std::size_t i = 0; i < n; ++i) {
        list->append<WowtypeCandidateWord>(this, state, i, shownCandidate(state->candidates_[i]));
    }
    if (cursor >= 0 && static_cast<std::size_t>(cursor) < n) {
        list->setGlobalCursorIndex(cursor);
    }
    panel.setCandidateList(std::move(list));
}

/// 展开的候选面板：竖排列表的每一项是一行（kGridCols 个词），一屏 kGridRows 行。
///
/// 照微信输入法的样子：光标所在行标 １–６，光标处的词用【】框起来（GNOME 的 kimpanel 只会把整行涂绿，
/// 以前的〔〕太细，一行汉字里找不到光标在哪个词上，#270）；同一屏里各列
/// 按最宽的词补齐，这样上下键在同一列里走。classic UI 和 kimpanel 都只会画一行或
/// 一列，画不了真正的网格，所以用全角字符拼出来。
void WowtypeEngine::fillGridPanel(fcitx::InputContext *ic, WowtypeState *state) {
    static const char *kLabels[] = {"\uFF11", "\uFF12", "\uFF13",
                                    "\uFF14", "\uFF15", "\uFF16"};
    static_assert(sizeof(kLabels) / sizeof(kLabels[0]) == kGridCols);
    const auto &all = state->candidates_;
    const std::size_t n = all.size();
    state->gridCursor_ = std::min(state->gridCursor_, n - 1);
    if (gridOverlay()) {
        // GNOME 扩展画真正的网格，只有光标处那一格高亮、点格子选词（#270）。本来画在 kimpanel 候选框上的
        // 提示和编辑区（应用自己不画编辑区时）挪到网格上面，kimpanel 什么都不画
        auto &panel = ic->inputPanel();
        sendGridOverlay(ic, state, panel.auxUp().toString() + panel.preedit().toString());
        panel.setAuxUp(fcitx::Text());
        panel.setPreedit(fcitx::Text());
        panel.setCandidateList(std::make_unique<WowtypeGridOverlayList>());
        return;
    }
    const std::size_t rows = (n + kGridCols - 1) / kGridCols;
    const std::size_t cursorRow = state->gridCursor_ / kGridCols;

    // 一屏一屏翻也交给会话（WowtypePanelList）：光标跟着到新的一屏，数字、空格选的是看到的这一屏
    auto list = std::make_unique<WowtypePanelList>(this, ic, state);
    list->setLayoutHint(fcitx::CandidateLayoutHint::Vertical);
    list->setPageSize(static_cast<int>(kGridRows));
    list->setSelectionKey(fcitx::KeyList{}); // 不要行号：编号画在行里
    for (std::size_t pageStart = 0; pageStart < rows; pageStart += kGridRows) {
        const std::size_t pageEnd = std::min(rows, pageStart + kGridRows);
        std::size_t widths[kGridCols] = {};
        for (std::size_t r = pageStart; r < pageEnd; ++r) {
            for (std::size_t c = 0; c < kGridCols && r * kGridCols + c < n; ++c) {
                widths[c] = std::max(widths[c], displayWidth(shownCandidate(all[r * kGridCols + c]).toString()));
            }
        }
        for (std::size_t r = pageStart; r < pageEnd; ++r) {
            fcitx::Text line;
            for (std::size_t c = 0; c < kGridCols && r * kGridCols + c < n; ++c) {
                const std::size_t index = r * kGridCols + c;
                const bool here = index == state->gridCursor_;
                const fcitx::Text shown = shownCandidate(all[index]);
                std::string after = here ? "\u3011" : "";
                padTo(after, displayWidth(shown.toString()), widths[c]);
                line.append(std::string(r == cursorRow ? kLabels[c] : "\u3000") + (here ? "\u3010" : "\u3000"));
                for (std::size_t i = 0; i < shown.size(); ++i) {
                    line.append(shown.stringAt(i), shown.formatAt(i));
                }
                line.append(after + (here ? "" : "\u3000"));
            }
            list->append<WowtypeGridRow>(this, state, r, std::move(line));
        }
    }
    // 先翻到光标所在的那一屏，下键走到第 7 行以后才看得到
    list->place(cursorRow / kGridRows, cursorRow);
    ic->inputPanel().setCandidateList(std::move(list));
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

namespace {

/// 会话第 index 个候选还是不是外壳显示的那个。
bool sameCandidate(WowtypeState *state, std::size_t index, const WowtypeCandidate &shown) {
    WowtypeCandidateInfo info{};
    info.size = sizeof(info);
    if (wowtype_session_candidate_info(state->session_, index, &info) != 0) {
        return false;
    }
    return shown.text == info.text && shown.pinyin == info.pinyin && shown.comment == info.comment &&
           shown.consumed == info.consumed && shown.plain == (info.kind == WOWTYPE_CAND_PLAIN) &&
           shown.emoji == (info.kind == WOWTYPE_CAND_EMOJI);
}

} // namespace

void WowtypeEngine::commitCandidate(fcitx::InputContext *ic,
                                    WowtypeState *state, std::size_t index) {
    if (!ic || !state || index >= state->candidates_.size()) {
        return;
    }
    if (state->panel() != WOWTYPE_TOOL_NONE) {
        choosePanelItem(ic, state, index);
        return;
    }
    // 选词、上屏、学习由会话做；外壳的候选是会话候选的一份拷贝，序号一样
    const WowtypeCandidate chosen = state->candidates_[index];
    if (!sameCandidate(state, index, chosen)) {
        // 会话的候选在显示以后变了（上文、设置、引擎变了又没刷新）：选同一个词，找不到就只刷新显示
        index = SIZE_MAX;
        const std::size_t total = wowtype_session_candidate_total(state->session_);
        for (std::size_t i = 0; i < total; ++i) {
            if (sameCandidate(state, i, chosen)) {
                index = i;
                break;
            }
        }
        if (index == SIZE_MAX) {
            refreshCandidates(state);
            updateInputPanel(ic, state);
            return;
        }
    }
    const WowtypeFrame *frame = wowtype_session_choose(state->session_, index);
    if (!frame || !frame->handled) {
        return;
    }
    if (frame->commit) {
        finishCommit(ic, state, frame);
    } else {
        // 句首词进了已选栈，剩下的拼音继续选；「译」里是选的词进了原文（没有要上屏的字，学到了照样记）
        const bool learned = countLearned(frame);
        refreshCandidates(state);
        if (learned) {
            maybeSaveUserDict(false);
        }
    }
    updateInputPanel(ic, state);
}

void WowtypeEngine::commitCurrent(fcitx::InputContext *ic, WowtypeState *state) {
    // 和按空格一样：上屏光标处的候选，没有候选时上屏原始输入
    const WowtypeFrame *frame = sessionKey(ic, state, fcitx::Key(FcitxKey_space));
    if (frame && frame->handled) {
        applySessionFrame(ic, state, frame);
    }
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
    // 上屏后还没发的挪光标（自动配对）先发：应用要先把光标放好，再收到这个键或这个键上屏的字。
    // 这时应用报的周围文字还是挪之前的
    surroundingStale_ = flushCursorDelta();
    // 联想开着时按了别的键：会话关掉了联想、键交给了应用（没有 frame 要画）时，候选框上的联想也收起来。
    // 放在最后（各条路都处理完、frame 用完以后）
    struct AfterKey {
        std::function<void()> done;
        ~AfterKey() { done(); }
    } afterKey{[this, ic, state] {
        if (state->associationShown_ && !state->associating()) {
            updateInputPanel(ic, state);
        }
    }};

    // 按键热力图：所有按键都经过这里（输入法消费掉的、还给应用的都算），松开也传，
    // 长按和合成的自动重复由核心去重。密码框在 recordKey 里排除，统计关着时什么都不做。
    recordKey(ic, event.origKey(), !event.isRelease());

    if (voice_ && handleVoiceKey(ic, state, event)) {
        return;
    }

    // 单按 Shift 切中英文（WowType 自己的英文模式），由会话判断。fcitx 的「临时切换输入法」热键
    // （默认左 Shift）生效时 fcitx 会先把 Shift 吃掉，这里就收不到，两者不会重复切换。
    if (handleShiftKey(ic, state, event)) {
        return;
    }
    if (event.isRelease()) {
        return;
    }


    if (isEmojiKey(key)) {
        // 表情面板快捷键：开着就关上；打了一半的拼音当搜索词（会话做）
        coreReady();
        syncSession(state);
        applySessionFrame(ic, state, wowtype_session_toggle_emoji_panel(state->session_));
        event.filterAndAccept();
        return;
    }
    if (const uint32_t action = modeKeyAction(key); action && state->panel() == WOWTYPE_TOOL_NONE) {
        // 另设的切换键（中 ↔ 英，在「译」里回中文）、互译键（进出「译」）：会话切；
        // 进不了「译」（没配好、密码框）时交给应用
        const WowtypeFrame *frame = sessionKey(ic, state, key, action);
        if (frame && frame->handled) {
            followSessionMode(ic, state, frame);
            event.filterAndAccept();
        }
        return;
    }
    if (state->panel() != WOWTYPE_TOOL_NONE) {
        // 工具栏 / 表情面板开着：按键都归它（会话管）；带 Ctrl / Alt / Super 的收起面板、交给应用
        if (state->panel() == WOWTYPE_TOOL_MENU) {
            sampleClipboard(ic); // 下一步可能进「剪贴板」页
        }
        const WowtypeFrame *frame = sessionKey(ic, state, key);
        if (frame && frame->handled) {
            applySessionFrame(ic, state, frame);
            event.filterAndAccept();
        } else {
            updateInputPanel(ic, state);
        }
        return;
    }

    // 互译模式、没在打拼音：回车上屏译文、Shift+回车上屏原文、Esc 清空、退格删原文、数字和符号进原文……
    // 都由会话处理
    if (translating(ic) && !state->composing() && !key.states().testAny(fcitx::KeyStates{
                                                      fcitx::KeyState::Ctrl, fcitx::KeyState::Alt,
                                                      fcitx::KeyState::Super})) {
        if (const WowtypeFrame *frame = sessionKey(ic, state, key); frame && frame->handled) {
            applySessionFrame(ic, state, frame);
            event.filterAndAccept();
            return;
        }
    }

    // 英文模式：按键原样交给应用（字母、半角标点都直接上屏）；汉字后面打字母、数字要补空格时
    // 会话连空格一起上屏
    if (asciiMode_ && !state->composing()) {
        if (const WowtypeFrame *frame = sessionKey(ic, state, key); frame && frame->handled) {
            applySessionFrame(ic, state, frame);
            event.filterAndAccept();
        } else {
            pairDelete(ic, frame, event); // 括号里切到英文打了字又删到空：两个一起删
        }
        return;
    }

    // 带 Ctrl/Alt/Super 的组合键先问会话：打字途中 Ctrl+Delete、Ctrl+退格忘掉光标处学错的词；
    // 别的交给应用或 fcitx 的其他处理器（没在打字时会话借这一下知道应用里的字可能变了）
    if (key.states().testAny(fcitx::KeyStates{fcitx::KeyState::Ctrl, fcitx::KeyState::Alt,
                                              fcitx::KeyState::Super})) {
        if (const WowtypeFrame *frame = sessionKey(ic, state, key); frame && frame->handled) {
            applySessionFrame(ic, state, frame);
            event.filterAndAccept();
        }
        return;
    }

    if (state->composing()) {
        // 只打了一个 v 再按空格打开工具栏：会话做（剪贴板页要的历史先读一次）
        if (sym == FcitxKey_space && state->input() == "v") {
            sampleClipboard(ic);
        }
        // 字母、隔音符、退格、Esc、空格、回车、数字、分号引号选词、V 模式算式、双拼分号、
        // 翻页、移动候选、展开面板都由会话处理。fcitx5 全局设置里的翻页、移动候选热键
        // （[Hotkey/PrevPage] 等，比如 , . 翻页）翻成动作一起交给会话：按了就算翻不动也吃掉，
        // 不让它变成标点把字上屏
        const bool wasExpanded = state->expanded_;
        const WowtypeFrame *frame = sessionKey(ic, state, key, keyAction(key));
        if (frame && frame->handled) {
            applySessionFrame(ic, state, frame);
            event.filterAndAccept();
            return;
        }
        if (wasExpanded) {
            // 展开面板里按了会话不管的键（标点、Home……）：面板已经收起，重画再照常处理
            syncView(state);
            updateInputPanel(ic, state);
        }

        // 标点、符号（先上屏候选再上屏标点）也由会话处理了。会话不管的键（Home / End / Delete / Tab、
        // 小键盘的 + - * / .、F1–F12、Insert、不是 ASCII 的键……）都吃掉：编辑区里的字还没上屏，
        // 这时交给应用，应用里的光标会乱跑，小键盘的 + 排到「你好」前面，F5 把网页刷新掉。
        // 修饰键、锁定键本身照常交给应用（按住 Ctrl 再按别的键、大写锁定），不然应用里对不上按下和松开
        if (!passesWhileComposing(sym)) {
            event.filterAndAccept();
        }
        return;
    }

    // 没在打字时也交给会话：字母（大写原样保留，Hello、iPhone 要用到）开始编辑区；
    // 标点换成中文标点（半角样式、数字写法里的符号、没有中文写法的 / + 交给应用）；
    // 汉字后面打数字要补空格时会话自己上屏（第5章）
    if (const WowtypeFrame *frame = sessionKey(ic, state, key); frame && frame->handled) {
        applySessionFrame(ic, state, frame);
        event.filterAndAccept();
    } else {
        pairDelete(ic, frame, event); // 自动配对：空的一对按退格，两个一起删
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
    // 从别的输入法切回来（不是换窗口获得焦点）、启动后第一次用：按「切到 WowType 时」定中 / 英
    // （#158：切走时是英文，切回来还是英文，打不了中文）。换窗口默认不动，模式照旧全局保持；
    // 进出密码框时 fcitx5 自己换成键盘布局再换回来（CapabilityChanged），也不算用户切回来。
    bool switchedBack = false;
    if (event.type() == fcitx::EventType::InputContextSwitchInputMethod) {
        const auto &switched = static_cast<fcitx::InputContextSwitchInputMethodEvent &>(event);
        switchedBack = switched.reason() != fcitx::InputMethodSwitchedReason::CapabilityChanged;
    }
    if (switchedBack || !initialModeApplied_) {
        initialModeApplied_ = true;
        applyInitialMode(ic, state);
    }
    // 换窗口、换应用获得焦点：设了「默认中/英文」就定一次（#254；默认和上次一样，不动）。
    // 切换输入法的事件优先，别让两边抢着定。
    if (!switchedBack && event.type() == fcitx::EventType::InputContextFocusIn) {
        applyWindowMode(ic, state);
    }
    // 最近用过的 emoji 在核心里（所有输入框共用），存在 ~/.local/share/wowtype/emoji-recent.txt
    wowtype_recent_emoji_path(recentEmojiPath().c_str());
    sampleClipboard(ic);
    maybeCheckUpdate();
}

/// 后台的小事交给设置界面（wowtype-config --startup）：第一次用时打开 WowType 主题、
/// 检查更新（它自己看「自动检查更新」开关，最多一小时查一次，有新版本时发桌面通知）。
/// 插件这边在切到 WowType 时叫它，同一个 fcitx5 进程里最多一小时叫一次。
void WowtypeEngine::maybeCheckUpdate() {
#ifdef WOWTYPE_CONFIG_TOOL
    if (std::getenv("WOWTYPE_NO_UPDATE_CHECK")) {
        return;
    }
    const auto nowTime = std::chrono::steady_clock::now();
    if (updateCheckedAt_ && nowTime - *updateCheckedAt_ < std::chrono::hours(1)) {
        return;
    }
    updateCheckedAt_ = nowTime;
    std::error_code ec;
    if (std::filesystem::exists(WOWTYPE_CONFIG_TOOL, ec)) {
        fcitx::startProcess({WOWTYPE_CONFIG_TOOL, "--startup"});
    }
#endif
}

void WowtypeEngine::deactivate(const fcitx::InputMethodEntry &entry,
                               fcitx::InputContextEvent &event) {
    // 打到一半切换输入法（比如按 Shift 切英文）：已选的词 + 原始字母原样上屏，
    // 不要把用户打的东西吞掉。失去焦点时放弃（reset）：这时再上屏，Qt 会送进新拿到焦点的控件，
    // XIM 的应用收不到；编辑区标了 DontCommit，工具包自己也不上屏。
    if (auto *ic = event.inputContext();
        ic && event.type() == fcitx::EventType::InputContextSwitchInputMethod) {
        auto *state = ic->propertyFor(&factory_);
        // 互译时拼音先进原文，攒着的原文再原样上屏（会话做）
        finishCommit(ic, state, wowtype_session_reset(state->session_, 1));
    }
    if (voiceActive() && voiceIc_.get() == event.inputContext()) {
        cancelVoice();
    }
    // 按住语音键时焦点切走（或者换了输入法）：松开的那一下到不了这里。不清掉的话，回来后第一次按语音键
    // 会被当成还按着时的自动重复吃掉，没有反应
    voiceKeyDown_ = false;
    reset(entry, event);
    maybeSaveUserDict(true);
    flushStats();
}

void WowtypeEngine::reset(const fcitx::InputMethodEntry & /*entry*/,
                          fcitx::InputContextEvent &event) {
    auto *ic = event.inputContext();
    if (!ic) {
        return;
    }
    if (event.type() == fcitx::EventType::InputContextReset && resetFromOwnKeys(ic)) {
        // 自动配对刚给应用发了方向键、Delete、退格，GTK 挪光标、删字时会重置输入法：
        // 光标是自己挪的，配对、上文、刚开始打的拼音都还算数
        return;
    }
    // 光标去了别处：还没发的挪光标不发了，之后的重置也不再当成是自己发的键引起的
    dropCursorDelta(ic);
    if (appKeysTarget_.get() == ic) {
        appKeysAtUsec_ = 0;
    }
    // 原文和拼音一样只在输入法里：应用重置输入框（点了别处、失去焦点）就丢掉，
    // 会话记的上文也作废（回来时光标可能在别处）。编辑区标了 DontCommit，工具包不会自己上屏。
    auto *state = ic->propertyFor(&factory_);
    if (state->clear()) {
        // 单按 Shift 还在等双击时输入框重置了（点了别处、换了窗口）：那一下照切，全局模式跟上（不弹提示）
        const int mode = wowtype_session_mode(state->session_);
        switchMode(ic, state, mode == WOWTYPE_MODE_ENGLISH, mode == WOWTYPE_MODE_TRANSLATE, false);
    }
    clearTranslation(state);
    ic->inputPanel().reset();
    ic->updatePreedit();
    ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
}

const char *WowtypeEngine::modeTitle() const {
    return translateMode_ ? "互译" : asciiMode_ ? "英文" : "中文";
}

const char *WowtypeEngine::modeLabel() const {
    return translateMode_ ? "译" : asciiMode_ ? "英" : "中";
}

std::string WowtypeEngine::subMode(const fcitx::InputMethodEntry & /*entry*/,
                                   fcitx::InputContext & /*ic*/) {
    return modeTitle();
}

std::string WowtypeEngine::subModeLabelImpl(const fcitx::InputMethodEntry & /*entry*/,
                                            fcitx::InputContext & /*ic*/) {
    // 中文也要给：给空的话切回中文时提示框、托盘写的是输入法的名字「WowType」，和「英」「译」对不上
    return modeLabel();
}

/// 按下 Shift 记下来，松开时中间没按别的键（也没按太久）就切中英文。
bool WowtypeEngine::handleShiftKey(fcitx::InputContext *ic, WowtypeState *state,
                                   fcitx::KeyEvent &event) {
    coreReady();
    syncSession(state);
    syncMode(ic, state);
    const fcitx::Key key = event.key();
    const auto sym = key.sym();
    const bool isShift = sym == FcitxKey_Shift_L || sym == FcitxKey_Shift_R;
    WowtypeKey raw{};
    raw.size = sizeof(raw);
    raw.keysym = static_cast<uint32_t>(sym);
    raw.modifiers = static_cast<uint32_t>(key.states());
    raw.release = event.isRelease() ? 1 : 0;
    // 别的键只报给会话（按住 Shift 时按了它，这一下就不算单按），不让会话处理
    raw.action = isShift ? WOWTYPE_KEY_ACTION_NONE : WOWTYPE_KEY_ACTION_OBSERVE;
    // 松开时按键码认：xkb 选项（比如 grp:shifts_toggle）或 fcitx5 按输入法布局重新翻译时，
    // 松开那一下 Shift 可能翻成别的符号（ISO_Next_Group 等）
    raw.code = static_cast<uint32_t>(event.origKey().code());
    // 按住不放的自动重复不重新计时（key() 规整时去掉了 Repeat，要看 rawKey）
    raw.repeat = event.rawKey().states().test(fcitx::KeyState::Repeat) ? 1 : 0;
    raw.time_ms = static_cast<uint64_t>(fcitx::now(CLOCK_MONOTONIC) / 1000);
    const bool wasExpanded = state->expanded_;
    const WowtypeFrame *frame = wowtype_session_key(state->session_, &raw);
    if (isShift && frame && frame->wake_after_ms > 0) {
        // 单按 Shift 等双击（#253）：到时间没有第二下就在 tickTranslate 里切
        scheduleTick(ic, frame->wake_after_ms);
    }
    if (!frame || !frame->mode_changed) {
        if (isShift) {
            // Shift 只走这一条路（再交给会话一次会把按下的时刻、键码冲掉）。展开面板里按下 Shift：
            // 会话已经把面板收起来了，重画；Shift 本身交给应用
            if (wasExpanded) {
                syncView(state);
                updateInputPanel(ic, state);
            }
            return true;
        }
        return false;
    }
    followSessionMode(ic, state, frame);
    if (!isShift) {
        // 等双击的单按被这个键打断（#253）：上面先切了，这个键照切了以后的模式接着处理
        return false;
    }
    // 这一下是松开 Shift（切了模式）：不接受，照常交给应用。外壳只在输入法没接受的时候才把键
    // 转给应用（Wayland 上经 KWin 的虚拟键盘），吞掉松开的 Shift，应用会以为它还按着：之后
    // shift+单击开新窗口、滚轮变横向、快捷键错乱（#225）。按下那一下本来就没接受（见上），
    // 单独按下、松开 Shift 不出字，交给应用不会多打东西。
    event.filter();
    return true;
}

void WowtypeEngine::followSessionMode(fcitx::InputContext *ic, WowtypeState *state,
                                      const WowtypeFrame *frame) {
    // 打到一半切英文：已选的词 + 打的字母原样上屏；离开「译」：原文原样上屏、拼音留着（会话已经放进 frame）
    const int mode = frame->mode;
    const bool committed = frame->commit != nullptr;
    if (committed) {
        finishCommit(ic, state, frame);
    } else {
        countLearned(frame);
    }
    switchMode(ic, state, mode == WOWTYPE_MODE_ENGLISH, mode == WOWTYPE_MODE_TRANSLATE, true);
    if (committed || state->composing()) {
        // 换好模式再画：离开「译」以后留着的拼音照普通的编辑区画，不再画成互译的原文框；
        // 带进「译」的拼音画成原文框
        updateInputPanel(ic, state);
    }
}

void WowtypeEngine::applyInitialMode(fcitx::InputContext *ic, WowtypeState *state) {
    if (initialMode_ == WowtypeInitialMode::Last) {
        return;
    }
    // 切不回中文时不进英文
    const bool english = initialMode_ == WowtypeInitialMode::English && canToggleMode();
    if (english == asciiMode_ && !translateMode_) {
        return;
    }
    switchMode(ic, state, english, false, false);
}

void WowtypeEngine::applyWindowMode(fcitx::InputContext *ic, WowtypeState *state) {
    if (windowMode_ == WowtypeWindowMode::Same) {
        return;
    }
    // 和 applyInitialMode 一样：切不回中文时不进英文；「译」里换窗口也回到默认的中 / 英
    const bool english = windowMode_ == WowtypeWindowMode::English && canToggleMode();
    if (english == asciiMode_ && !translateMode_) {
        return;
    }
    switchMode(ic, state, english, false, false);
}

void WowtypeEngine::syncMode(fcitx::InputContext *ic, WowtypeState *state) {
    // 中 / 英 / 译是全局的（在一个应用里切了，别的应用里也是）；会话每个输入框一份，按键前对齐
    const int want = translateMode_ ? WOWTYPE_MODE_TRANSLATE
                     : asciiMode_   ? WOWTYPE_MODE_ENGLISH
                                    : WOWTYPE_MODE_CHINESE;
    if (wowtype_session_mode(state->session_) == want) {
        return;
    }
    auto set = [&](int mode) {
        const WowtypeFrame *frame = wowtype_session_set_mode(state->session_, mode);
        if (frame && frame->commit && ic) {
            finishCommit(ic, state, frame);
            updateInputPanel(ic, state);
        } else {
            countLearned(frame);
        }
    };
    if (want == WOWTYPE_MODE_TRANSLATE) {
        // 别的输入框里进的「译」：会话先到进「译」前的模式，在这里按互译键也回得去
        set(translateFrom_);
    }
    set(want);
}

void WowtypeEngine::switchMode(fcitx::InputContext *ic, WowtypeState *state, bool ascii,
                               bool translate, bool notify) {
    // 离开「译」时攒着的原文原样上屏：会话做（下面 syncMode 切会话的模式时放进 frame）
    if (ascii && !asciiMode_ && ic && state && state->composing()) {
        // 打到一半切英文：已选的词 + 打的字母原样上屏（和微信输入法一样）
        commitInput(ic, state);
        updateInputPanel(ic, state);
    }
    if (translate && !translateMode_) {
        translateFrom_ = asciiMode_ ? WOWTYPE_MODE_ENGLISH : WOWTYPE_MODE_CHINESE;
    }
    asciiMode_ = ascii;
    translateMode_ = translate;
    if (state) {
        syncMode(ic, state);
    }
    WLOG_I() << "WowType: 切到" << modeTitle();
    if (!ic) {
        return;
    }
    if (notify) {
#ifdef WOWTYPE_HAVE_CUSTOM_IM_INFO
        std::string label = modeLabel();
        if (translateMode_ && translator_) {
            label += " ";
            label += wowtype_translate_tag(translator_, "");
        }
        instance_->showCustomInputMethodInformation(ic, label);
#else
        instance_->showInputMethodInformation(ic);
#endif
    }
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
    checkOverlayAck(ic);
    const int phase = wowtype_voice_poll(voice_);
    const std::string text = wowtype_voice_text(voice_);
    switch (phase) {
    case WOWTYPE_VOICE_LISTENING: {
        const int level = wowtype_voice_level(voice_);
        if (voiceOverlay()) {
            // 浮条由 GNOME 扩展画，这里只留编辑区里识别到一半的字
            showVoice(ic, {}, text);
            sendVoiceOverlay(ic, kOverlayListening, "正在听…", level);
            return true;
        }
        // 不写字，只画麦克风 + 跟着音量滚动的波形
        voiceLevels_.push_back(level);
        if (voiceLevels_.size() > kVoiceBars) {
            voiceLevels_.erase(voiceLevels_.begin());
        }
        showVoice(ic, "🎙 " + voiceWave(voiceLevels_) + " ", text);
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
    case WOWTYPE_VOICE_RESULT: {
        clearVoice(true);
        // 和工具栏、表情面板上屏的一样交给会话：补空格、记上文，互译时进原文
        auto *state = ic->propertyFor(&factory_);
        coreReady();
        syncSession(state);
        finishCommit(ic, state,
                     wowtype_session_commit_text(state->session_, text.c_str(),
                                                 prevChar(ic).value_or(0)));
        // 上屏以后再复制，复制不成也不影响上屏；密码框里说的话不进剪贴板
        if (voiceCopy_ && !ic->capabilityFlags().testAny(fcitx::CapabilityFlag::PasswordOrSensitive) &&
            !wowtype::copyToClipboard(text)) {
            WLOG_I() << "WowType: 没能复制到剪贴板（要装 wl-clipboard，X11 下装 xclip 或 xsel）";
        }
        if (translating(ic)) {
            // 互译模式：说的话进了原文
            updateInputPanel(ic, state);
        }
        return false;
    }
    case WOWTYPE_VOICE_ERROR:
        WLOG_I() << "WowType: 语音 " << text;
        voiceErrorText_ = text;
        if (voiceOverlay()) {
            showVoice(ic, {}, {});
            sendVoiceOverlay(ic, kOverlayError, text, 0);
        } else {
            showVoice(ic, "🎙 " + text, {});
        }
#ifdef WOWTYPE_CONFIG_TOOL
        // 没下载模型：提示只有几秒、点不了，直接把设置界面的「语音」页打开（那里有下载按钮）。
        // 一次运行里只开一次，不想用语音的人误按语音键不会被反复打扰；测试里不开
        if (static bool opened = false;
            !opened && wowtype_voice_model_state(voice_) == WOWTYPE_VOICE_MODEL_MISSING &&
            !std::getenv("WOWTYPE_NO_UPDATE_CHECK")) {
            opened = true;
            std::error_code ec;
            if (std::filesystem::exists(WOWTYPE_CONFIG_TOOL, ec)) {
                fcitx::startProcess({WOWTYPE_CONFIG_TOOL, "--page", "voice"});
            }
        }
#endif
        // 没下载模型的提示要去设置里操作，多留一会儿让人看清
        voiceErrorUntil_ = fcitx::now(CLOCK_MONOTONIC) +
                           (wowtype_voice_model_state(voice_) == WOWTYPE_VOICE_MODEL_MISSING
                                ? kVoiceHintUsec
                                : kVoiceErrorUsec);
        return true;
    default:
        if (voiceErrorUntil_ && fcitx::now(CLOCK_MONOTONIC) < voiceErrorUntil_) {
            // 浮条 1.5 秒收不到信号会自己收起：提示要留得更久时接着发
            if (voiceOverlay()) {
                sendVoiceOverlay(ic, kOverlayError, voiceErrorText_, 0);
            }
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
        const WowtypeFrame *frame = wowtype_session_frame(state->session_);
        const std::string source = frame && frame->translating ? frame->translate_source : "";
        const std::string translated = frame && frame->translating ? frame->translate_text : "";
        fcitx::Text box;
        box.append(source);
        box.append(partial, fcitx::TextFormatFlag::Underline);
        box.setCursor(static_cast<int>(box.textLength()));
        panel.setPreedit(box);
        if (inlinePreedit(ic) && !translated.empty()) {
            fcitx::Text shown;
            shown.append(translated, fcitx::TextFormatFlag::Underline);
            shown.setCursor(static_cast<int>(shown.textLength()));
            setClientPreedit(panel, shown);
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
    overlaySentAt_ = 0;
    overlayAcked_ = false;
    voiceLevels_.clear();
    voiceFrame_ = 0;
    voiceErrorUntil_ = 0;
    voiceErrorText_.clear();
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
// 照微信输入法的样子：打的字（选好的词、标点、语音识别结果）攒成原文，显示在候选框里
// （当原文框用），不交给应用；原文停下来 0.5 秒（句末标点立刻）就发请求，译文边出边写在
// 应用的输入框里（编辑区，带下划线）。回车 / 空格上屏译文，Shift+回车上屏原文，Esc 清空。
// 这些都在会话里（wowtype_session_tick 等），外壳只画、排定时器（会话的 wake_after_ms）。

bool WowtypeEngine::translateAvailable() const {
    return translateEnabled_ && translator_ && wowtype_translate_ready(translator_) == 1;
}

bool WowtypeEngine::translating(fcitx::InputContext *ic) const {
    return translateMode_ && translator_ && translatable(ic);
}

bool WowtypeEngine::translatable(fcitx::InputContext *ic) {
    // 密码框之类：照常打中文，不往外发
    if (!ic) {
        return false;
    }
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

void WowtypeEngine::clearTranslation(WowtypeState *state) {
    // 丢掉攒着的原文、取消这个输入框的请求（会话做）
    wowtype_session_translate_clear(state->session_);
    if (translateIc_.get() && translateIc_.get()->propertyFor(&factory_) == state) {
        translateDrawn_.clear();
    }
}

namespace {
/// 密码框、敏感输入框（Password / Sensitive 任一位）：打字统计整个不算。
unsigned statsFlags(fcitx::InputContext *ic) {
    return !ic || ic->capabilityFlags().testAny(fcitx::CapabilityFlag::PasswordOrSensitive)
               ? WOWTYPE_STATS_SENSITIVE
               : 0u;
}
} // namespace

void WowtypeEngine::recordStats(fcitx::InputContext *ic, const std::string &text,
                                const WowtypeFrame *frame) {
    // 关着时核心什么都不做；这里先挡一下，省得算模式名
    if (!stats_ || !typingStats_ || text.empty()) {
        return;
    }
    const std::string src = typingSource();
    const std::string scheme = shuangpin_ && !translateMode_ && !asciiMode_ ? typingScheme() : std::string();
    unsigned candidate = frame ? static_cast<unsigned>(frame->choice_index) : 0;
    if (src == "translate") {
        candidate = 0; // 互译上屏的不是候选
    }
    // 文字只交给核心数各类字符有几个，核心不留下；密码框里的整个不算
    wowtype_stats_commit(stats_, text.c_str(), src.c_str(), scheme.empty() ? nullptr : scheme.c_str(),
                         static_cast<int>(candidate), statsFlags(ic), statsNowMs());
}

void WowtypeEngine::recordKey(fcitx::InputContext *ic, const fcitx::Key &key, bool down) {
    if (!stats_ || !typingStats_ || !ic) {
        return;
    }
    // 只记哪个物理键按了一次（当天的次数），不记顺序和时刻；密码框里的不算
    wowtype_stats_key(stats_, 0, static_cast<unsigned>(key.code()), down ? 1 : 0, statsFlags(ic),
                      statsNowMs());
}

void WowtypeEngine::flushStats() {
    if (stats_ && typingStats_) {
        // 交给核心的写文件线程，这里不等
        wowtype_stats_flush(stats_, statsNowMs());
    }
}

std::string WowtypeEngine::typingSource() const {
    if (translateMode_) {
        return "translate";
    }
    if (asciiMode_) {
        return "english";
    }
    if (wubi_) {
        return "wubi";
    }
    return shuangpin_ ? "shuangpin" : "quanpin";
}

std::string WowtypeEngine::typingScheme() const {
    std::string id = shuangpinScheme_;
    for (char &ch : id) {
        if (ch >= 'A' && ch <= 'Z') {
            ch = static_cast<char>(ch - 'A' + 'a');
        }
    }
    return id;
}

uint64_t WowtypeEngine::nowMs() {
    return static_cast<uint64_t>(fcitx::now(CLOCK_MONOTONIC) / 1000);
}

void WowtypeEngine::scheduleTick(fcitx::InputContext *ic, uint32_t ms) {
    if (!ic) {
        return;
    }
    if (translateIc_.get() != ic) {
        translateIc_ = ic->watch();
    }
    const uint64_t at = fcitx::now(CLOCK_MONOTONIC) + static_cast<uint64_t>(ms) * 1000;
    if (!translateTimer_) {
        translateTimer_ = instance_->eventLoop().addTimeEvent(
            CLOCK_MONOTONIC, at, kTimerAccuracyUsec,
            [this](fcitx::EventSourceTime *source, uint64_t) {
                const uint32_t next = tickTranslate();
                if (next > 0) {
                    source->setNextInterval(static_cast<uint64_t>(next) * 1000);
                    source->setOneShot();
                }
                return true;
            });
    } else {
        translateTimer_->setTime(at);
        translateTimer_->setOneShot();
    }
}

uint32_t WowtypeEngine::tickTranslate() {
    auto *ic = translateIc_.get();
    if (!ic) {
        return 0;
    }
    auto *state = ic->propertyFor(&factory_);
    syncSession(state);
    const WowtypeFrame *frame = wowtype_session_tick(state->session_, nowMs());
    if (!frame) {
        return 0;
    }
    if (frame->mode_changed) {
        // 单按 Shift 等双击等到了时间（#253）：现在切，弹「中 / 英」提示（打到一半切英文时字母在 frame 里）
        const uint32_t wake = frame->wake_after_ms;
        followSessionMode(ic, state, frame);
        return wake;
    }
    if (frame->commit) {
        // 按过回车，译好了：上屏译文（正在打的拼音留着，不清编辑区）
        recordStats(ic, frame->commit, frame);
        ic->commitString(frame->commit);
        translateDrawn_.clear();
        updateInputPanel(ic, state);
        return frame->wake_after_ms;
    }
    // 结果变了才重画；只换编辑区和提示行：正在打拼音时候选列表（和翻到的页、光标）不动
    if (translating(ic) && translateSignature(frame) != translateDrawn_) {
        fillTranslateView(ic, state, ic->inputPanel());
        ic->updatePreedit();
        ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
    }
    return frame->wake_after_ms;
}

std::string WowtypeEngine::translateSignature(const WowtypeFrame *frame) const {
    if (!frame || !frame->translating) {
        return {};
    }
    return std::string(frame->translate_source) + "|" + frame->translate_text + "|" +
           frame->translate_status + "|" + frame->translate_title + "|" +
           std::to_string(frame->translate_done);
}

void WowtypeEngine::fillTranslateView(fcitx::InputContext *ic, WowtypeState *state,
                                      fcitx::InputPanel &panel) {
    const WowtypeFrame *frame = wowtype_session_frame(state->session_);
    if (!frame || !frame->translating) {
        return;
    }
    translateDrawn_ = translateSignature(frame);
    if (frame->wake_after_ms > 0) {
        scheduleTick(ic, frame->wake_after_ms);
    }
    const std::string source = frame->translate_source;
    if (source.empty() && !state->composing()) {
        return;
    }
    // 原文框：攒着的原文 + 已选的词 + 还没选的拼音
    fcitx::Text box;
    box.append(source);
    if (state->composing()) {
        box.append(state->selectedText());
        box.append(segmentedRemaining(state), fcitx::TextFormatFlag::Underline);
    }
    box.setCursor(static_cast<int>(box.textLength()));
    panel.setPreedit(box);
    panel.setAuxUp(fcitx::Text(frame->translate_title));

    // 底下一行：状态，或者怎么上屏
    std::string status = frame->translate_status;
    const std::string shown = frame->translate_text;
    if (inlinePreedit(ic)) {
        fcitx::Text text;
        text.append(shown, fcitx::TextFormatFlag::Underline);
        text.setCursor(static_cast<int>(text.textLength()));
        setClientPreedit(panel, text);
    } else if (!shown.empty()) {
        // 应用不让把编辑区画在输入框里：译文写在候选框底下
        status = shown + (frame->translate_done ? "" : "…");
    }
    panel.setAuxDown(fcitx::Text(status));
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
