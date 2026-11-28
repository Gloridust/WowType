#include "engine_host.h"

#include <shlobj.h>

#include <algorithm>
#include <ctime>
#include <fstream>
#include <iterator>
#include <vector>

#include "../win/updater.h"
#include "globals.h"

#ifndef WOWTYPE_VERSION
#define WOWTYPE_VERSION "dev"
#endif
#define WOWTYPE_WIDEN2(x) L##x
#define WOWTYPE_WIDEN(x) WOWTYPE_WIDEN2(x)
#define WOWTYPE_WIDE_VERSION WOWTYPE_WIDEN(WOWTYPE_VERSION)

namespace wowtype::tsf {

namespace {

/// 学到了词以后最多隔这么久存一次（毫秒）。Linux、macOS 是一个输入法进程，攒 20 次上屏再存；Windows 上每个应用
/// 进程各有一个引擎，学到的要尽快写下去，别的应用下一次按键时合并进来（mergeLearning），学到的词才几秒内各处都有。
/// 写文件在核心的存盘线程上，不挡打字。
constexpr ULONGLONG kSaveAfterMs = 2000;
/// 翻页时一个音节的字要列全（yi 有八百多个字），候选上限给 1000（和 macOS 一样）。
constexpr unsigned kMaxCandidates = 1000;

bool sameStamp(const FILETIME &a, const FILETIME &b) {
    return a.dwLowDateTime == b.dwLowDateTime && a.dwHighDateTime == b.dwHighDateTime;
}

std::string readFileUtf8(const std::wstring &path, bool &ok) {
    std::ifstream in(path, std::ios::binary);
    ok = static_cast<bool>(in);
    if (!ok) {
        return {};
    }
    std::string text((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    // 记事本存的 UTF-8 可能带 BOM
    if (text.size() >= 3 && static_cast<unsigned char>(text[0]) == 0xEF && static_cast<unsigned char>(text[1]) == 0xBB &&
        static_cast<unsigned char>(text[2]) == 0xBF) {
        text.erase(0, 3);
    }
    return text;
}

/// 把开头的 ~\ 或 ~/ 换成用户目录（设置里常这么写，和另两端一样）。
std::wstring expandHome(const std::wstring &path) {
    if (path.size() >= 2 && path[0] == L'~' && (path[1] == L'/' || path[1] == L'\\')) {
        wchar_t *profile = nullptr;
        if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_Profile, 0, nullptr, &profile))) {
            std::wstring out = std::wstring(profile) + L"\\" + path.substr(2);
            CoTaskMemFree(profile);
            return out;
        }
    }
    return path;
}

} // namespace

FILETIME fileStamp(const std::wstring &path) {
    WIN32_FILE_ATTRIBUTE_DATA info{};
    if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &info)) {
        return FILETIME{};
    }
    return info.ftLastWriteTime;
}

bool fileExists(const std::wstring &path) {
    const DWORD attrs = GetFileAttributesW(path.c_str());
    return attrs != INVALID_FILE_ATTRIBUTES && !(attrs & FILE_ATTRIBUTE_DIRECTORY);
}

EngineHost &EngineHost::instance() {
    // 故意不析构：核心有自己的线程（存盘、翻译），DLL 一旦载入引擎就钉住不卸载（见 ensureLoading），进程退出时由系统收
    static EngineHost *host = new EngineHost();
    return *host;
}

std::wstring EngineHost::dataDir() const {
    wchar_t buffer[MAX_PATH] = {};
    if (GetEnvironmentVariableW(L"WOWTYPE_DATA_DIR", buffer, MAX_PATH) > 0) {
        return buffer;
    }
    wchar_t *local = nullptr;
    std::wstring dir;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &local))) {
        dir = std::wstring(local) + L"\\WowType";
        CoTaskMemFree(local);
    }
    return dir;
}

std::wstring EngineHost::resource(const wchar_t *name) const {
    const std::wstring path = moduleDir() + L"\\data\\" + name;
    return fileExists(path) ? path : std::wstring();
}

std::wstring EngineHost::lexiconPath() const {
    const std::string configured = config_.value("Lexicon");
    if (!configured.empty()) {
        const std::wstring path = expandHome(widen(configured));
        if (fileExists(path)) {
            return path;
        }
        log(L"设置里的词库 " + path + L" 不在，用自带的词库");
    }
    return resource(L"lexicon.tsv");
}

