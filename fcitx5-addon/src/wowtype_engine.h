#ifndef WOWTYPE_FCITX5_ENGINE_H
#define WOWTYPE_FCITX5_ENGINE_H

#include <cstddef>
#include <string>
#include <vector>

#include <fcitx/inputcontextproperty.h>
#include <fcitx/inputmethodengine.h>

#include "wowtype_core.h"

namespace fcitx {
class Instance;
class InputContext;
class InputContextEvent;
class InputMethodEntry;
class KeyEvent;
} // namespace fcitx

class WowtypeState;

class WowtypeEngine final : public fcitx::InputMethodEngineV2 {
public:
    explicit WowtypeEngine(fcitx::Instance *instance);
    ~WowtypeEngine() override;

    void keyEvent(const fcitx::InputMethodEntry &entry,
                  fcitx::KeyEvent &event) override;
    void activate(const fcitx::InputMethodEntry &entry,
                  fcitx::InputContextEvent &event) override;
    void deactivate(const fcitx::InputMethodEntry &entry,
                    fcitx::InputContextEvent &event) override;
    void reset(const fcitx::InputMethodEntry &entry,
               fcitx::InputContextEvent &event) override;

    void updateInputPanel(fcitx::InputContext *ic, WowtypeState *state);
    void commitCandidate(fcitx::InputContext *ic, WowtypeState *state,
                         std::size_t index);

private:
    void refreshCandidates(WowtypeState *state);
    /// 统一的上屏入口：提交文本、记录选词、更新上下文。
    void commitText(fcitx::InputContext *ic, WowtypeState *state,
                    const std::string &text);
    std::string userDictPath() const;

    fcitx::Instance *instance_;
    WowtypeEngineHandle *core_;
    fcitx::FactoryFor<WowtypeState> factory_;
    /// 最近上屏的文本，用于上下文 bigram 特征（只保留尾部若干字符）。
    std::string recent_;
};

#endif /* WOWTYPE_FCITX5_ENGINE_H */
