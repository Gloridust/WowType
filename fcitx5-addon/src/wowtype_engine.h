#ifndef WOWTYPE_FCITX5_ENGINE_H
#define WOWTYPE_FCITX5_ENGINE_H

#include <cstddef>
#include <future>
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
    /// 选中第 index 个候选（全局下标）：整句候选直接上屏，
    /// 句首词候选先压进已选栈，剩下的拼音继续输入。
    void commitCandidate(fcitx::InputContext *ic, WowtypeState *state,
                         std::size_t index);

private:
    /// 词库在后台线程载入；载入好之前 core_ 为空，按键照常进编辑区。
    bool coreReady();
    void refreshCandidates(WowtypeState *state);
    /// 上屏：已选的词 + tail 一起提交，记录选词、更新上下文，清空状态。
    void commitAll(fcitx::InputContext *ic, WowtypeState *state,
                   const std::string &tail, const std::string &tailPinyin);
    /// 上屏一段与拼音无关的文本（标点等），只更新上下文。
    void commitPlain(fcitx::InputContext *ic, const std::string &text);
    /// 选中光标所在的候选；没有候选时上屏原始输入。
    void commitCurrent(fcitx::InputContext *ic, WowtypeState *state);
    void rememberContext(const std::string &text);
    void maybeSaveUserDict(bool force);
    std::string userDictPath() const;

    fcitx::Instance *instance_;
    WowtypeEngineHandle *core_;
    std::future<WowtypeEngineHandle *> loading_;
    fcitx::FactoryFor<WowtypeState> factory_;
    /// 最近上屏的文本，用于上下文 bigram 特征（只保留尾部若干字节，按字符边界截）。
    std::string recent_;
    /// 距离上次保存用户词库的上屏次数。
    int unsavedCommits_ = 0;
};

#endif /* WOWTYPE_FCITX5_ENGINE_H */