void EngineHost::loadConfig() {
    configStamp_ = fileStamp(configPath());
    bool ok = false;
    const std::string text = readFileUtf8(configPath(), ok);
    Config loaded = ok ? Config::parse(text) : Config();
    if (loaded != config_ || configGeneration_ == 0) {
        config_ = loaded;
        ++configGeneration_;
        applyTranslateSettings();
        voice_.configure(config_.flag("Voice"), config_.value("VoiceKey"), config_.flag("VoiceCopy"),
                         narrow(voiceModelDir()), config_.number("VoiceSilenceTimeout"));
        if (stats_) {
            // 关掉时记录器丢掉内存里还没写的计数，以后什么都不记
            wowtype_stats_set_enabled(stats_, config_.flag("TypingStats"));
        }
        // 开发者模式（默认关）：开着时核心把每次选词、上屏明文记进数据目录的 devlog.jsonl（docs/DEVLOG.md），
        // 会话的每次调用自己写，这里只管开关。几个应用进程各写各的，都是整行追加
        if (config_.flag("DeveloperMode")) {
            wowtype_devlog_configure(narrow(dataDir() + L"\\devlog.jsonl").c_str(), 1);
        } else {
            wowtype_devlog_configure(nullptr, 0);
        }
        if (WowtypeEngineHandle *engine = engine_.load()) {
            applyEngineSettings(engine);
        }
        log(L"设置：每页 " + std::to_wstring(config_.pageSize()) + L"，方案 " + widen(config_.value("InputScheme")) +
            L"，Shift 切换 " + widen(config_.value("ShiftToggle")) + L"，词库 " +
            (config_.value("Lexicon").empty() ? std::wstring(L"自带") : widen(config_.value("Lexicon"))));
    }
}

void EngineHost::checkForChanges() {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (configGeneration_ == 0 || !sameStamp(fileStamp(configPath()), configStamp_)) {
        loadConfig();
    }
    if (WowtypeEngineHandle *engine = engine_.load()) {
        // 别的应用进程刚存过学到的词：合并进来；自己攒着没存的、隔了一会儿了：存
        mergeLearning(engine);
        if (commitsSinceSave_ > 0 && GetTickCount64() - lastSave_ >= kSaveAfterMs) {
            save();
        }
        const std::wstring custom = dataDir() + L"\\custom.tsv";
        if (!sameStamp(fileStamp(custom), customStamp_)) {
            customStamp_ = fileStamp(custom);
            const int n = wowtype_engine_load_custom_words(engine, narrow(custom).c_str());
            if (n < 0) {
                log(L"自定义词载入失败 " + custom);
            }
        }
    }
}

void EngineHost::applyEngineSettings(WowtypeEngineHandle *engine) {
    // 设置里管引擎的部分，和 macOS 的 Engine.apply、Linux 的 applyCoreSettings 一样
    wowtype_engine_set_fuzzy(engine, config_.flag("Fuzzy"));
    wowtype_engine_set_fuzzy_groups(engine, config_.fuzzyGroups());
    wowtype_engine_set_shuangpin(engine, config_.shuangpin());
    if (wowtype_engine_set_shuangpin_scheme(engine, config_.value("ShuangpinScheme").c_str()) != 0) {
        log(L"不认识双拼方案 " + widen(config_.value("ShuangpinScheme")) + L"，用自然码");
        wowtype_engine_set_shuangpin_scheme(engine, "ziranma");
    }
    wowtype_engine_set_shuangpin_abbrev(engine, config_.flag("ShuangpinAbbrev"));
    wowtype_engine_set_typo_correction(engine, config_.flag("TypoCorrection"));
    wowtype_engine_set_rare_ext_chars(engine, config_.flag("RareExtChars"));
    if (config_.flag("Traditional") && !conversionLoaded_) {
        const std::wstring s2t = resource(L"s2t.tsv");
        if (!s2t.empty() && wowtype_engine_load_conversion(engine, narrow(s2t).c_str()) > 0) {
            conversionLoaded_ = true;
        } else {
            log(L"简繁表载入失败（没有 data\\s2t.tsv）");
        }
    }
    wowtype_engine_set_traditional(engine, config_.flag("Traditional") && conversionLoaded_);
    if (config_.wubi() && !wubiLoaded_) {
        const std::wstring wubi = resource(L"wubi86.tsv");
        if (!wubi.empty() && wowtype_engine_load_wubi(engine, narrow(wubi).c_str()) > 0) {
            wubiLoaded_ = true;
        } else {
            log(L"五笔码表载入失败（没有 data\\wubi86.tsv），先按全拼打");
        }
    }
}

