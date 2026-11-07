#ifndef WOWTYPE_FCITX5_ENGINE_H
#define WOWTYPE_FCITX5_ENGINE_H

#include <cstddef>
#include <future>
#include <memory>
#include <string>
#include <vector>

#include <fcitx-config/configuration.h>
#include <fcitx-config/enum.h>
#include <fcitx-config/option.h>
#include <fcitx/inputcontextproperty.h>
#include <fcitx/inputmethodengine.h>
#include <fcitx-utils/event.h>
#include <fcitx-utils/key.h>
#include <fcitx-utils/keysym.h>
#include <fcitx-utils/trackableobject.h>

#include "wowtype_core.h"

namespace fcitx {
class Instance;
class InputContext;
class InputContextEvent;
class InputPanel;
class InputMethodEntry;
class KeyEvent;
} // namespace fcitx

class WowtypeState;

enum class WowtypeLayout { Horizontal, Vertical };
FCITX_CONFIG_ENUM_NAME(WowtypeLayout, "Horizontal", "Vertical");

/// 选项里显示中文（存盘仍是英文名）。
struct WowtypeLayoutAnnotation {
    bool skipDescription() const { return false; }
    bool skipSave() const { return false; }
    void dumpDescription(fcitx::RawConfig &config) const {
        config.setValueByPath("EnumI18n/0", "横排");
        config.setValueByPath("EnumI18n/1", "竖排");
    }
};

/// ~/.config/fcitx5/conf/wowtype.conf。fcitx5 配置工具和 wowtype-config 都改这个文件；
/// 同名环境变量（WOWTYPE_FUZZY 等）设了的话优先，方便测试。
FCITX_CONFIGURATION(
    WowtypeConfig,
    fcitx::Option<WowtypeLayout, fcitx::NoConstrain<WowtypeLayout>,
                  fcitx::DefaultMarshaller<WowtypeLayout>, WowtypeLayoutAnnotation>
        layout{this, "CandidateLayout", "候选排列", WowtypeLayout::Horizontal};
    fcitx::Option<int, fcitx::IntConstrain> pageSize{
        this, "PageSize", "每页候选个数", 9, fcitx::IntConstrain(3, 9)};
    fcitx::Option<bool> fuzzy{this, "Fuzzy",
                              "模糊音（z=zh、c=ch、s=sh，an=ang、en=eng、in=ing）", false};
    fcitx::Option<bool> typo{this, "TypoCorrection", "按错键自动纠正", true};
    fcitx::Option<bool> shuangpin{this, "Shuangpin", "双拼（自然码）", false};
    fcitx::Option<bool> traditional{this, "Traditional", "输出繁体字", false};
    fcitx::Option<bool> voice{this, "Voice", "语音输入", true};
    fcitx::Option<fcitx::Key, fcitx::KeyConstrain> voiceKey{
        this, "VoiceKey", "语音输入键（按住说话，或点一下开始）", fcitx::Key(FcitxKey_Alt_R),
        fcitx::KeyConstrain({fcitx::KeyConstrainFlag::AllowModifierOnly,
                             fcitx::KeyConstrainFlag::AllowModifierLess})};
    fcitx::Option<bool> checkUpdate{this, "CheckUpdate", "自动检查更新（一天最多一次）", true};
    fcitx::ExternalOption settings{this, "Settings", "自定义词和更多设置", "wowtype-config"};);

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

    const fcitx::Configuration *getConfig() const override { return &config_; }
    void setConfig(const fcitx::RawConfig &config) override;
    /// 重新读配置文件和自定义词（设置界面改完后经 D-Bus ReloadAddonConfig 调用）。
    void reloadConfig() override;

    void updateInputPanel(fcitx::InputContext *ic, WowtypeState *state);
    /// 选中第 index 个候选（全局下标）：整句候选直接上屏，
    /// 句首词候选先压进已选栈，剩下的拼音继续输入。
    void commitCandidate(fcitx::InputContext *ic, WowtypeState *state,
                         std::size_t index);
    /// 展开的候选面板里点了第 row 行：光标在这行就选光标处的词，否则选这行第一个。
    void selectGridRow(fcitx::InputContext *ic, WowtypeState *state, std::size_t row);

private:
    /// 词库在后台线程载入；载入好之前 core_ 为空，按键照常进编辑区。
    bool coreReady();
    /// 把配置（和环境变量覆盖）算成下面的 effective 值，按需建语音句柄。
    void applyConfig();
    /// 词库载入好以后，把开关和自定义词交给核心。
    void applyCoreSettings();
    std::string customWordsPath() const;
    bool isVoiceKey(const fcitx::Key &key) const;
    void refreshCandidates(WowtypeState *state);
    /// 展开的候选面板（下键展开）：处理了这个键返回 true。
    bool handleGridKey(fcitx::InputContext *ic, WowtypeState *state, const fcitx::Key &key);
    void fillGridPanel(fcitx::InputPanel &panel, WowtypeState *state);
    std::string segmentedRemaining(WowtypeState *state) const;
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

    // 语音输入：按住（或点一下）热键说话，识别结果上屏
    /// 处理了这个键（热键本身，或录音时的 Esc）就返回 true。
    bool handleVoiceKey(fcitx::InputContext *ic, WowtypeState *state,
                        fcitx::KeyEvent &event);
    /// 定时调用：刷新提示、上屏结果。还要继续轮询就返回 true。
    bool pollVoice();
    void showVoice(fcitx::InputContext *ic, const std::string &status,
                   const std::string &partial);
    void clearVoice();
    void cancelVoice();
    void maybeCheckUpdate();
    bool voiceActive() const { return voiceShowing_; }

    fcitx::Instance *instance_;
    WowtypeEngineHandle *core_;
    std::future<WowtypeEngineHandle *> loading_;
    fcitx::FactoryFor<WowtypeState> factory_;
    /// 最近上屏的文本，用于上下文 bigram 特征（只保留尾部若干字节，按字符边界截）。
    std::string recent_;
    /// 距离上次保存用户词库的上屏次数。
    int unsavedCommits_ = 0;

    WowtypeConfig config_;
    // 生效中的设置（配置文件 + 环境变量覆盖）
    bool horizontal_ = true;
    std::size_t pageSize_ = 9;
    bool fuzzy_ = false;
    bool typo_ = true;
    bool shuangpin_ = false;
    bool traditional_ = false;
    bool conversionLoaded_ = false;

    WowtypeVoice *voice_ = nullptr;
    /// 语音热键，默认右 Alt；FcitxKey_None 表示关掉语音。
    fcitx::Key voiceKey_;
    /// 热键按下还没松开（松开那一下也要吃掉，免得应用把单按 Alt 当成打开菜单）。
    bool voiceKeyDown_ = false;
    /// 这次 fcitx5 运行里查过更新没有（只在第一次切到 WowType 时查）。
    bool updateChecked_ = false;
    /// 正在显示语音提示（录音、识别中、出错提示）。
    bool voiceShowing_ = false;
    /// 出错提示显示到这个时刻（单调时钟，微秒）。
    uint64_t voiceErrorUntil_ = 0;
    /// 开始说话时的输入框；结果只往这里上屏。
    fcitx::TrackableObjectReference<fcitx::InputContext> voiceIc_;
    std::unique_ptr<fcitx::EventSourceTime> voiceTimer_;
    /// 最近几次轮询的音量（0–100），画成滚动的波形。
    std::vector<int> voiceLevels_;
    /// 轮询次数，「识别中」的省略号动画用。
    unsigned voiceFrame_ = 0;
};

#endif /* WOWTYPE_FCITX5_ENGINE_H */
