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
    if (!core_) {
        FCITX_ERROR() << "Wowtype: 初始化 Rust 核心失败，词典=" << lexiconPath
                      << "，错误="
                      << (wowtype_last_error() ? wowtype_last_error()
                                               : "unknown");
    }
}

WowtypeEngine::~WowtypeEngine() {
    if (core_) {
        wowtype_engine_free(core_);
        core_ = nullptr;
    }
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
    ic->commitString(state->candidates_[index]);
    state->buffer_.clear();
    state->candidates_.clear();
    state->scores_.clear();
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
            ic->commitString(state->buffer_);
            state->buffer_.clear();
            updateInputPanel(ic, state);
        }
        event.filterAndAccept();
        return;
    }

    if (sym == FcitxKey_Return && !state->buffer_.empty()) {
        ic->commitString(state->buffer_);
        state->buffer_.clear();
        state->candidates_.clear();
        state->scores_.clear();
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