void EngineHost::applyTranslateSettings() {
    if (config_.flag("Translate") && !translator_) {
        translator_ = wowtype_translate_new();
    }
    if (!translator_) {
        return;
    }
    const std::string keyFile = narrow(dataDir() + L"\\translate.key");
    wowtype_translate_configure(translator_, config_.value("TranslateBaseUrl").c_str(),
                                config_.value("TranslateModel").c_str(), config_.value("TranslateTarget").c_str(),
                                config_.flag("TranslateFormal"), keyFile.c_str());
    std::string model;
    std::string server;
    if (config_.flag("TranslateLocal")) {
        model = config_.value("TranslateLocalModel");
        if (model.empty()) {
            model = narrow(dataDir() + L"\\models\\Hy-MT3-1.8B-Q4_K_M.gguf");
        }
        server = config_.value("TranslateLlamaServer");
    }
    // 没选本地模型时传空串：不起进程、不占端口（已经起了的马上停掉）
    wowtype_translate_configure_local(translator_, model.c_str(), server.c_str(),
                                      static_cast<unsigned>(config_.number("TranslateIdleMinutes") * 60));
}

WowtypeEngineHandle *EngineHost::makeEngine() {
    const std::wstring lexicon = lexiconPath();
    if (lexicon.empty()) {
        log(L"安装目录里没有 data\\lexicon.tsv");
        return nullptr;
    }
    CreateDirectoryW(dataDir().c_str(), nullptr);
    const std::wstring lm = resource(L"words.lm");
    WowtypeEngineHandle *engine =
        wowtype_engine_new(narrow(lexicon).c_str(), lm.empty() ? nullptr : narrow(lm).c_str());
    if (!engine && !lm.empty()) {
        engine = wowtype_engine_new(narrow(lexicon).c_str(), nullptr);
    }
    if (!engine) {
        const char *error = wowtype_last_error();
        log(L"载入词库失败 " + lexicon + L"：" + widen(error ? error : ""));
        return nullptr;
    }
    wowtype_engine_set_max_candidates(engine, kMaxCandidates);
    if (const std::wstring english = resource(L"english.txt"); !english.empty()) {
        wowtype_engine_load_english(engine, narrow(english).c_str());
    }
    // 用户自己训的领域词级模型（可选），和 words.lm 混着用
    if (const std::wstring domain = dataDir() + L"\\words.domain.lm"; fileExists(domain)) {
        if (wowtype_engine_set_domain_lm(engine, narrow(domain).c_str()) != 0) {
            log(L"领域词级模型载入失败 " + domain);
        }
    }
    // 整句增强模型：用户导入的微信输入法模型优先，再是安装包里 WowType 自己的
    std::wstring nnlm = dataDir() + L"\\wetype\\nlrgpt2_nnlm.bin";
    if (!fileExists(nnlm)) {
        nnlm = resource(L"nnlm.bin");
    }
    if (!nnlm.empty() && wowtype_engine_load_nnlm(engine, narrow(nnlm).c_str()) < 0) {
        log(L"整句增强模型载入失败 " + nnlm);
    }
    wowtype_engine_load_user_dict(engine, narrow(dataDir() + L"\\user.tsv").c_str());
    wowtype_engine_load_history(engine, narrow(dataDir() + L"\\history.tsv").c_str());
    return engine;
}

