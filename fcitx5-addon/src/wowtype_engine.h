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
#include <fcitx-utils/dbus/bus.h>
#include <fcitx-utils/dbus/servicewatcher.h>
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
class Text;
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

enum class WowtypeShuangpinScheme { Ziranma, Xiaohe, Microsoft, Sogou, ABC, Ziguang, PinyinJiajia };
FCITX_CONFIG_ENUM_NAME(WowtypeShuangpinScheme, "Ziranma", "Xiaohe", "Microsoft", "Sogou", "ABC",
                       "Ziguang", "PinyinJiajia");

struct WowtypeShuangpinAnnotation {
    bool skipDescription() const { return false; }
    bool skipSave() const { return false; }
    void dumpDescription(fcitx::RawConfig &config) const {
        const char *names[] = {"自然码", "小鹤双拼", "微软双拼", "搜狗双拼",
                               "智能 ABC", "紫光双拼", "拼音加加"};
        for (int i = 0; i < 7; ++i) {
            config.setValueByPath("EnumI18n/" + std::to_string(i), names[i]);
        }
    }
};

/// 分号、引号选第 2、3 个候选。
enum class WowtypeSelectKeys { Off, Semicolon, SemicolonQuote };
FCITX_CONFIG_ENUM_NAME(WowtypeSelectKeys, "Off", "Semicolon", "SemicolonQuote");

struct WowtypeSelectKeysAnnotation {
    bool skipDescription() const { return false; }
    bool skipSave() const { return false; }
    void dumpDescription(fcitx::RawConfig &config) const {
        config.setValueByPath("EnumI18n/0", "不用");
        config.setValueByPath("EnumI18n/1", "分号选第 2 个");
        config.setValueByPath("EnumI18n/2", "分号选第 2 个、引号选第 3 个（引号不再当隔音符）");
    }
};

/// 单按哪个 Shift 切换中英文。
enum class WowtypeShiftToggle { Both, Left, Right, Off };
FCITX_CONFIG_ENUM_NAME(WowtypeShiftToggle, "Both", "Left", "Right", "Off");

