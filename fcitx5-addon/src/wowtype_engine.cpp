#include "wowtype_engine.h"

#include <cstdlib>
#include <filesystem>
#include <memory>
#include <string>
#include <system_error>
#include <utility>

#include <fcitx/addonfactory.h>
#include <fcitx/addonmanager.h>
#include <fcitx/candidatelist.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputcontextmanager.h>
#include <fcitx/inputpanel.h>
#include <fcitx/instance.h>
#include <fcitx/text.h>
#include <fcitx/userinterface.h>
#include <fcitx-utils/key.h>
#include <fcitx-utils/keysym.h>
#include <fcitx-utils/log.h>

namespace {

constexpr const char *kDefaultLexicon = "/usr/share/wowtype/lexicon.tsv";
constexpr const char *kDemoLexicon = "/usr/share/wowtype/demo_lexicon.tsv";

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

} // namespace

/// 每个输入上下文独立保存的缓冲区和候选。
class WowtypeState final : public fcitx::InputContextProperty {
public:
    std::string buffer_;
    std::vector<std::string> candidates_;
    std::vector<double> scores_;
};

WowtypeEngine::WowtypeEngine(fcitx::Instance *instance)
    : instance_(instance),
      core_(nullptr),
      factory_([](fcitx::InputContext &) {
          return new WowtypeState();
      }) {
    instance_->inputContextManager().registerProperty("wowtype", &factory_);

    std::string lexiconPath = kDefaultLexicon;
    if (const char *env = std::getenv("WOWTYPE_LEXICON")) {
        if (*env) {
            lexiconPath = env;
        }
    }
    std::error_code ec;
    if (!std::filesystem::exists(lexiconPath, ec)) {
        lexiconPath = kDemoLexicon;
    }

    const char *lmPath = std::getenv("WOWTYPE_LM");
    core_ = wowtype_engine_new(lexiconPath.c_str(), lmPath);
    if (core_) {
        if (const char *fuzzy = std::getenv("WOWTYPE_FUZZY");
            fuzzy && *fuzzy && *fuzzy != '0') {
            wowtype_engine_set_fuzzy(core_, 1);
        }
        if (const char *sp = std::getenv("WOWTYPE_SHUANGPIN");
            sp && *sp && *sp != '0') {
            wowtype_engine_set_shuangpin(core_, 1);
        }
        if (const char *tr = std::getenv("WOWTYPE_TRADITIONAL");
            tr && *tr && *tr != '0') {
            const char *s2t = std::getenv("WOWTYPE_S2T");
            const std::string path =
                (s2t && *s2t) ? std::string(s2t)
                              : std::string("/usr/share/wowtype/s2t.tsv");
            const int loaded = wowtype_engine_load_conversion(core_, path.c_str());
            if (loaded > 0) {
                wowtype_engine_set_traditional(core_, 1);
                FCITX_INFO() << "Wowtype: 载入简繁表 " << loaded << " 条";
            } else {
                FCITX_WARN() << "Wowtype: 简繁表载入失败 " << path;
            }
        }
        const std::string userDict = userDictPath();
        if (!userDict.empty()) {
            const int loaded = wowtype_engine_load_user_dict(core_, userDict.c_str());
            if (loaded > 0) {
                FCITX_INFO() << "Wowtype: 载入用户词 " << loaded << " 条";
            }
        }
    }
    if (!core_) {
        FCITX_ERROR() << "Wowtype: 初始化 Rust 核心失败，词典=" << lexiconPath
                      << "，错误="
                      << (wowtype_last_error() ? wowtype_last_error()
                                               : "unknown");
    }
}

WowtypeEngine::~WowtypeEngine() {
    if (core_) {
        const std::string userDict = userDictPath();
        if (!userDict.empty()) {
            wowtype_engine_save_user_dict(core_, userDict.c_str());
        }
        wowtype_engine_free(core_);
        core_ = nullptr;
    }
}

std::string WowtypeEngine::userDictPath() const {
    const char *env = std::getenv("WOWTYPE_USER_DICT");
    if (env && *env) {
        return env;
    }
    std::string base;
    if (const char *data = std::getenv("XDG_DATA_HOME"); data && *data) {
        base = data;
    } else if (const char *home = std::getenv("HOME"); home && *home) {
        base = std::string(home) + "/.local/share";
    } else {
        return {};
    }
    const std::string dir = base + "/wowtype";
    std::error_code ec;
    std::filesystem::create_directories(dir, ec);
    return dir + "/user.tsv";
}

void WowtypeEngine::commitText(fcitx::InputContext *ic, WowtypeState *state,
                               const std::string &text) {
    if (!ic || text.empty()) {
        return;
    }
    ic->commitString(text);
    if (core_) {
        wowtype_engine_record_selection(core_, text.c_str());
        // 上下文只保留尾部：bigram 特征只看紧邻的上文。
        recent_ += text;
        if (recent_.size() > 24) {
            recent_ = recent_.substr(recent_.size() - 24);
        }
        wowtype_engine_set_context(core_, recent_.c_str());
    }
    state->buffer_.clear();
    state->candidates_.clear();
    state->scores_.clear();
}

void WowtypeEngine::refreshCandidates(WowtypeState *state) {
    state->candidates_.clear();
    state->scores_.clear();
    if (!core_ || state->buffer_.empty()) {
        return;
    }

    WowtypeCandidates *raw =
        wowtype_engine_input(core_, state->buffer_.c_str());
    if (!raw) {
        return;
    }

    const std::size_t count = wowtype_candidates_len(raw);
    for (std::size_t i = 0; i < count; ++i) {
        const char *text = wowtype_candidates_text(raw, i);
        if (text) {
            state->candidates_.emplace_back(text);
            state->scores_.push_back(wowtype_candidates_score(raw, i));
        }
    }
    wowtype_candidates_free(raw);
}