void EngineHost::ensureLoading() {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (loading_) {
        return;
    }
    loading_ = true;
    // 核心起了线程以后 DLL 就不能卸载了（线程的代码在 DLL 里）：钉住，DllCanUnloadNow 怎么答都不卸
    HMODULE pinned = nullptr;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                       reinterpret_cast<LPCWSTR>(&fileStamp), &pinned);
    if (configGeneration_ == 0) {
        loadConfig();
    }
    wowtype_recent_emoji_path(narrow(dataDir() + L"\\emoji-recent.txt").c_str());
    {
        // 开发者模式的记录里带上是在哪个应用里打的：这个 DLL 加载在应用进程里，exe 的名字就是应用
        wchar_t exe[MAX_PATH] = {};
        std::wstring name(exe, GetModuleFileNameW(nullptr, exe, MAX_PATH));
        if (const auto slash = name.find_last_of(L"\\/"); slash != std::wstring::npos) {
            name.erase(0, slash + 1);
        }
        wowtype_devlog_set_app(narrow(name).c_str());
    }
    // 打字统计的记录器：建好时是关着的（不读不建文件），按 TypingStats 打开。几个应用进程各有一个，
    // 核心写文件时先读回再合并，计数不会互相盖掉
    stats_ = wowtype_stats_new(narrow(dataDir() + L"\\stats.json").c_str());
    if (stats_) {
        wowtype_stats_set_enabled(stats_, config_.flag("TypingStats"));
    }
    // 词库有几十 MB，放后台读，读完再交给文本服务（按键时看 engine() 有没有了）
    std::thread([this] {
        WowtypeEngineHandle *engine = makeEngine();
        std::lock_guard<std::recursive_mutex> inner(mutex_);
        if (!engine) {
            return;
        }
        applyEngineSettings(engine);
        customStamp_ = FILETIME{};
        userStamp_ = fileStamp(dataDir() + L"\\user.tsv");
        historyStamp_ = fileStamp(dataDir() + L"\\history.tsv");
        engine_.store(engine);
        log(L"词库载入好了");
    }).detach();
}

void EngineHost::didCommit() {
    ++commitsSinceSave_;
    if (GetTickCount64() - lastSave_ >= kSaveAfterMs) {
        save();
    }
}

void EngineHost::mergeLearning(WowtypeEngineHandle *engine) {
    const std::wstring userPath = dataDir() + L"\\user.tsv";
    const std::wstring historyPath = dataDir() + L"\\history.tsv";
    // 上次后台写失败了现在才知道：记下来，下次接着存
    if (wowtype_engine_save_wait(engine, 0) < 0) {
        const char *error = wowtype_last_error();
        log(L"保存用户词库或输入习惯失败：" + widen(error ? error : ""));
        commitsSinceSave_ = std::max(commitsSinceSave_, 1);
    }
    // 每个应用进程各有一个引擎、各存各的：文件和上次合并时不一样了（别的进程存过，也可能是自己刚存的）就合并进来。
    // 合并自己存的没关系：用户词留大的频次、输入习惯同一条留最近用过的（核心的 load 就是这么合并的），不会往回改。
    // 以前只认「不是自己写的」：自己的存盘写完的那一刻别的进程也写过，就当成自己的、漏了（CI 的两个进程测试抓到的）。
    // 哪个变了两个都读，先读输入习惯：里面有别的应用忘掉的词（f 行），读用户词库时按它去掉；忘掉以后又学到的，
    // 输入习惯里的热度更新，读用户词库时就留着
    const FILETIME userNow = fileStamp(userPath);
    const FILETIME historyNow = fileStamp(historyPath);
    if (sameStamp(userNow, userStamp_) && sameStamp(historyNow, historyStamp_)) {
        return;
    }
    const int history = wowtype_engine_load_history(engine, narrow(historyPath).c_str());
    const int user = wowtype_engine_load_user_dict(engine, narrow(userPath).c_str());
    userStamp_ = userNow;
    historyStamp_ = historyNow;
    trace(L"合并别的应用存的学习数据：输入习惯 " + std::to_wstring(history) + L" 条，用户词 " + std::to_wstring(user) + L" 条");
}

void EngineHost::didForget() {
    ++commitsSinceSave_;
    save();
}

void EngineHost::save(bool wait) {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    WowtypeEngineHandle *engine = engine_.load();
    if (!engine) {
        return;
    }
    // 先把别的进程存过的合并进来，再写
    mergeLearning(engine);
    if (commitsSinceSave_ > 0) {
        lastSave_ = GetTickCount64();
        CreateDirectoryW(dataDir().c_str(), nullptr);
        const bool dict = wowtype_engine_save_user_dict_async(engine, narrow(dataDir() + L"\\user.tsv").c_str()) == 0;
        const bool history =
            wowtype_engine_save_history_async(engine, narrow(dataDir() + L"\\history.tsv").c_str()) == 0;
        if (dict && history) {
            commitsSinceSave_ = 0;
        }
        if (!dict || !history) {
            log(L"存学习数据交不出去（下次接着存）");
        } else {
            trace(L"存学习数据（后台写）");
        }
    }
    if (wait && wowtype_engine_save_wait(engine, -1) < 0) {
        const char *error = wowtype_last_error();
        log(L"保存用户词库或输入习惯失败：" + widen(error ? error : ""));
    }
}

