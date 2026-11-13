#ifndef WOWTYPE_FCITX5_ENGINE_H
#define WOWTYPE_FCITX5_ENGINE_H

#include <chrono>
#include <cstdint>
#include <utility>
#include <cstddef>
#include <future>
#include <memory>
#include <optional>
#include <cstdlib>
#include <string>
#include <vector>

#include <fcitx-config/configuration.h>
#include <fcitx-config/enum.h>
#include <fcitx-config/option.h>
#include <fcitx-config/rawconfig.h>
#include <fcitx/inputcontextproperty.h>
#include <fcitx/inputmethodengine.h>
#include <fcitx-utils/dbus/bus.h>
#include <fcitx-utils/dbus/matchrule.h>
#include <fcitx-utils/dbus/objectvtable.h>
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

/// v + 空格打开的工具栏里现在是哪一页（符号、表情直接用表情面板）。

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

/// 标点样式：中文标点 / ASCII 标点。
enum class WowtypePunctStyle { Fullwidth, Halfwidth };
FCITX_CONFIG_ENUM_NAME(WowtypePunctStyle, "Fullwidth", "Halfwidth");

struct WowtypePunctStyleAnnotation {
    bool skipDescription() const { return false; }
    bool skipSave() const { return false; }
    void dumpDescription(fcitx::RawConfig &config) const {
        config.setValueByPath("EnumI18n/0", "全角（中文标点）");
        config.setValueByPath("EnumI18n/1", "半角（英文标点）");
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

/// 切到 WowType 时用中文还是英文（#158、#121）。
enum class WowtypeInitialMode { Chinese, English, Last };
FCITX_CONFIG_ENUM_NAME(WowtypeInitialMode, "Chinese", "English", "Last");

struct WowtypeInitialModeAnnotation {
    bool skipDescription() const { return false; }
    bool skipSave() const { return false; }
    void dumpDescription(fcitx::RawConfig &config) const {
        config.setValueByPath("EnumI18n/0", "中文");
        config.setValueByPath("EnumI18n/1", "英文");
        config.setValueByPath("EnumI18n/2", "和上次切走时一样");
    }
};

/// 互译语言（代码和核心的 translate::LANGUAGES 一致）。
enum class WowtypeTranslateTarget { en, ja, ko, fr, de, es, ru, pt, it, vi, th, id, ar };
FCITX_CONFIG_ENUM_NAME(WowtypeTranslateTarget, "en", "ja", "ko", "fr", "de", "es", "ru", "pt",
                       "it", "vi", "th", "id", "ar");

struct WowtypeTranslateTargetAnnotation {
    bool skipDescription() const { return false; }
    bool skipSave() const { return false; }
    void dumpDescription(fcitx::RawConfig &config) const {
        const char *names[] = {"英语", "日语",   "韩语",   "法语", "德语", "西班牙语", "俄语",
                               "葡萄牙语", "意大利语", "越南语", "泰语", "印尼语", "阿拉伯语"};
        for (int i = 0; i < 13; ++i) {
            config.setValueByPath("EnumI18n/" + std::to_string(i), names[i]);
        }
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
    fcitx::Option<bool> pageKeysMinus{this, "PageKeysMinusEqual", "翻页键：- =", true};
    fcitx::Option<bool> pageKeysBracket{this, "PageKeysBracket", "翻页键：[ ]", false};
    fcitx::Option<bool> pageKeysComma{this, "PageKeysCommaPeriod", "翻页键：, .", false};
    fcitx::Option<bool> pageKeysTab{this, "PageKeysTab", "翻页键：Shift+Tab Tab", false};
    fcitx::Option<bool> fuzzy{this, "Fuzzy", "模糊音（下面几组分别开关）", false};
    fcitx::Option<bool> fuzzyZh{this, "FuzzyZh", "模糊音：z = zh", true};
    fcitx::Option<bool> fuzzyCh{this, "FuzzyCh", "模糊音：c = ch", true};
    fcitx::Option<bool> fuzzySh{this, "FuzzySh", "模糊音：s = sh", true};
    fcitx::Option<bool> fuzzyNL{this, "FuzzyNL", "模糊音：n = l", false};
    fcitx::Option<bool> fuzzyFH{this, "FuzzyFH", "模糊音：f = h", false};
    fcitx::Option<bool> fuzzyRL{this, "FuzzyRL", "模糊音：r = l", false};
    fcitx::Option<bool> fuzzyAn{this, "FuzzyAn", "模糊音：an = ang", true};
    fcitx::Option<bool> fuzzyEn{this, "FuzzyEn", "模糊音：en = eng", true};
    fcitx::Option<bool> fuzzyIn{this, "FuzzyIn", "模糊音：in = ing", true};
    fcitx::Option<bool> fuzzyIan{this, "FuzzyIan", "模糊音：ian = iang", true};
    fcitx::Option<bool> fuzzyUan{this, "FuzzyUan", "模糊音：uan = uang", true};
    fcitx::Option<bool> fuzzyUn{this, "FuzzyUn", "模糊音：un = ong", false};
    fcitx::Option<bool> typo{this, "TypoCorrection", "按错键自动纠正", true};
    fcitx::Option<bool> rareExt{this, "RareExtChars", "候选末尾列出扩展 B 区以后的生僻字", false};
    fcitx::Option<bool> shuangpin{this, "Shuangpin", "双拼输入", false};
    fcitx::Option<WowtypeShuangpinScheme, fcitx::NoConstrain<WowtypeShuangpinScheme>,
                  fcitx::DefaultMarshaller<WowtypeShuangpinScheme>, WowtypeShuangpinAnnotation>
        shuangpinScheme{this, "ShuangpinScheme", "双拼方案", WowtypeShuangpinScheme::Ziranma};
    fcitx::Option<bool> shuangpinShowKeys{this, "ShuangpinShowKeys",
                                          "双拼时编辑区显示打的键（不翻成全拼）", false};
    fcitx::Option<WowtypeShiftToggle, fcitx::NoConstrain<WowtypeShiftToggle>,
                  fcitx::DefaultMarshaller<WowtypeShiftToggle>, WowtypeShiftAnnotation>
        shiftToggle{this, "ShiftToggle", "单按 Shift 切换中英文", WowtypeShiftToggle::Both};
    fcitx::Option<WowtypeInitialMode, fcitx::NoConstrain<WowtypeInitialMode>,
                  fcitx::DefaultMarshaller<WowtypeInitialMode>, WowtypeInitialModeAnnotation>
        initialMode{this, "InitialMode", "切到 WowType 时", WowtypeInitialMode::Chinese};
    fcitx::Option<bool> traditional{this, "Traditional", "输出繁体字", false};
    fcitx::Option<WowtypePunctStyle, fcitx::NoConstrain<WowtypePunctStyle>,
                  fcitx::DefaultMarshaller<WowtypePunctStyle>, WowtypePunctStyleAnnotation>
        punctStyle{this, "PunctuationStyle", "标点样式", WowtypePunctStyle::Fullwidth};
    fcitx::Option<WowtypeSelectKeys, fcitx::NoConstrain<WowtypeSelectKeys>,
                  fcitx::DefaultMarshaller<WowtypeSelectKeys>, WowtypeSelectKeysAnnotation>
        selectKeys{this, "SelectKeys", "分号、引号选词", WowtypeSelectKeys::Off};
    fcitx::Option<bool> pickChar{this, "PickChar",
                                 "以词定字：打拼音时 [ ] 上屏候选的第一个、最后一个字", true};
    fcitx::Option<bool> dateTime{this, "DateTime",
                                 "打 riqi、shijian、xingqi 时给出当前日期时间", true};
    fcitx::Option<bool> calculator{this, "Calculator", "v 开头算算式（v1+2*3，只在全拼下）",
                                   true};
    fcitx::Option<bool> toolbar{this, "Toolbar",
                                "v + 空格打开工具栏（剪贴板、常用语、符号、表情，只在全拼下）",
                                true};
    // 默认关：fcitx5 的 clipboard 插件不告诉我们哪条是密码管理器复制的密码
    fcitx::Option<bool> clipboardHistory{this, "ClipboardHistory",
                                         "记录剪贴板历史（只在内存里，最多 20 条）", false};
    fcitx::Option<bool> autoSpace{this, "AutoSpace", "汉字和英文、数字之间自动加空格", false};
    fcitx::Option<bool> autoSpaceLetters{this, "AutoSpaceLetters", "汉字和英文字母之间", true};
    fcitx::Option<bool> autoSpaceDigits{this, "AutoSpaceDigits", "汉字和数字之间", true};
    fcitx::Option<bool> voice{this, "Voice", "语音输入", true};
    fcitx::Option<fcitx::Key, fcitx::KeyConstrain> voiceKey{
        this, "VoiceKey", "语音输入键（按住说话，或点一下开始）", fcitx::Key(FcitxKey_Alt_R),
        fcitx::KeyConstrain({fcitx::KeyConstrainFlag::AllowModifierOnly,
                             fcitx::KeyConstrainFlag::AllowModifierLess})};
    fcitx::Option<bool> voiceCopy{this, "VoiceCopy", "语音识别的结果同时复制到剪贴板", false};
    fcitx::Option<bool> emojiSuggest{this, "EmojiSuggest", "打字时推荐 emoji", true};
    fcitx::Option<fcitx::Key, fcitx::KeyConstrain> emojiKey{
        this, "EmojiKey", "打开表情面板的快捷键", fcitx::Key("Super+period"),
        fcitx::KeyConstrain(fcitx::KeyConstrainFlags{fcitx::KeyConstrainFlag::AllowModifierLess})};
    fcitx::Option<bool> checkUpdate{this, "CheckUpdate", "自动检查更新（最多一小时一次）", true};
    // 互译：API Key 不放这里（这个文件谁都能读），在 ~/.config/wowtype/translate.key（0600）
    fcitx::Option<bool> translate{this, "Translate", "互译（Shift 切到「译」，打中文出外文）",
                                  false};
    fcitx::Option<WowtypeTranslateTarget, fcitx::NoConstrain<WowtypeTranslateTarget>,
                  fcitx::DefaultMarshaller<WowtypeTranslateTarget>,
                  WowtypeTranslateTargetAnnotation>
        translateTarget{this, "TranslateTarget", "互译语言", WowtypeTranslateTarget::en};
    fcitx::Option<std::string> translateBaseUrl{this, "TranslateBaseUrl",
                                                "翻译服务地址（OpenAI 格式，如 https://api.openai.com/v1）",
                                                ""};
    fcitx::Option<std::string> translateModel{this, "TranslateModel", "翻译用的模型", ""};
    fcitx::Option<bool> translateFormal{this, "TranslateFormal", "译文用正式语气（默认聊天口吻）",
                                        false};
    // 本地模型（腾讯 HY-MT 1.5 1.8B）：第一次翻译时起 llama-server，闲置后停掉。
    // 默认用本地模型；旧配置文件里没写这一项时见 loadWowtypeConfig
    fcitx::Option<bool> translateLocal{this, "TranslateLocal", "用本地模型翻译（HY-MT，离线）",
                                       true};
    fcitx::Option<std::string> translateLocalModel{
        this, "TranslateLocalModel", "本地模型文件（留空用 WowType 设置下载的）", ""};
    fcitx::Option<std::string> translateLlamaServer{
        this, "TranslateLlamaServer", "llama-server 路径（留空在 PATH 里找）", ""};
    fcitx::Option<int, fcitx::IntConstrain> translateIdleMinutes{
        this, "TranslateIdleMinutes", "本地模型闲置几分钟后释放内存（0 不释放）", 5,
        fcitx::IntConstrain(0, 240)};
    // 词库文件（拼音<TAB>词<TAB>频次）。WowType 设置里切换「万象」时写成
    // ~/.local/share/wowtype/dicts/wanxiang/lexicon.tsv；文件不在就用默认的
    fcitx::Option<std::string> lexicon{this, "Lexicon", "词库文件（留空用自带的雾凇词库）", ""};
    fcitx::ExternalOption settings{this, "Settings", "自定义词和更多设置", "wowtype-config"};);

/// 键名、默认值、范围、可选值以 spec/config.json 为准（设置契约），改这里要先改规格；
/// fcitx5-addon/test/config_dump.cpp 把上面的导出来，scripts/test-config-contract.py 对照。

/// 把 wowtype.conf 读成的 RawConfig 装进 config，文件里没写的项是默认值（和 fcitx::readAsIni 一样）。
/// 0.3.10 及以前没有 TranslateLocal：文件里没写这一项、TranslateBaseUrl 又填了的，接着用翻译接口（False）。
/// 这条规矩三端一样（settings/wowtype-config 的 read_config、macOS 的 WowtypeConfig.parse）。
/// 数字项超出范围时夹到边上（三端一样，见 spec/config.json 的 readRules.outOfRange）。
/// fcitx5 自己的 IntConstrain 是不认、回到默认值；认不出的数字（abc、空的）还是默认值。
inline void clampWowtypeInt(fcitx::Option<int, fcitx::IntConstrain> &option, const fcitx::RawConfig &raw,
                            int min, int max) {
    const std::string *text = raw.valueByPath(option.path());
    if (!text || text->empty()) {
        return;
    }
    char *end = nullptr;
    const long long n = std::strtoll(text->c_str(), &end, 10);
    if (end == text->c_str() || *end != '\0') {
        return;
    }
    if (n < min) {
        option.setValue(min);
    } else if (n > max) {
        option.setValue(max);
    }
}

/// 去掉两边的空格和 Tab（fcitx5 读文件时值前面的空格会留着：「Key=  值」读成「  值」）。
inline std::string trimWowtypeValue(const std::string &text) {
    const auto begin = text.find_first_not_of(" \t");
    if (begin == std::string::npos) {
        return "";
    }
    return text.substr(begin, text.find_last_not_of(" \t") - begin + 1);
}

/// 最上面一层的设置项，键和值两边的空格去掉（三端一样：「PageSize = 5」读成 5，见 spec/config.json 的 readRules）。
/// [分组]（[Hotkey] 等）是带子项的，不是设置项，不要。
inline fcitx::RawConfig wowtypeTopLevel(const fcitx::RawConfig &raw) {
    fcitx::RawConfig out;
    for (const auto &key : raw.subItems()) {
        auto item = raw.get(key);
        if (!item || !item->subItems().empty()) {
            continue;
        }
        out.setValueByPath(trimWowtypeValue(key), trimWowtypeValue(item->value()));
    }
    return out;
}

inline void loadWowtypeConfig(WowtypeConfig &config, const fcitx::RawConfig &file) {
    const fcitx::RawConfig raw = wowtypeTopLevel(file);
    config.load(raw);
    // 范围和上面 IntConstrain 的一样；不一样时契约测试（PageSize=12 读成 9）会报错
    clampWowtypeInt(config.pageSize, raw, 3, 9);
    clampWowtypeInt(config.translateIdleMinutes, raw, 0, 240);
    if (!raw.valueByPath("TranslateLocal") &&
        (*config.translateBaseUrl).find_first_not_of(" \t\r\n") != std::string::npos) {
        config.translateLocal.setValue(false);
    }
}

class WowtypeEngine;

/// 会话总线上的 org.wowtype.Input：外部命令切中 / 英 / 译（vim 退出插入模式切英文，#98）。
///   busctl --user call org.wowtype.Input /org/wowtype/Input org.wowtype.Input1 SetMode s en
class WowtypeControl : public fcitx::dbus::ObjectVTable<WowtypeControl> {
public:
    explicit WowtypeControl(WowtypeEngine *engine) : engine_(engine) {}
    std::string mode();
    /// zh / en / translate / toggle（只在中英之间切），返回切完以后的模式。
    std::string setMode(const std::string &mode);

private:
    WowtypeEngine *engine_;
    FCITX_OBJECT_VTABLE_METHOD(mode, "Mode", "", "s");
    FCITX_OBJECT_VTABLE_METHOD(setMode, "SetMode", "s", "s");
};

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
    /// 编辑区画在应用的输入框里（应用支持、全局设置也开着）。
    bool inlinePreedit(fcitx::InputContext *ic) const;
    /// 选中第 index 个候选（全局下标）：整句候选直接上屏，
    /// 句首词候选先压进已选栈，剩下的拼音继续输入。
    void commitCandidate(fcitx::InputContext *ic, WowtypeState *state,
                         std::size_t index);
    /// 点了工具栏 / 表情面板的第 index 项（会话做：菜单进下一层，别的上屏）。
    void choosePanelItem(fcitx::InputContext *ic, WowtypeState *state, std::size_t index);
    /// 展开的候选面板里点了第 row 行：光标在这行就选光标处的词，否则选这行第一个。
    void selectGridRow(fcitx::InputContext *ic, WowtypeState *state, std::size_t row);
    /// 互译：上屏译文；还没译好就记下来，好了再上屏。

private:
    /// 词库在后台线程载入；载入好之前 core_ 为空，按键照常进编辑区。
    bool coreReady();
    /// 配置里换了词库：存好用户词、清掉各输入框的编辑状态，在后台换新词库。
    /// 上一次载入还没完就先记着，载完再换（不在主线程上等）。
    void maybeSwitchLexicon();
    /// 把配置（和环境变量覆盖）算成下面的 effective 值，按需建语音句柄。
    void applyConfig();
    /// 词库载入好以后，把开关和自定义词交给核心。
    void applyCoreSettings();
    std::string customWordsPath() const;
    bool isVoiceKey(const fcitx::Key &key) const;
    bool isEmojiKey(const fcitx::Key &key) const;
    /// 单按 Shift 切换中英文：处理了（切换了）返回 true。
    /// Shift 键交给会话判断单按（别的键只报一下，打断单按）。返回 true：这个键处理完了
    /// （Shift 键都是；单按切换了模式时吃掉，否则交给应用）。
    bool handleShiftKey(fcitx::InputContext *ic, WowtypeState *state, fcitx::KeyEvent &event);
    /// 把全局的中 / 英 / 译对齐到这个输入框的会话（切英文时会话上屏打到一半的）。
    void syncMode(fcitx::InputContext *ic, WowtypeState *state);
    /// 按「切到 WowType 时」（InitialMode）定中 / 英：从别的输入法切回来、启动后第一次用时调。
    void applyInitialMode(fcitx::InputContext *ic, WowtypeState *state);
    /// 切到指定模式。离开「译」上屏攒着的原文，切到英文上屏打到一半的；
    /// notify：弹出「中 / 英 / 译」提示（外部命令切的不弹，免得 vim 每按一次 Esc 闪一下）。
    void switchMode(fcitx::InputContext *ic, WowtypeState *state, bool ascii, bool translate,
                    bool notify);

    // 互译模式：打的字先攒成原文，模型译好后上屏译文
    /// 现在是互译模式，而且这个输入框能用（密码框里不翻译、不往外发）。
    bool translating(fcitx::InputContext *ic) const;
    bool translateAvailable() const;
    std::string translateKeyFile() const;
    /// 上屏一段文字：互译模式下攒进原文，否则直接交给应用。所有上屏都走这里。
    /// autoSpace：要不要按光标前的字补空格（会话上屏的已经补过了，传 false）。
    void emit(fcitx::InputContext *ic, const std::string &text, bool autoSpace = true);
    /// 上屏 next 之前要不要先补一个空格（光标前是汉字、next 是字母数字，或反过来）。
    bool needsAutoSpace(fcitx::InputContext *ic, const std::string &next) const;
    /// 直接交给应用的字母、数字（英文模式、不在打字时的数字）：要补空格就自己上屏。
    bool autoSpaceKey(fcitx::InputContext *ic, const fcitx::Key &key);
    /// 原文原样上屏（Shift+回车、离开互译模式）。
    void clearTranslation(WowtypeState *state);
    /// 单调时钟的毫秒数（会话的 time_ms、tick 用）。
    static uint64_t nowMs();
    /// 过 ms 毫秒叫一次会话的 tick（会话的 frame->wake_after_ms：等发请求、等译文）。
    void scheduleTick(fcitx::InputContext *ic, uint32_t ms);
    /// 定时器到了：tick 会话，按过回车且译好了的上屏，结果变了重画。返回多久以后再叫（0 不用）。
    uint32_t tickTranslate();
    /// 现在画的互译内容（变了才重画）。
    std::string translateSignature(const WowtypeFrame *frame) const;
    /// 照微信输入法：译文直接写在应用的输入框里（编辑区），候选框当原文框
    /// （顶上是方向，下面是原文和正在打的拼音，拼音候选照常列在下面）。
    /// 只设编辑区和提示行，不动候选列表。
    void fillTranslateView(fcitx::InputContext *ic, WowtypeState *state, fcitx::InputPanel &panel);

    // 表情面板（快捷键打开，打拼音或英文搜 emoji 和符号）
    void fillToolPanel(fcitx::InputPanel &panel, WowtypeState *state);
    /// 剪贴板历史：从 fcitx5 的 clipboard 插件拿最新一条交给核心（没有这个插件就什么都不做）。
    void sampleClipboard(fcitx::InputContext *ic);

public:

private:
    std::string recentEmojiPath() const;
    /// 把引擎、上文、设置同步给会话（引擎是后台载入的，设置可能刚改过）。
    void syncSession(WowtypeState *state);
    /// 同步后交给会话处理一个按下的键；action 是 WOWTYPE_KEY_ACTION_*（fcitx5 全局的翻页、
    /// 移动候选热键）。返回会话的 frame（会话没建好时为 NULL）。
    /// 带上应用里光标前的字（prevChar）和输入框情况（密码框、互译时不自动补空格）。
    const WowtypeFrame *sessionKey(fcitx::InputContext *ic, WowtypeState *state,
                                   const fcitx::Key &key,
                                   uint32_t action = WOWTYPE_KEY_ACTION_NONE);
    /// 应用里光标前一个字（Unicode 码位）；应用不报告周围文字时 0。
    uint32_t prevChar(fcitx::InputContext *ic) const;
    /// 这个键对应的 fcitx5 全局翻页、移动候选热键（方向键不算，照横排竖排的规则走）。
    uint32_t keyAction(const fcitx::Key &key) const;
    /// 会话处理了一个键以后：上屏、记 emoji、照会话的候选框重画（或只挪页码和光标）。
    void applySessionFrame(fcitx::InputContext *ic, WowtypeState *state,
                           const WowtypeFrame *frame);
    /// 候选由会话算，外壳抄一份画候选框（fcitx5 的候选框要整个列表），连同页码、光标。
    void refreshCandidates(WowtypeState *state);
    /// 会话的候选重算过才重新抄；返回 true 表示重抄了。页码、光标每次都抄。
    bool syncView(WowtypeState *state);
    void fillGridPanel(fcitx::InputPanel &panel, WowtypeState *state);
    std::string segmentedRemaining(WowtypeState *state);
    /// 会话上屏以后：上屏 frame->commit、清空外壳的状态、记上文；frame->learned 时攒着存用户词库。
    void finishCommit(fcitx::InputContext *ic, WowtypeState *state, const WowtypeFrame *frame);
    /// 上屏已选的词 + 还没选的原始输入（切输入法、打到一半切英文），原始输入也记一次选词。
    void commitInput(fcitx::InputContext *ic, WowtypeState *state);
    /// 上屏一段与拼音无关的文本（标点等），只更新上下文。
    void commitPlain(fcitx::InputContext *ic, const std::string &text);
    /// 选中光标所在的候选；没有候选时上屏原始输入（交给会话按一次空格）。
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
    /// 在会话总线上登记 org.wowtype.Input（外部命令切模式）。
    void setupControl();
    /// 扩展在跑、而且没被认定画不出来（#170）：语音提示交给浮条。
    bool voiceOverlay() const { return !overlayOwner_.empty() && !overlayBroken_; }
    void sendVoiceOverlay(fcitx::InputContext *ic, uint32_t state, const std::string &label,
                          int level);
    /// 发了状态一直等不到扩展的回执：认定浮条画不出来，这次和以后都在候选框里提示。
    void checkOverlayAck(fcitx::InputContext *ic);
    void maybeCheckUpdate();
    bool voiceActive() const { return voiceShowing_; }

    fcitx::Instance *instance_;
    WowtypeEngineHandle *core_;
    std::future<WowtypeEngineHandle *> loading_;
    /// core_ / loading_ 用的词库文件，和配置要的词库文件（不一样就该换了）。
    std::string lexicon_;
    std::string wantedLexicon_;
    /// lexicon_ 载入时的 (大小, 修改时间)：同一个路径的文件被换掉（更新了词库包）也要重载。
    std::pair<std::uintmax_t, long long> lexiconStamp_{0, 0};
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
    bool rareExt_ = false;
    WowtypeSelectKeys selectKeys_ = WowtypeSelectKeys::Off;
    bool pickChar_ = true;
    bool dateTime_ = true;
    bool calculator_ = true;
    bool toolbar_ = true;
    bool clipboardHistory_ = false;
    /// 双拼时编辑区显示打的键（#122）
    bool shuangpinShowKeys_ = false;
    /// 自动补空格（wowtype_autospace 的 flags）：1 字母、2 数字，0 关。
    int autoSpaceFlags_ = 0;
    bool shuangpin_ = false;
    /// 配置文件里的双拼方案名（传给核心）。
    std::string shuangpinScheme_ = "Ziranma";
    WowtypeShiftToggle shiftToggle_ = WowtypeShiftToggle::Both;
    WowtypeInitialMode initialMode_ = WowtypeInitialMode::Chinese;
    /// 启动后还没切到过 WowType：第一次切过来（包括 WowType 是默认输入法时第一次获得焦点）按 InitialMode 定模式
    bool initialModeApplied_ = false;
    WowtypePunctStyle punctStyle_ = WowtypePunctStyle::Fullwidth;
    /// 打开的翻页键组（Page Up/Down、方向键、fcitx 全局翻页键一直可用）
    bool pageMinus_ = true;
    bool pageBracket_ = false;
    bool pageComma_ = false;
    bool pageTab_ = false;
    /// 英文模式：按键原样交给应用（中英文切换全局生效，切到别的窗口也保持）。
    bool asciiMode_ = false;
    /// 互译模式（和英文模式一样全局生效）。
    bool translateMode_ = false;
    bool traditional_ = false;
    bool conversionLoaded_ = false;
    bool lm2Loaded_ = false;
    bool emojiSuggest_ = true;
    /// 表情面板快捷键，FcitxKey_None 表示关掉。
    fcitx::Key emojiKey_;
    /// 最近用过的 emoji（最近的在前），存在 ~/.local/share/wowtype/emoji-recent.txt。

    WowtypeVoice *voice_ = nullptr;
    /// 语音结果同时复制到剪贴板（默认关）。
    bool voiceCopy_ = false;
    /// 语音热键，默认右 Alt；FcitxKey_None 表示关掉语音。
    fcitx::Key voiceKey_;
    /// 热键按下还没松开（松开那一下也要吃掉，免得应用把单按 Alt 当成打开菜单）。
    bool voiceKeyDown_ = false;
    /// 这次 fcitx5 运行里查过更新没有（只在第一次切到 WowType 时查）。
    std::optional<std::chrono::steady_clock::time_point> updateCheckedAt_;
    /// 正在显示语音提示（录音、识别中、出错提示）。
    bool voiceShowing_ = false;
    /// 出错提示显示到这个时刻（单调时钟，微秒）。
    uint64_t voiceErrorUntil_ = 0;
    /// 正在显示的出错提示（浮条要接着发）。
    std::string voiceErrorText_;
    /// 开始说话时的输入框；结果只往这里上屏。
    fcitx::TrackableObjectReference<fcitx::InputContext> voiceIc_;
    std::unique_ptr<fcitx::EventSourceTime> voiceTimer_;
    /// 最近几次轮询的音量（0–100），画成滚动的波形。
    std::vector<int> voiceLevels_;
    /// 轮询次数，「识别中」的省略号动画用。
    unsigned voiceFrame_ = 0;

    // 互译
    WowtypeTranslator *translator_ = nullptr;
    bool translateEnabled_ = false;
    /// 正在翻译的输入框（同一时间只译一个输入框的原文）。
    fcitx::TrackableObjectReference<fcitx::InputContext> translateIc_;
    std::unique_ptr<fcitx::EventSourceTime> translateTimer_;
    /// 到这个时刻（单调时钟，微秒）发请求；0 表示不用发。
    /// 上次画面板时的结果，没变就不重画。
    std::string translateDrawn_;

    // 语音浮条（GNOME 扩展画）：单独一条会话总线连接，盯着扩展注册的名字
    std::unique_ptr<fcitx::dbus::Bus> overlayBus_;
    std::unique_ptr<fcitx::dbus::ServiceWatcher> overlayWatcher_;
    std::unique_ptr<fcitx::dbus::ServiceWatcherEntry> overlayWatch_;
    /// 扩展在总线上的唯一名；空表示扩展没在跑，用候选框里的文字提示。
    std::string overlayOwner_;
    /// 扩展画好一次状态回一个 Ack。这次说话发出第一个状态的时间、收到回执没有；
    /// 等不到就把 overlayBroken_ 置上，直到扩展换了人（重新登录、扩展重载）。
    std::unique_ptr<fcitx::dbus::Slot> overlayAckSlot_;
    uint64_t overlaySentAt_ = 0;
    bool overlayAcked_ = false;
    bool overlayBroken_ = false;

    // 外部命令切模式：单独一条会话总线连接。control_ 要先于总线析构，所以排在后面
    std::unique_ptr<fcitx::dbus::Bus> controlBus_;
    std::unique_ptr<WowtypeControl> control_;

public:
    /// 现在的模式：zh / en / translate。
    std::string modeName() const;
    /// 外部命令切模式（WowtypeControl 调）；不认识的模式、没配翻译时切「译」返回 false。
    bool setModeByName(const std::string &mode);
};

#endif /* WOWTYPE_FCITX5_ENGINE_H */