void WowtypeEngine::updateInputPanel(fcitx::InputContext *ic,
                                     WowtypeState *state) {
    auto &panel = ic->inputPanel();
    panel.reset();

    if (state->buffer_.empty()) {
        ic->updatePreedit();
        ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
        return;
    }

    panel.setPreedit(fcitx::Text(state->buffer_));

    auto candidates = std::make_unique<fcitx::CommonCandidateList>();
    candidates->setLayoutHint(fcitx::CandidateLayoutHint::Vertical);
    candidates->setPageSize(9);
    for (std::size_t i = 0; i < state->candidates_.size(); ++i) {
        candidates->append<WowtypeCandidateWord>(this, state, i,
                                                state->candidates_[i]);
    }
    panel.setCandidateList(std::move(candidates));

    ic->updatePreedit();
    ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
}

void WowtypeEngine::commitCandidate(fcitx::InputContext *ic,
                                    WowtypeState *state, std::size_t index) {
    if (!ic || !state || index >= state->candidates_.size()) {
        return;
    }
    commitText(ic, state, state->candidates_[index]);
    updateInputPanel(ic, state);
}

void WowtypeEngine::keyEvent(const fcitx::InputMethodEntry & /*entry*/,
                             fcitx::KeyEvent &event) {
    if (event.isRelease()) {
        return;
    }

    auto *ic = event.inputContext();
    if (!ic) {
        return;
    }
    auto *state = ic->propertyFor(&factory_);
    const fcitx::Key key = event.key();
    const auto sym = key.sym();

    // 带 Ctrl/Alt/Super 的组合键交给应用或 fcitx 的其他处理器。
    if (key.states().test(fcitx::KeyState::Ctrl) ||
        key.states().test(fcitx::KeyState::Alt) ||
        key.states().test(fcitx::KeyState::Super)) {
        return;
    }

    if (sym == FcitxKey_BackSpace && !state->buffer_.empty()) {
        state->buffer_.pop_back();
        refreshCandidates(state);
        updateInputPanel(ic, state);
        event.filterAndAccept();
        return;
    }

    if (sym == FcitxKey_Escape && !state->buffer_.empty()) {
        state->buffer_.clear();
        state->candidates_.clear();
        state->scores_.clear();
        updateInputPanel(ic, state);
        event.filterAndAccept();
        return;
    }

    if (sym == FcitxKey_space && !state->buffer_.empty()) {
        if (!state->candidates_.empty()) {
            commitCandidate(ic, state, 0);
        } else {
            const std::string raw = state->buffer_;
            commitText(ic, state, raw);
            updateInputPanel(ic, state);
        }
        event.filterAndAccept();
        return;
    }

    if (sym == FcitxKey_Return && !state->buffer_.empty()) {
        const std::string raw = state->buffer_;
        commitText(ic, state, raw);
        updateInputPanel(ic, state);
        event.filterAndAccept();
        return;
    }

    if (sym >= FcitxKey_1 && sym <= FcitxKey_9) {
        if (!state->buffer_.empty()) {
            const auto index = static_cast<std::size_t>(sym - FcitxKey_1);
            if (index < state->candidates_.size()) {
                commitCandidate(ic, state, index);
            }
            event.filterAndAccept();
            return;
        }
    }

    // 翻页/移动（↑↓、PgUp/PgDn、-/=）交给候选列表自己处理。
    if (auto *list = ic->inputPanel().candidateList()) {
        if (list->size() > 0 && list->keyEvent(event)) {
            event.filterAndAccept();
            ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
            return;
        }
    }

    // 没有正在输入的拼音时，把 ASCII 标点转成中文标点。
    if (state->buffer_.empty()) {
        const char *punct = nullptr;
        switch (sym) {
        case FcitxKey_comma:
            punct = "，";
            break;
        case FcitxKey_period:
            punct = "。";
            break;
        case FcitxKey_question:
            punct = "？";
            break;
        case FcitxKey_exclam:
            punct = "！";
            break;
        case FcitxKey_semicolon:
            punct = "；";
            break;
        case FcitxKey_colon:
            punct = "：";
            break;
        default:
            break;
        }
        if (punct) {
            commitText(ic, state, punct);
            event.filterAndAccept();
            return;
        }
    }

    char input = 0;
    if (sym >= FcitxKey_a && sym <= FcitxKey_z) {
        input = static_cast<char>(sym);
    } else if (sym >= FcitxKey_A && sym <= FcitxKey_Z) {
        input = static_cast<char>('a' + (sym - FcitxKey_A));
    } else if (sym == FcitxKey_apostrophe) {
        input = '\'';
    }

    if (input != 0) {
        // 开头的隔音符没有意义，直接忽略。
        if (input == '\'' && state->buffer_.empty()) {
            return;
        }
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
    state->buffer_.clear();
    state->candidates_.clear();
    state->scores_.clear();
}

void WowtypeEngine::deactivate(const fcitx::InputMethodEntry &entry,
                               fcitx::InputContextEvent &event) {
    reset(entry, event);
}

void WowtypeEngine::reset(const fcitx::InputMethodEntry & /*entry*/,
                          fcitx::InputContextEvent &event) {
    auto *ic = event.inputContext();
    if (!ic) {
        return;
    }
    auto *state = ic->propertyFor(&factory_);
    state->buffer_.clear();
    state->candidates_.clear();
    state->scores_.clear();
    ic->inputPanel().reset();
    ic->updatePreedit();
    ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
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

FCITX_ADDON_FACTORY_V2(wowtype, WowtypeFactory)