void EngineHost::recordKey(uint32_t code, bool sensitive) {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (!stats_ || sensitive || !config_.flag("TypingStats")) {
        return;
    }
    // platform 2 = Windows（ABI 1.13）
    wowtype_stats_key(stats_, 2, code, 1, 0, wowtype_stats_now_ms());
}

void EngineHost::recordCommit(const std::string &text, const std::string &source, const std::string &scheme, int index,
                              bool sensitive) {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (!stats_ || sensitive || !config_.flag("TypingStats")) {
        return;
    }
    wowtype_stats_commit(stats_, text.c_str(), source.c_str(), scheme.c_str(), index, 0, wowtype_stats_now_ms());
}

void EngineHost::flushStats() {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (stats_ && config_.flag("TypingStats")) {
        wowtype_stats_flush(stats_, wowtype_stats_now_ms());
    }
}

void EngineHost::checkUpdateIfDue() {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    wchar_t override[8] = {};
    // 开发版（dev）不查；测试时换了数据目录也不查
    if (!config_.flag("CheckUpdate") || updateChecking_ || !update::isRelease(WOWTYPE_VERSION) ||
        GetEnvironmentVariableW(L"WOWTYPE_DATA_DIR", override, 8) > 0) {
        return;
    }
    const ULONGLONG now = GetTickCount64();
    if (now < nextUpdateLook_) {
        return;
    }
    nextUpdateLook_ = now + 3600 * 1000ULL;
    const std::wstring dir = dataDir();
    const auto nowSeconds = static_cast<int64_t>(std::time(nullptr));
    update::State state = win::readState(dir);
    if (!update::due(state, nowSeconds)) {
        return;
    }
    // 先记下这次试过：每个应用进程各有一个输入法，查不成（断网、GitHub 出错）时别的进程看到它，一小时内不再各问一遍
    state.tried = nowSeconds;
    win::writeState(dir, state);
    updateChecking_ = true;
    const bool beta = config_.flag("BetaUpdates");
    std::thread([this, dir, beta] {
        std::string error;
        const auto release = win::fetchLatest(dir, beta, WOWTYPE_VERSION, &error);
        std::lock_guard<std::recursive_mutex> inner(mutex_);
        updateChecking_ = false;
        if (!release) {
            log(L"检查更新失败：" + widen(error));
        } else if (const auto latest = update::version(release->tag); latest && update::isNewer(*latest, WOWTYPE_VERSION)) {
            log(L"有新版本 " + widen(*latest) + L"（现在 " WOWTYPE_WIDE_VERSION L"）");
        }
    }).detach();
}

std::optional<std::string> EngineHost::availableUpdate() {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (!config_.flag("CheckUpdate")) {
        return std::nullopt;
    }
    const auto latest = update::version(win::readState(dataDir()).latest);
    if (latest && update::isNewer(*latest, WOWTYPE_VERSION)) {
        return latest;
    }
    return std::nullopt;
}

void EngineHost::sampleClipboard() {
    if (!config_.flag("ClipboardHistory")) {
        return;
    }
    // 序号没变就是没复制过新东西，不去开剪贴板
    const DWORD sequence = GetClipboardSequenceNumber();
    if (sequence == clipboardSequence_) {
        return;
    }
    clipboardSequence_ = sequence;
    if (!IsClipboardFormatAvailable(CF_UNICODETEXT) || !OpenClipboard(nullptr)) {
        return;
    }
    std::string text;
    if (HANDLE data = GetClipboardData(CF_UNICODETEXT)) {
        if (const auto *chars = static_cast<const wchar_t *>(GlobalLock(data))) {
            text = narrow(chars);
            GlobalUnlock(data);
        }
    }
    CloseClipboard();
    if (!text.empty() && text != lastClipboard_) {
        lastClipboard_ = text;
        wowtype_clipboard_remember(text.c_str());
    }
}

} // namespace wowtype::tsf
