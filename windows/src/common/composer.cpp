#include "composer.h"

#include <algorithm>
#include <chrono>

#include "utf.h"

namespace wowtype {

namespace {

std::string str(const char *p) { return p ? std::string(p) : std::string(); }

/// frame 带不带某个字段（旧核心给的结构体短）。外壳和核心一起编，正常都带。
bool hasFullFrame(const WowtypeFrame *frame) { return frame && frame->size >= sizeof(WowtypeFrame); }

} // namespace

uint64_t monotonicMs() {
    using namespace std::chrono;
    return static_cast<uint64_t>(duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count());
}

Composer::Composer(WowtypeEngineHandle *engine, TextClient *client) : engine_(engine), client_(client) {
    session_ = wowtype_session_new(engine, nullptr);
    configure();
}

Composer::~Composer() {
    // 先让会话放掉翻译器（翻译器比会话活得久，但别留着借用）
    wowtype_session_set_translator(session_, nullptr);
    wowtype_session_free(session_);
}

uint64_t Composer::now() const { return clock ? clock() : monotonicMs(); }

Composer::Mode Composer::mode() const {
    switch (wowtype_session_mode(session_)) {
    case WOWTYPE_MODE_ENGLISH: return Mode::English;
    case WOWTYPE_MODE_TRANSLATE: return Mode::Translate;
    default: return Mode::Chinese;
    }
}

bool Composer::isComposing() const {
    const char *input = wowtype_session_input(session_);
    return input && *input;
}

std::string Composer::input() const { return str(wowtype_session_input(session_)); }

std::string Composer::translateSource() const { return str(wowtype_session_translate_source(session_)); }

Composer::Panel Composer::openPanel() const {
    switch (wowtype_session_open_panel(session_)) {
    case WOWTYPE_TOOL_MENU: return Panel::Menu;
    case WOWTYPE_TOOL_CLIPBOARD: return Panel::Clipboard;
    case WOWTYPE_TOOL_PHRASES: return Panel::Phrases;
    case WOWTYPE_TOOL_SYMBOLS: return Panel::Symbols;
    case WOWTYPE_TOOL_EMOJI: return Panel::Emoji;
    default: return Panel::None;
    }
}

bool Composer::translateAvailable() const {
    return config_.flag("Translate") && translator_ && wowtype_translate_ready(translator_) == 1;
}

bool Composer::translating() const {
    return mode() == Mode::Translate && translator_ && client_ && client_->allowsTranslation();
}

bool Composer::canToggleMode() const { return !config_.is("ShiftToggle", "Off") || config_.toggleKey().has_value(); }

std::string Composer::modeName() const {
    switch (mode()) {
    case Mode::English: return "en";
    case Mode::Translate: return "translate";
    default: return "zh";
    }
}

std::vector<std::string> Composer::allCandidates() const {
    std::vector<std::string> out;
    const std::size_t total = wowtype_session_candidate_total(session_);
    for (std::size_t i = 0; i < total; ++i) {
        WowtypeCandidateInfo info{};
        info.size = sizeof(WowtypeCandidateInfo);
        if (wowtype_session_candidate_info(session_, i, &info) == 0 && info.text) {
            out.emplace_back(info.text);
        }
    }
    return out;
}

void Composer::setEngine(WowtypeEngineHandle *engine) {
    if (engine == engine_) {
        return;
    }
    if (engine_ && isComposing()) {
        // 换词库：编辑区、候选都是旧词库算的，清掉（和 Linux、macOS 一样）
        wowtype_session_reset(session_, 0);
    }
    // 先让会话换上新的，再由外壳放掉旧的
    wowtype_session_set_engine(session_, engine);
    engine_ = engine;
    refresh();
}

void Composer::apply(const Config &config) {
    config_ = config;
    const bool noWayBack = config_.is("ShiftToggle", "Off") && !config_.toggleKey();
    if (noWayBack || (mode() == Mode::Translate && !translateAvailable())) {
        switchMode(Mode::Chinese);
    }
    if (!config_.flag("ClipboardHistory")) {
        wowtype_clipboard_clear();
    }
    configure();
}

void Composer::setTranslator(WowtypeTranslator *translator) {
    if (translator == translator_) {
        return;
    }
    // 换翻译器前攒着的原文原样上屏（会话换翻译器时会丢掉原文）
    const std::string source = translateSource();
    if (!source.empty() && client_) {
        client_->insertText(source);
    }
    translator_ = translator;
    wowtype_session_set_translator(session_, translator);
    configure();
    if (mode() == Mode::Translate && !translateAvailable()) {
        applyFrame(wowtype_session_set_mode(session_, WOWTYPE_MODE_CHINESE));
    }
    refresh();
}

// ---------------------------------------------------------------- 按键

bool Composer::handle(const KeyInput &key) {
    if (key.release) {
        return false;
    }
    // 先报给会话：按住 Shift 时按了别的键，这一下就不算单按（下面有的键不交给会话）
    observe(key);
    // 表情面板快捷键中英文都管；工具栏、表情面板开着时按键都归它们（和 Linux 一样）
    if (const auto emojiKey = config_.emojiKey(); emojiKey && emojiKey->matches(key)) {
        toggleEmojiPanel();
        return true;
    }
    if (openPanel() != Panel::None) {
        return handleToolKey(key);
    }
    if (const auto action = modeKeyAction(key)) {
        // 另设的切换键、进出「译」的键：会话切；进不了「译」时交给应用。翻译器可能刚配好：先跟上
        configure();
        return sendToSession(key, *action);
    }
    // 互译、没在打拼音：回车上屏译文、Shift+回车上屏原文、Esc 清空……都由会话处理
    if (mode() == Mode::Translate && !isComposing() && !key.hasShortcutModifier()) {
        return sendToSession(key);
    }
    if (mode() == Mode::English) {
        // 英文模式：按键原样交给应用；汉字后面打字母、数字要补空格时会话连空格一起上屏
        return sendToSession(key);
    }
    const bool composing = isComposing();
    if (!engine_ && !composing) {
        // 词库还在后台载入：先什么都不吃，字母原样给应用
        return false;
    }
    if (key.hasShortcutModifier()) {
        // 先问会话：打字途中 Ctrl+Delete、Ctrl+退格忘掉光标处学错的词。别的快捷键交给应用，
        // 没在打字时会话借这一下知道应用里的字可能变了（上文作废）
        return sendToSession(key);
    }
    if (!composing) {
        return handleIdle(key);
    }
    return handleComposing(key);
}

bool Composer::shiftChanged(bool down, bool otherModifiers, uint64_t nowMs, bool right) {
    configure(); // 翻译器可能刚配好：「译」这一档跟着
    WowtypeKey raw{};
    raw.size = sizeof(WowtypeKey);
    raw.keysym = right ? keysym::shiftRight : keysym::shiftLeft;
    raw.release = down ? 0 : 1;
    raw.modifiers = otherModifiers ? mod::control : 0;
    raw.time_ms = nowMs;
    const WowtypeFrame *frame = wowtype_session_key(session_, &raw);
    if (frame && frame->wake_after_ms > 0 && onTranslatePoll) {
        // 单按 Shift 等双击（#253）：到时间没有第二下，pollTranslation 里切
        onTranslatePoll(frame->wake_after_ms);
    }
    if (!frame || !frame->mode_changed) {
        return false;
    }
    // 打到一半切英文：会话把已选的词 + 打的字母放进了 frame；离开「译」时是攒着的原文
    applyFrame(frame);
    return true;
}

void Composer::otherModifierChanged() {
    WowtypeKey raw{};
    raw.size = sizeof(WowtypeKey);
    raw.action = WOWTYPE_KEY_ACTION_OBSERVE;
    followObserved(wowtype_session_key(session_, &raw));
}

void Composer::observe(const KeyInput &key) {
    WowtypeKey raw{};
    raw.size = sizeof(WowtypeKey);
    raw.keysym = key.keysym;
    raw.modifiers = key.modifiers;
    raw.action = WOWTYPE_KEY_ACTION_OBSERVE;
    followObserved(wowtype_session_key(session_, &raw));
}

void Composer::followObserved(const WowtypeFrame *frame) {
    if (frame && frame->mode_changed) {
        // 等双击的单按 Shift 被这个键打断（#253）：会话先切了（打到一半切英文时字母在 frame 里），这个键照新模式处理
        applyFrame(frame);
    }
}

std::optional<uint32_t> Composer::modeKeyAction(const KeyInput &key) const {
    // 两个设成一样时算进出「译」（和 Linux、macOS 一样）
    if (const auto k = config_.translateModeKey(); k && k->matches(key)) {
        return WOWTYPE_KEY_ACTION_TOGGLE_TRANSLATE;
    }
    if (const auto k = config_.toggleKey(); k && k->matches(key)) {
        return WOWTYPE_KEY_ACTION_TOGGLE_MODE;
    }
    return std::nullopt;
}

void Composer::switchMode(Mode target) {
    if (target == Mode::Translate && !translateAvailable()) {
        target = Mode::Chinese;
    }
    if (target == mode()) {
        return;
    }
    const int raw = target == Mode::English ? WOWTYPE_MODE_ENGLISH
                    : target == Mode::Translate ? WOWTYPE_MODE_TRANSLATE
                                                : WOWTYPE_MODE_CHINESE;
    applyFrame(wowtype_session_set_mode(session_, raw));
}

bool Composer::setModeNamed(const std::string &name) {
    Mode target;
    if (name == "zh") {
        target = Mode::Chinese;
    } else if (name == "en") {
        target = Mode::English;
    } else if (name == "translate") {
        if (!translateAvailable()) {
            return false;
        }
        target = Mode::Translate;
    } else if (name == "toggle") {
        target = mode() == Mode::Chinese ? Mode::English : Mode::Chinese;
    } else {
        return false;
    }
    switchMode(target);
    return true;
}

void Composer::applyInitialMode() {
    if (config_.is("InitialMode", "Last")) {
        return;
    }
    if (config_.is("InitialMode", "English")) {
        switchMode(canToggleMode() ? Mode::English : Mode::Chinese);
    } else {
        switchMode(Mode::Chinese);
    }
}

void Composer::applyWindowMode() {
    if (config_.is("WindowMode", "English")) {
        switchMode(canToggleMode() ? Mode::English : Mode::Chinese);
    } else if (config_.is("WindowMode", "Chinese")) {
        switchMode(Mode::Chinese);
    }
    // Same（和认不出的值一样按默认）：不动，模式照旧
}

void Composer::commitComposition() {
    closeTool();
    if (hasPendingText()) {
        applyFrame(wowtype_session_reset(session_, 1));
    }
    applyFrame(wowtype_session_reset(session_, 0));
}

void Composer::cancel() {
    closeTool();
    translateDrawn_.clear();
    wowtype_session_translate_clear(session_);
    applyFrame(wowtype_session_reset(session_, 0));
}

void Composer::select(int index) {
    if (index < 0) {
        return;
    }
    const WowtypeFrame *frame = wowtype_session_select(session_, static_cast<std::size_t>(index));
    if (frame && frame->handled) {
        applyFrame(frame);
    }
}

void Composer::turnPage(bool forward) {
    if (!isComposing() && openPanel() == Panel::None) {
        return;
    }
    handle(KeyInput::key(forward ? keysym::pageDown : keysym::pageUp));
}

void Composer::insert(const std::string &text) {
    if (text.empty()) {
        return;
    }
    applyFrame(wowtype_session_commit_text(session_, text.c_str(), reliablePreviousCharacter()));
}

// ---------------------------------------------------------------- 内部

void Composer::configure() {
    WowtypeSessionConfig c{};
    c.size = sizeof(WowtypeSessionConfig);
    c.page_size = static_cast<uint32_t>(std::max(config_.pageSize(), 1));
    c.calculator = config_.flag("Calculator");
    c.date_time = config_.flag("DateTime");
    c.emoji_suggest = config_.flag("EmojiSuggest");
    c.horizontal = config_.horizontal();
    c.arrow_keys = config_.arrowKeys();
    c.page_keys = config_.pageKeys();
    c.select_keys = config_.selectKeys();
    c.pick_char = config_.flag("PickChar");
    c.punct_style = config_.halfwidthPunct() ? 1 : 0;
    c.auto_space = config_.autoSpaceFlags();
    c.shift_toggle = config_.shiftToggle();
    c.shift_tap_ms = 0;
    // 双击 Shift 不切换（#253）：等着的单按在 pollTranslation、observe 的 frame 里切，都跟着 mode_changed
    c.shift_double_tap = 1;
    c.translate_mode = translateAvailable();
    c.translate_key = config_.translateModeKey().has_value();
    // 互译只翻一句（#191）：双击 Shift 进「译」，翻完回去的 frame 可能在 pollTranslation 里，TSF 比对模式跟上
    c.translate_one_shot = config_.flag("TranslateOneShot");
    c.toolbar = config_.flag("Toolbar");
    c.clipboard_history = config_.flag("ClipboardHistory");
    c.shuangpin_keys = config_.flag("ShuangpinShowKeys");
    c.wubi = config_.wubi();
    c.wubi_auto_commit = config_.flag("WubiAutoCommit");
    c.wubi_hint = config_.flag("WubiHint");
    c.association = config_.flag("Association");
    // 自动配对要能挪应用里的光标：这个输入框现在不能时先不开（sendToSession 每个键看一眼，变了再配）
    pairing_ = config_.flag("AutoPairPunct") && client_ && client_->canEditAroundCaret();
    c.auto_pair_punct = pairing_;
    wowtype_session_configure(session_, &c);
    if (isComposing()) {
        refresh();
    }
}

bool Composer::handleIdle(const KeyInput &key) {
    // 都交给会话：字母开始编辑区；标点换成中文标点；汉字后面打数字要补空格时会话自己上屏；
    // 退格、方向键、回车这些交给应用，会话借这一下知道应用里的字可能变了（上文作废）
    if (sendToSession(key)) {
        return true;
    }
    // 互译时打的字都要进原文：会话交给应用的（数字后面的点 3.14、半角标点）原样进原文
    const auto c = key.ascii();
    if (translating() && c && *c > 0x20 && *c < 0x7f && !key.isLetter()) {
        insert(std::string(1, static_cast<char>(*c)));
        return true;
    }
    return false;
}

bool Composer::handleComposing(const KeyInput &key) {
    if (key.keysym == 0x20 && input() == "v" && config_.flag("ClipboardHistory") && sampleClipboard) {
        // 只打一个 v 再按空格打开工具栏（会话做）：剪贴板页要的历史先读一次
        sampleClipboard();
    }
    if (sendToSession(key)) {
        return true;
    }
    // 会话不管的键：展开面板里按了这种键，会话已经把面板收起来了，先重画；
    // 其他功能键（Tab、Home 等）打字途中吃掉，免得光标跑到别处
    refresh();
    return true;
}

bool Composer::handleToolKey(const KeyInput &key) {
    if (openPanel() == Panel::Menu && config_.flag("ClipboardHistory") && sampleClipboard) {
        sampleClipboard(); // 下一步可能进「剪贴板」页
    }
    if (sendToSession(key)) {
        return true;
    }
    refresh();
    return false;
}

uint32_t Composer::previousCharacter() {
    if (translating()) {
        if (const uint32_t last = lastCodepoint(translateSource())) {
            return last;
        }
    }
    return client_ ? client_->previousCharacter() : 0;
}

uint32_t Composer::reliablePreviousCharacter() {
    if (!client_ || !client_->previousCharacterIsReliable()) {
        return 0;
    }
    return client_->previousCharacter();
}

bool Composer::sendToSession(const KeyInput &key, uint32_t action) {
    if (config_.flag("AutoPairPunct") || pairing_) {
        // 输入框能不能按位置改字可能变了：变了重新配会话
        const bool wanted = config_.flag("AutoPairPunct") && client_ && client_->canEditAroundCaret();
        if (wanted != pairing_) {
            configure();
        }
    }
    WowtypeKey raw{};
    raw.size = sizeof(WowtypeKey);
    raw.keysym = key.keysym;
    raw.modifiers = key.modifiers;
    raw.release = key.release ? 1 : 0;
    raw.action = action;
    raw.time_ms = now();
    if (client_) {
        // 应用说了是密码框、网址框这些（TSF 的 InputScope）
        raw.hints |= client_->inputHints();
    }
    if (client_ && !client_->allowsTranslation()) {
        // 密码框：「译」里也照常上屏、不往外发，进出「译」的键进不去
        raw.hints |= WOWTYPE_KEY_HINT_NO_TRANSLATE;
    }
    if (pairing_ && !translating() && client_) {
        if (const auto next = client_->nextCharacter()) {
            // 自动配对：跳过右标点、成对删之前，会话拿光标后的字核对补好的右半边还在不在
            raw.next_char = *next;
            raw.hints |= WOWTYPE_KEY_HINT_NEXT_CHAR;
        }
    }
    if (translating()) {
        // 互译时上屏的字进原文：光标前的字是原文的最后一个字，不补空格
        raw.prev_char = previousCharacter();
        raw.hints |= WOWTYPE_KEY_HINT_NO_AUTO_SPACE;
    } else {
        // 应用告诉的才给（自己猜的给 0）。读得到周围文字时光标前没有字（输入框清空了、光标在开头）也报：
        // 会话把自己记的上文清掉，和 fcitx5 一样；不报的话清空输入框以后还拿上一次上屏的字当上文
        // （CI 的两个进程学习测试里，上文「你好」「时」带出的搭配把两个应用的排序弄得不一样）
        if (client_ && client_->previousCharacterIsReliable()) {
            raw.prev_char = client_->previousCharacter();
            raw.hints |= WOWTYPE_KEY_HINT_SURROUNDING;
        }
    }
    const WowtypeFrame *frame = wowtype_session_key(session_, &raw);
    if (!frame) {
        return false;
    }
    const bool handled = frame->handled != 0;
    if (handled) {
        applyFrame(frame);
    } else if (hasFullFrame(frame) && frame->delete_next && client_ && client_->deletePair()) {
        // 自动配对：空的一对按退格，左右两半一起删（这个退格吃掉，不再交给应用）
        refresh();
        return true;
    } else if (associationShown_) {
        // 联想开着时按了打字以外的键：会话关掉了联想、键交给应用
        refresh();
    }
    return handled;
}

void Composer::applyFrame(const WowtypeFrame *frame) {
    // 离开「译」的那一下上屏的（只翻一句时的译文，原文原样上屏）照「译」记统计：会话已经切回去了（和 Linux 一样）
    const Mode statsMode = frame && frame->mode_changed && appliedMode_ == Mode::Translate ? Mode::Translate : mode();
    appliedMode_ = mode();
    if (frame && frame->commit && client_) {
        // 会话已经补好了空格、记了上文；互译时上屏的是译文、原文
        const std::string text = frame->commit;
        client_->insertText(text);
        if (onCommitStats) {
            // 打字统计（外壳按 TypingStats 决定记不记）：互译上屏的不是候选，位置记 0
            const int index = hasFullFrame(frame) && statsMode != Mode::Translate ? static_cast<int>(frame->choice_index) : 0;
            onCommitStats(text, statsSource(statsMode), statsScheme(statsMode), index);
        }
        if (frame->learned && onCommit) {
            onCommit(text);
        }
    }
    if (hasFullFrame(frame) && frame->cursor_delta != 0 && client_) {
        // 自动配对：上屏「（）」后光标放到中间（-1），跳过补好的右半边（+1）。紧跟在上屏后面、下一个键之前
        client_->moveCaret(frame->cursor_delta);
    }
    if (hasFullFrame(frame) && frame->forgot && onForget) {
        onForget();
    }
    refresh();
}

void Composer::refresh() {
    if (!client_) {
        return;
    }
    if (openPanel() != Panel::None) {
        drawTool();
        return;
    }
    if (translating()) {
        const WowtypeFrame *all = wowtype_session_frame(session_);
        if (all && all->translating && (isComposing() || !translateSource().empty())) {
            refreshTranslate(all);
            return;
        }
    }
    // 没在打字时也可能有上屏以后的联想（会话给的一页，照普通候选框画）
    const bool associating = !isComposing() && wowtype_session_association(session_) != 0;
    associationShown_ = associating;
    const WowtypeFrame *frame = isComposing() || associating ? wowtype_session_frame(session_) : nullptr;
    if (!frame) {
        client_->setMarkedText("", 0);
        client_->showCandidates(nullptr);
        return;
    }
    client_->setMarkedText(str(frame->preedit), frame->preedit_cursor);
    const auto page = candidatePage(frame);
    client_->showCandidates(page ? &*page : nullptr);
}

std::optional<CandidatePage> Composer::candidatePage(const WowtypeFrame *frame) {
    CandidatePage page;
    // 只读显示的这些：候选可能有上千个
    for (std::size_t i = 0; i < frame->cand_count; ++i) {
        if (const char *text = wowtype_session_candidate(session_, i)) {
            page.texts.emplace_back(text);
            page.comments.push_back(str(wowtype_session_candidate_comment(session_, i)));
        }
    }
    // 五笔空码、没有码表时没有候选，只有上方一行提示
    if (frame->aux) {
        page.aux = std::string(frame->aux);
    }
    if (page.texts.empty() && !page.aux) {
        return std::nullopt;
    }
    page.cursor = frame->cand_cursor;
    page.hasPrev = frame->has_prev != 0;
    page.hasNext = frame->has_next != 0;
    page.expanded = frame->panel == WOWTYPE_PANEL_EXPANDED;
    page.vertical = !config_.horizontal();
    page.labels = !(frame->panel == WOWTYPE_PANEL_ASSOCIATION && frame->cand_cursor < 0);
    return page;
}

void Composer::toggleEmojiPanel() { applyFrame(wowtype_session_toggle_emoji_panel(session_)); }

void Composer::openTool(Panel panel) {
    int raw = WOWTYPE_TOOL_NONE;
    switch (panel) {
    case Panel::Menu: raw = WOWTYPE_TOOL_MENU; break;
    case Panel::Clipboard: raw = WOWTYPE_TOOL_CLIPBOARD; break;
    case Panel::Phrases: raw = WOWTYPE_TOOL_PHRASES; break;
    case Panel::Symbols: raw = WOWTYPE_TOOL_SYMBOLS; break;
    case Panel::Emoji: raw = WOWTYPE_TOOL_EMOJI; break;
    case Panel::None: break;
    }
    if (panel == Panel::Clipboard && config_.flag("ClipboardHistory") && sampleClipboard) {
        sampleClipboard();
    }
    applyFrame(wowtype_session_open_tool(session_, raw));
}

void Composer::closeTool() {
    if (openPanel() == Panel::None) {
        return;
    }
    applyFrame(wowtype_session_open_tool(session_, WOWTYPE_TOOL_NONE));
}

void Composer::drawTool() {
    const WowtypeFrame *frame = wowtype_session_frame(session_);
    if (!frame) {
        return;
    }
    const std::string query = str(frame->preedit);
    client_->setMarkedText(query, static_cast<int>(query.size()));
    CandidatePage page;
    for (std::size_t i = 0; i < frame->cand_count; ++i) {
        if (const char *text = wowtype_session_candidate(session_, i)) {
            page.texts.emplace_back(text);
            page.comments.emplace_back();
        }
    }
    if (frame->aux) {
        page.aux = std::string(frame->aux);
    }
    const bool emoji = frame->panel == WOWTYPE_PANEL_EMOJI;
    page.cursor = frame->cand_cursor;
    page.hasPrev = frame->has_prev != 0;
    page.hasNext = frame->has_next != 0;
    page.expanded = emoji;
    page.vertical = !emoji;
    client_->showCandidates(&page);
}

/// 统计用的输入模式：互译 / 英文 / 五笔 / 双拼 / 全拼（和 macOS 一样）。
std::string Composer::statsSource(Mode mode) const {
    switch (mode) {
    case Mode::Translate: return "translate";
    case Mode::English: return "english";
    default: break;
    }
    if (config_.wubi()) {
        return "wubi";
    }
    return config_.shuangpin() ? "shuangpin" : "quanpin";
}

/// 双拼方案在统计里的名字（小写）；不是双拼时为空。
std::string Composer::statsScheme(Mode mode) const {
    if (!config_.shuangpin() || mode != Mode::Chinese) {
        return {};
    }
    std::string scheme = config_.value("ShuangpinScheme");
    for (char &c : scheme) {
        if (c >= 'A' && c <= 'Z') {
            c = static_cast<char>(c - 'A' + 'a');
        }
    }
    return scheme;
}

// ---------------------------------------------------------------- 互译

uint32_t Composer::pollTranslation() {
    const WowtypeFrame *frame = wowtype_session_tick(session_, now());
    if (!frame) {
        return 0;
    }
    const uint32_t wake = frame->wake_after_ms;
    if (frame->mode_changed) {
        // 单按 Shift 等双击等到了时间（#253）：现在切（打到一半切英文时字母在 frame 里）
        translateDrawn_.clear();
        applyFrame(frame);
    } else if (frame->commit) {
        // 按过回车，译好了：上屏译文（正在打的拼音留着）
        translateDrawn_.clear();
        applyFrame(frame);
    } else if (frame->translating && translateSignature(frame) != translateDrawn_) {
        // 结果变了才重画；正在打拼音时候选列表（和翻到的页、光标）不动
        refresh();
    }
    return wake;
}

std::string Composer::translateSignature(const WowtypeFrame *f) const {
    return str(f->translate_source) + "|" + str(f->translate_text) + "|" + str(f->translate_status) + "|" +
           str(f->translate_title) + "|" + std::to_string(f->translate_done);
}

void Composer::refreshTranslate(const WowtypeFrame *f) {
    translateDrawn_ = translateSignature(f);
    if (f->wake_after_ms > 0 && onTranslatePoll) {
        onTranslatePoll(f->wake_after_ms);
    }
    // 先把要用的字抄出来：读候选会让会话重算，frame 里的指针就不能用了
    const std::string shown = str(f->translate_text);
    std::string box = str(f->translate_source);
    const std::string title = str(f->translate_title);
    const std::string status = str(f->translate_status);
    const bool composing = isComposing();
    if (composing) {
        box += str(f->preedit);
    }
    std::optional<CandidatePage> page = composing ? candidatePage(f) : std::nullopt;
    if (!page) {
        page = CandidatePage{};
    }
    page->translate = CandidatePage::Translate{title, box, status};
    client_->setMarkedText(shown, static_cast<int>(shown.size()));
    client_->showCandidates(&*page);
}

} // namespace wowtype