struct WowtypeShiftAnnotation {
    bool skipDescription() const { return false; }
    bool skipSave() const { return false; }
    void dumpDescription(fcitx::RawConfig &config) const {
        config.setValueByPath("EnumI18n/0", "左右 Shift 都行");
        config.setValueByPath("EnumI18n/1", "左 Shift");
        config.setValueByPath("EnumI18n/2", "右 Shift");
        config.setValueByPath("EnumI18n/3", "不用 Shift 切换");
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
    fcitx::Option<bool> fuzzy{this, "Fuzzy", "模糊音（下面几组分别开关）", false};
    fcitx::Option<bool> fuzzyZh{this, "FuzzyZh", "模糊音：z = zh", true};
    fcitx::Option<bool> fuzzyCh{this, "FuzzyCh", "模糊音：c = ch", true};
    fcitx::Option<bool> fuzzySh{this, "FuzzySh", "模糊音：s = sh", true};
    fcitx::Option<bool> fuzzyNL{this, "FuzzyNL", "模糊音：n = l", false};
    fcitx::Option<bool> fuzzyFH{this, "FuzzyFH", "模糊音：f = h", false};
    fcitx::Option<bool> fuzzyRL{this, "FuzzyRL", "模糊音：r = l", false};
    fcitx::Option<bool> fuzzyAn{this, "FuzzyAn", "模糊音：an = ang（ian = iang、uan = uang）", true};
    fcitx::Option<bool> fuzzyEn{this, "FuzzyEn", "模糊音：en = eng", true};
    fcitx::Option<bool> fuzzyIn{this, "FuzzyIn", "模糊音：in = ing", true};
    fcitx::Option<bool> typo{this, "TypoCorrection", "按错键自动纠正", true};
    fcitx::Option<bool> shuangpin{this, "Shuangpin", "双拼输入", false};
    fcitx::Option<WowtypeShuangpinScheme, fcitx::NoConstrain<WowtypeShuangpinScheme>,
                  fcitx::DefaultMarshaller<WowtypeShuangpinScheme>, WowtypeShuangpinAnnotation>
        shuangpinScheme{this, "ShuangpinScheme", "双拼方案", WowtypeShuangpinScheme::Ziranma};
    fcitx::Option<WowtypeShiftToggle, fcitx::NoConstrain<WowtypeShiftToggle>,
                  fcitx::DefaultMarshaller<WowtypeShiftToggle>, WowtypeShiftAnnotation>
        shiftToggle{this, "ShiftToggle", "单按 Shift 切换中英文", WowtypeShiftToggle::Both};
    fcitx::Option<bool> traditional{this, "Traditional", "输出繁体字", false};
    fcitx::Option<WowtypeSelectKeys, fcitx::NoConstrain<WowtypeSelectKeys>,
                  fcitx::DefaultMarshaller<WowtypeSelectKeys>, WowtypeSelectKeysAnnotation>
        selectKeys{this, "SelectKeys", "分号、引号选词", WowtypeSelectKeys::Off};
    fcitx::Option<bool> dateTime{this, "DateTime",
                                 "打 riqi、shijian、xingqi 时给出当前日期时间", true};
    fcitx::Option<bool> calculator{this, "Calculator", "v 开头算算式（v1+2*3，只在全拼下）",
                                   true};
    fcitx::Option<bool> voice{this, "Voice", "语音输入", true};
    fcitx::Option<fcitx::Key, fcitx::KeyConstrain> voiceKey{
        this, "VoiceKey", "语音输入键（按住说话，或点一下开始）", fcitx::Key(FcitxKey_Alt_R),
        fcitx::KeyConstrain({fcitx::KeyConstrainFlag::AllowModifierOnly,
                             fcitx::KeyConstrainFlag::AllowModifierLess})};
    fcitx::Option<bool> emojiSuggest{this, "EmojiSuggest", "打字时推荐 emoji", true};
    fcitx::Option<fcitx::Key, fcitx::KeyConstrain> emojiKey{
        this, "EmojiKey", "打开表情面板的快捷键", fcitx::Key("Super+period"),
        fcitx::KeyConstrain(fcitx::KeyConstrainFlags{fcitx::KeyConstrainFlag::AllowModifierLess})};
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
    /// 英文模式时状态栏、切换提示里显示「英」。
    std::string subMode(const fcitx::InputMethodEntry &entry,
                        fcitx::InputContext &ic) override;
    std::string subModeLabelImpl(const fcitx::InputMethodEntry &entry,
                                 fcitx::InputContext &ic) override;

    const fcitx::Configuration *getConfig() const override { return &config_; }
    void setConfig(const fcitx::RawConfig &config) override;
    /// 重新读配置文件和自定义词（设置界面改完后经 D-Bus ReloadAddonConfig 调用）。
    void reloadConfig() override;

    void updateInputPanel(fcitx::InputContext *ic, WowtypeState *state);
    /// 预编辑去向：全局开关（「在程序中显示预编辑文本」）打开且应用申报
    /// Preedit 能力时送进应用输入框（on-the-spot），否则画在候选窗顶部。
    void sendPreedit(fcitx::InputContext *ic, const fcitx::Text &preedit);
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
    bool isEmojiKey(const fcitx::Key &key) const;
    /// 单按 Shift 切换中英文：处理了（切换了）返回 true。
    bool handleShiftToggle(fcitx::InputContext *ic, WowtypeState *state,
                           fcitx::KeyEvent &event);
    void toggleAsciiMode(fcitx::InputContext *ic, WowtypeState *state);
    /// 双拼方案用分号当键（微软、搜狗、紫光的 ing），且现在正等第二个键。
    bool semicolonIsKey(WowtypeState *state) const;
    /// 分号/引号选词：这个键要选第几个候选（1 起），不选返回 0。
    int selectKeyIndex(fcitx::KeySym sym) const;
    /// V 模式计算器：编辑区是 v + 算式（或刚打了 v）。
    bool calcActive(WowtypeState *state) const;
    /// 打 riqi / shijian 等时，把当前日期时间插到首选后面。
    void addDateTimeCandidates(WowtypeState *state, const std::string &input);
    /// 上屏不学习的候选（日期时间、计算结果、自定义编码等）。
    void commitPlainCandidate(fcitx::InputContext *ic, WowtypeState *state, std::size_t index);

    // 表情面板（快捷键打开，打拼音或英文搜 emoji 和符号）
    void openEmojiPanel(fcitx::InputContext *ic, WowtypeState *state);
    void closeEmojiPanel(fcitx::InputContext *ic, WowtypeState *state);
    void refreshEmojiPanel(WowtypeState *state);
    /// 面板开着时的按键，处理了返回 true。
    bool handleEmojiPanelKey(fcitx::InputContext *ic, WowtypeState *state,
                             const fcitx::Key &key);
    /// 首选候选对得上 emoji 时，插到候选列表里。
    void addEmojiSuggestions(WowtypeState *state, const std::string &input);
    void addKeycapSuggestion(WowtypeState *state, const std::string &input);
    /// 上屏选中的 emoji 候选（打字推荐的或面板里的）。
    void commitEmoji(fcitx::InputContext *ic, WowtypeState *state, std::size_t index);
    void rememberEmoji(const std::string &emoji);
    std::string recentEmojiPath() const;
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
    /// done：识别完了（语音浮条显示「识别完成」再淡出），否则直接收起。
    void clearVoice(bool done = false);
    void cancelVoice();
    /// GNOME 下由 WowType 扩展画语音浮条：插件经 D-Bus 把状态发给它。
    void setupVoiceOverlay();
    bool voiceOverlay() const { return !overlayOwner_.empty(); }
    void sendVoiceOverlay(fcitx::InputContext *ic, uint32_t state, const std::string &label,
                          int level);
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
    /// 打开的模糊音分组（位掩码，见 wowtype_engine_set_fuzzy_groups）。
    unsigned fuzzyGroups_ = 0;
    bool typo_ = true;
    WowtypeSelectKeys selectKeys_ = WowtypeSelectKeys::Off;
    bool dateTime_ = true;
    bool calculator_ = true;
    bool shuangpin_ = false;
    /// 配置文件里的双拼方案名（传给核心）。
    std::string shuangpinScheme_ = "Ziranma";
    bool shuangpinSemicolon_ = false;
    WowtypeShiftToggle shiftToggle_ = WowtypeShiftToggle::Both;
    /// 英文模式：按键原样交给应用（中英文切换全局生效，切到别的窗口也保持）。
    bool asciiMode_ = false;
    /// 按下还没松开的 Shift（单按才切换，中间按了别的键就作废）和按下的时刻。
    fcitx::KeySym shiftDown_ = FcitxKey_None;
    uint64_t shiftDownAt_ = 0;
    bool traditional_ = false;
    bool conversionLoaded_ = false;
    bool emojiSuggest_ = true;
    /// 表情面板快捷键，FcitxKey_None 表示关掉。
    fcitx::Key emojiKey_;
    /// 最近用过的 emoji（最近的在前），存在 ~/.local/share/wowtype/emoji-recent.txt。
    std::vector<std::string> recentEmoji_;
    bool recentEmojiLoaded_ = false;

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

    // 语音浮条（GNOME 扩展画）：单独一条会话总线连接，盯着扩展注册的名字
    std::unique_ptr<fcitx::dbus::Bus> overlayBus_;
    std::unique_ptr<fcitx::dbus::ServiceWatcher> overlayWatcher_;
    std::unique_ptr<fcitx::dbus::ServiceWatcherEntry> overlayWatch_;
    /// 扩展在总线上的唯一名；空表示扩展没在跑，用候选框里的文字提示。
    std::string overlayOwner_;
};

#endif /* WOWTYPE_FCITX5_ENGINE_H */
