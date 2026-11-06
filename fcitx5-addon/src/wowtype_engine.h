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

    fcitx::Instance *instance_;
    WowtypeEngineHandle *core_;
    fcitx::FactoryFor<WowtypeState> factory_;
};

#endif /* WOWTYPE_FCITX5_ENGINE_H */
