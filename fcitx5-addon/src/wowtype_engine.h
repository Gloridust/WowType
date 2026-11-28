#ifndef WOWTYPE_FCITX5_ENGINE_H
#define WOWTYPE_FCITX5_ENGINE_H

#include <chrono>
#include <cstdint>
#include <utility>
#include <cstddef>
#include <functional>
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
#include <fcitx-utils/handlertable.h>
#include <fcitx-utils/key.h>
#include <fcitx-utils/keysym.h>
#include <fcitx-utils/trackableobject.h>

#include "wowtype_core.h"

namespace fcitx {
class Instance;
class Event;
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

/// 打字途中方向键做什么（#129）。
enum class WowtypeArrowKeys { Candidates, Caret };
FCITX_CONFIG_ENUM_NAME(WowtypeArrowKeys, "Candidates", "Caret");

struct WowtypeArrowKeysAnnotation {
    bool skipDescription() const { return false; }
    bool skipSave() const { return false; }
    void dumpDescription(fcitx::RawConfig &config) const {
        config.setValueByPath("EnumI18n/0", "都用来选词");
        config.setValueByPath("EnumI18n/1", "左右键移动光标");
    }
};

/// 输入方案：全拼、双拼、五笔 86。
enum class WowtypeInputScheme { Quanpin, Shuangpin, Wubi86 };
FCITX_CONFIG_ENUM_NAME(WowtypeInputScheme, "Quanpin", "Shuangpin", "Wubi86");

struct WowtypeInputSchemeAnnotation {
    bool skipDescription() const { return false; }
    bool skipSave() const { return false; }
    void dumpDescription(fcitx::RawConfig &config) const {
        config.setValueByPath("EnumI18n/0", "拼音输入");
        config.setValueByPath("EnumI18n/1", "双拼输入");
        config.setValueByPath("EnumI18n/2", "五笔输入");
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

/// 换到新窗口、新应用时用什么模式（#254）：Same 保持当前，Chinese / English 定一次。
enum class WowtypeWindowMode { Same, Chinese, English };
FCITX_CONFIG_ENUM_NAME(WowtypeWindowMode, "Same", "Chinese", "English");

struct WowtypeWindowModeAnnotation {
    bool skipDescription() const { return false; }
    bool skipSave() const { return false; }
    void dumpDescription(fcitx::RawConfig &config) const {
        config.setValueByPath("EnumI18n/0", "和上次一样");
        config.setValueByPath("EnumI18n/1", "中文");
        config.setValueByPath("EnumI18n/2", "英文");
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
    fcitx::Option<WowtypeArrowKeys, fcitx::NoConstrain<WowtypeArrowKeys>,
                  fcitx::DefaultMarshaller<WowtypeArrowKeys>, WowtypeArrowKeysAnnotation>
        arrowKeys{this, "ArrowKeys", "方向键", WowtypeArrowKeys::Candidates};
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
    fcitx::Option<bool> fuzzyAnAi{this, "FuzzyAnAi", "模糊音：an = ai", false};
    fcitx::Option<bool> fuzzyHuangWang{this, "FuzzyHuangWang", "模糊音：huang = wang", false};
    fcitx::Option<bool> fuzzyUnIong{this, "FuzzyUnIong", "模糊音：un = iong", false};
    fcitx::Option<bool> fuzzyEngOng{this, "FuzzyEngOng", "模糊音：eng = ong", false};
    fcitx::Option<bool> typo{this, "TypoCorrection", "按错键自动纠正", true};
    fcitx::Option<bool> rareExt{this, "RareExtChars", "候选末尾列出扩展 B 区以后的生僻字", false};
    fcitx::Option<bool> inlineSpace{this, "InlineSpaceSeparator",
                                    "输入框里的拼音用空格分音节（网页代码块里留下半截拼音时打开）", false};
    fcitx::Option<WowtypeInputScheme, fcitx::NoConstrain<WowtypeInputScheme>,
                  fcitx::DefaultMarshaller<WowtypeInputScheme>, WowtypeInputSchemeAnnotation>
        inputScheme{this, "InputScheme", "输入方案", WowtypeInputScheme::Quanpin};
    fcitx::Option<WowtypeShuangpinScheme, fcitx::NoConstrain<WowtypeShuangpinScheme>,
                  fcitx::DefaultMarshaller<WowtypeShuangpinScheme>, WowtypeShuangpinAnnotation>
        shuangpinScheme{this, "ShuangpinScheme", "双拼方案", WowtypeShuangpinScheme::Ziranma};
    fcitx::Option<bool> shuangpinShowKeys{this, "ShuangpinShowKeys",
                                          "双拼时编辑区显示打的键（不翻成全拼）", false};
    fcitx::Option<bool> shuangpinAbbrev{this, "ShuangpinAbbrev",
                                        "双拼简拼（只打声母，sm 出「什么」）", true};
    fcitx::Option<bool> wubiAutoCommit{this, "WubiAutoCommit", "五笔四码唯一自动上屏", true};
    fcitx::Option<bool> wubiHint{this, "WubiHint", "五笔编码提示（候选后面显示还要打的码）", true};
    fcitx::Option<WowtypeShiftToggle, fcitx::NoConstrain<WowtypeShiftToggle>,
                  fcitx::DefaultMarshaller<WowtypeShiftToggle>, WowtypeShiftAnnotation>
        shiftToggle{this, "ShiftToggle", "单按 Shift 切换中英文", WowtypeShiftToggle::Both};
    fcitx::Option<WowtypeInitialMode, fcitx::NoConstrain<WowtypeInitialMode>,
                  fcitx::DefaultMarshaller<WowtypeInitialMode>, WowtypeInitialModeAnnotation>
        initialMode{this, "InitialMode", "切到 WowType 时", WowtypeInitialMode::Chinese};
    fcitx::Option<WowtypeWindowMode, fcitx::NoConstrain<WowtypeWindowMode>,
                  fcitx::DefaultMarshaller<WowtypeWindowMode>, WowtypeWindowModeAnnotation>
        windowMode{this, "WindowMode", "默认中/英文", WowtypeWindowMode::Same};
    fcitx::Option<bool> traditional{this, "Traditional", "输出繁体字", false};
    fcitx::Option<WowtypePunctStyle, fcitx::NoConstrain<WowtypePunctStyle>,
                  fcitx::DefaultMarshaller<WowtypePunctStyle>, WowtypePunctStyleAnnotation>
        punctStyle{this, "PunctuationStyle", "标点样式", WowtypePunctStyle::Fullwidth};
    fcitx::Option<WowtypeSelectKeys, fcitx::NoConstrain<WowtypeSelectKeys>,
                  fcitx::DefaultMarshaller<WowtypeSelectKeys>, WowtypeSelectKeysAnnotation>
        selectKeys{this, "SelectKeys", "分号、引号选词", WowtypeSelectKeys::Off};
    fcitx::Option<bool> pickChar{this, "PickChar",
                                 "以词定字：打拼音时 [ ] 上屏候选的第一个、最后一个字", true};
    fcitx::Option<bool> association{this, "Association",
                                    "联想：上屏以后给出常跟在后面的词（Tab 选，数字、空格照常）", false};
    fcitx::Option<bool> dateTime{this, "DateTime",
                                 "打 riqi、shijian、xingqi 时给出当前日期时间", true};
    fcitx::Option<bool> calculator{this, "Calculator", "v 开头算算式（v1+2*3；双拼、五笔时是大写 V）",
                                   true};
    fcitx::Option<bool> toolbar{this, "Toolbar",
                                "v + 空格打开工具栏（剪贴板、常用语、符号、表情；双拼、五笔时不开）",
                                true};
    // 默认关：fcitx5 的 clipboard 插件不告诉我们哪条是密码管理器复制的密码
    fcitx::Option<bool> clipboardHistory{this, "ClipboardHistory",
                                         "记录剪贴板历史（只在内存里，最多 20 条）", false};
    // 跨设备复制粘贴：一台设备上复制的文字，在配过对的另一台上直接粘贴。默认关（和剪贴板历史一样，
    // clipboard 插件不告诉我们哪条是密码管理器复制的密码）；配对在 WowType 设置里做
    fcitx::Option<bool> clipboardSync{this, "ClipboardSync",
                                      "跨设备复制粘贴（先在 WowType 设置里配对）", false};
    fcitx::Option<bool> clipboardSyncLan{this, "ClipboardSyncLan",
                                         "跨设备复制粘贴：同一个局域网里直接传", true};
    fcitx::Option<std::string> clipboardSyncRelayUrl{
        this, "ClipboardSyncRelayUrl", "跨设备复制粘贴：自己部署的中转服务地址（留空不用）", ""};
    fcitx::Option<std::string> clipboardSyncDeviceName{
        this, "ClipboardSyncDeviceName", "跨设备复制粘贴：这台设备的名字（留空用主机名）", ""};
    fcitx::Option<bool> clipboardSyncPaste{
        this, "ClipboardSyncPaste",
        "跨设备复制粘贴：收到的也放进系统剪贴板（能直接 Ctrl+V）", true};
    fcitx::Option<bool> autoSpace{this, "AutoSpace", "汉字和英文、数字之间自动加空格", false};
    fcitx::Option<bool> autoSpaceLetters{this, "AutoSpaceLetters", "汉字和英文字母之间", true};
    fcitx::Option<bool> autoSpaceDigits{this, "AutoSpaceDigits", "汉字和数字之间", true};
    fcitx::Option<bool> autoPairPunct{this, "AutoPairPunct",
                                      "中文标点自动配对（输入左标点自动补全右标点并移到中间）",
                                      false};
    fcitx::Option<bool> voice{this, "Voice", "语音输入", true};
    fcitx::Option<fcitx::Key, fcitx::KeyConstrain> voiceKey{
        this, "VoiceKey", "语音输入键（按住说话，或点一下开始）", fcitx::Key(FcitxKey_Alt_R),
        fcitx::KeyConstrain({fcitx::KeyConstrainFlag::AllowModifierOnly,
                             fcitx::KeyConstrainFlag::AllowModifierLess})};
    // 点按说话时没声音多久自动结束（毫秒，#285），0 不自动结束（再点一下语音键结束，最长录 2 分钟）。
    // WowType 设置里是「停顿多久自动结束」的下拉框（1.5、3、5、10、30 秒、不自动结束）
    fcitx::Option<int, fcitx::IntConstrain> voiceSilenceTimeout{
        this, "VoiceSilenceTimeout", "停顿多久自动结束（点按说话，毫秒；0 不自动结束）", 1500,
        fcitx::IntConstrain(0, 60000)};
    fcitx::Option<bool> voiceCopy{this, "VoiceCopy", "语音识别的结果同时复制到剪贴板", false};
    fcitx::Option<bool> emojiSuggest{this, "EmojiSuggest", "打字时推荐 emoji", true};
    fcitx::Option<fcitx::Key, fcitx::KeyConstrain> emojiKey{
        this, "EmojiKey", "打开表情面板的快捷键", fcitx::Key("Super+period"),
        fcitx::KeyConstrain(fcitx::KeyConstrainFlags{fcitx::KeyConstrainFlag::AllowModifierLess})};
    // 另设的快捷键（#143、#87），默认不用；单按 Shift 照常。fcitx5 自己的热键（比如切换输入法的
    // Ctrl+空格）先被 fcitx5 拿走，WowType 收不到，设置界面会提示。两个设成同一个键时算互译键
    fcitx::Option<fcitx::Key, fcitx::KeyConstrain> toggleKey{
        this, "ToggleKey", "切换中 / 英文的快捷键", fcitx::Key(),
        fcitx::KeyConstrain(fcitx::KeyConstrainFlags{fcitx::KeyConstrainFlag::AllowModifierLess})};
    fcitx::Option<fcitx::Key, fcitx::KeyConstrain> translateModeKey{
        this, "TranslateModeKey", "进出互译的快捷键（设了以后单按 Shift 只切中 / 英）", fcitx::Key(),
        fcitx::KeyConstrain(fcitx::KeyConstrainFlags{fcitx::KeyConstrainFlag::AllowModifierLess})};
    fcitx::Option<bool> checkUpdate{this, "CheckUpdate", "自动检查更新（最多一小时一次）", true};
    // 打字统计默认关；开了也只在本机记每天的计数（字数、按键次数），不记打的内容，见 docs/CONFIG.md
    fcitx::Option<bool> typingStats{this, "TypingStats",
                                    "打字统计（只在本机记每天的字数和按键次数，不记打的内容）", false};
    // 开发者模式默认关；开了以后核心把打的字、当时的候选、选了第几个明文记在本机，调排序用，见 docs/DEVLOG.md
    fcitx::Option<bool> developerMode{this, "DeveloperMode",
                                      "开发者模式（把打的字、候选和选了第几个明文记在本机，调试用）", false};
    // 互译：API Key 不放这里（这个文件谁都能读），在 ~/.config/wowtype/translate.key（0600）
    fcitx::Option<bool> translate{this, "Translate", "互译（打中文出外文，单按 Shift 或互译键切到「译」）",
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
    // 互译只翻一句（#191），默认关：关着时 Shift 照旧 中 → 英 → 译 → 中，双击 Shift 不切换
    fcitx::Option<bool> translateOneShot{
        this, "TranslateOneShot", "双击 Shift 单次互译（单按 Shift 只切中英，翻完一句自动回来）", false};
    // 本地模型（腾讯混元 Hy-MT3 1.8B）：第一次翻译时起 llama-server，闲置后停掉。
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
    clampWowtypeInt(config.voiceSilenceTimeout, raw, 0, 60000);
    if (!raw.valueByPath("TranslateLocal") &&
        (*config.translateBaseUrl).find_first_not_of(" \t\r\n") != std::string::npos) {
        config.translateLocal.setValue(false);
    }
    // 0.3.12 及以前的双拼开关：只在没有 InputScheme 时算。WowtypeConfig 里没有它，存盘时就没了
    const std::string *oldShuangpin = raw.valueByPath("Shuangpin");
    if (!raw.valueByPath("InputScheme") && oldShuangpin && *oldShuangpin == "True") {
        config.inputScheme.setValue(WowtypeInputScheme::Shuangpin);
    }
}

class WowtypeEngine;

/// 后台载入的结果：核心（失败是空的），还有哪个用户文件在、却没读出来。
struct WowtypeLoaded {
    WowtypeEngineHandle *core = nullptr;
    bool userDictUnread = false;
    bool historyUnread = false;
    /// 载入的整句增强模型（路径 + 大小 + 修改时间，没载入是空），reloadConfig 按它认模型换没换
    std::string nnlmStamp;
};

/// 会话总线上的 org.wowtype.Input：外部命令切中 / 英 / 译（vim 退出插入模式切英文，#98）。
///   busctl --user call org.wowtype.Input /org/wowtype/Input org.wowtype.Input1 SetMode s en
/// Version 返回正在跑的插件的版本：升级以后设置界面拿它和装好的版本比，不一样（或者没有这个方法，
/// 是 0.4.0 及以前的插件）就提醒重启输入法。
class WowtypeControl : public fcitx::dbus::ObjectVTable<WowtypeControl> {
public:
    explicit WowtypeControl(WowtypeEngine *engine) : engine_(engine) {}
    std::string mode();
    /// zh / en / translate / toggle（只在中英之间切），返回切完以后的模式。
    std::string setMode(const std::string &mode);
    std::string version();

private:
    WowtypeEngine *engine_;
    FCITX_OBJECT_VTABLE_METHOD(mode, "Mode", "", "s");
    FCITX_OBJECT_VTABLE_METHOD(setMode, "SetMode", "s", "s");
    FCITX_OBJECT_VTABLE_METHOD(version, "Version", "", "s");
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
    /// 状态栏、切换提示：「中文」「英文」「互译」，一个字的是「中」「英」「译」。
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
    /// 候选上点右键（#229）：第 index 个候选（全局下标）是学过的词，菜单里给「忘掉这个词」。
    bool canForgetCandidate(WowtypeState *state, std::size_t index) const;
    /// 右键菜单的「忘掉这个词」：忘掉第 index 个候选（全局下标），和光标在它上面按 Ctrl+Delete 一样，
    /// 忘掉了马上存，照会话重画（编辑区、页码、光标不动）。
    void forgetCandidate(fcitx::InputContext *ic, WowtypeState *state, std::size_t index);
    /// 点了工具栏 / 表情面板的第 index 项（会话做：菜单进下一层，别的上屏）。
    void choosePanelItem(fcitx::InputContext *ic, WowtypeState *state, std::size_t index);
    /// 展开的候选面板里点了第 row 行：光标在这行就选光标处的词，否则选这行第一个。
    void selectGridRow(fcitx::InputContext *ic, WowtypeState *state, std::size_t row);
    /// 工具栏 / 表情面板 / 展开面板的候选框上点了翻页按钮、滚了滚轮：和键盘上按 sym（Page Up /
    /// Page Down、上下键）一样交给会话，照会话的页和光标重画。面板的页码、光标只在会话里有一份。
    void panelListKey(fcitx::InputContext *ic, WowtypeState *state, fcitx::KeySym sym);
    /// 互译：上屏译文；还没译好就记下来，好了再上屏。

private:
    /// 一次上屏记进打字统计（只分类计数，不保存文字）。`frame` 带候选位置时一并记。
    void recordStats(fcitx::InputContext *ic, const std::string &text, const WowtypeFrame *frame);
    /// 记一次按键（按键热力图）。密码框里的按键不计。
    void recordKey(fcitx::InputContext *ic, const fcitx::Key &key, bool down);
    /// 把攒着的统计写进文件（失焦、退出时）。
    void flushStats();
    /// 当前输入模式在统计里的名字。
    std::string typingSource() const;
    /// 双拼方案在统计里的名字（小写枚举名）；不是双拼时为空。
    std::string typingScheme() const;
    /// 词库在后台线程载入；载入好之前 core_ 为空，按键照常进编辑区。
    bool coreReady();
    /// 后台载入完了（loading_ 已经就绪，或者愿意等）：收下核心和「哪个用户文件没读出来」。
    void takeLoaded();
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
    /// 设置里另设的切换键、互译键：WOWTYPE_KEY_ACTION_TOGGLE_*，都不是为 NONE。
    uint32_t modeKeyAction(const fcitx::Key &key) const;
    /// 能自己切中 / 英：单按 Shift 没关，或者另设了切换键。都没有时一直是中文（切过去就切不回来）。
    bool canToggleMode() const;
    /// 单按 Shift 切换中英文：处理了（切换了）返回 true。
    /// Shift 键交给会话判断单按（别的键只报一下，打断单按）。返回 true：这个键处理完了
    /// （Shift 键都是；单按切换了模式时吃掉，否则交给应用）。
    bool handleShiftKey(fcitx::InputContext *ic, WowtypeState *state, fcitx::KeyEvent &event);
    /// 会话自己切了模式（单按 Shift、切换键、互译键）：上屏它放进 frame 的字，全局的模式跟上。
    void followSessionMode(fcitx::InputContext *ic, WowtypeState *state, const WowtypeFrame *frame);
    /// 把全局的中 / 英 / 译对齐到这个输入框的会话（切英文时会话上屏打到一半的）。
    void syncMode(fcitx::InputContext *ic, WowtypeState *state);
    /// 按「切到 WowType 时」（InitialMode）定中 / 英：从别的输入法切回来、启动后第一次用时调。
    void applyInitialMode(fcitx::InputContext *ic, WowtypeState *state);
    /// 按「默认中/英文」（WindowMode）定中 / 英：换到新窗口、新应用时调（#254）。
    void applyWindowMode(fcitx::InputContext *ic, WowtypeState *state);
    /// 切到指定模式。离开「译」上屏攒着的原文，切到英文上屏打到一半的；
    /// notify：弹出「中 / 英 / 译」提示（外部命令切的不弹，免得 vim 每按一次 Esc 闪一下）。
    void switchMode(fcitx::InputContext *ic, WowtypeState *state, bool ascii, bool translate,
                    bool notify);

    // 互译模式：打的字先攒成原文，模型译好后上屏译文
    /// 现在的模式：「中文」「英文」「互译」；提示框和托盘上的一个字「中」「英」「译」。
    const char *modeTitle() const;
    const char *modeLabel() const;
    /// 现在是互译模式，而且这个输入框能用（密码框里不翻译、不往外发）。
    bool translating(fcitx::InputContext *ic) const;
    /// 这个输入框能翻译：不是密码框。
    static bool translatable(fcitx::InputContext *ic);
    bool translateAvailable() const;
    std::string translateKeyFile() const;
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
    void fillToolPanel(fcitx::InputContext *ic, WowtypeState *state);
    /// 剪贴板历史：从 fcitx5 的 clipboard 插件拿最新一条交给核心（没有这个插件就什么都不做）。
    void sampleClipboard(fcitx::InputContext *ic);
    /// fcitx5 的 clipboard 插件里最新的一条（还没复制过东西是空串）；现在读不了——密码框里、
    /// 没有输入框、没有这个插件——是 nullopt。
    std::optional<std::string> latestClipboard(fcitx::InputContext *ic);

    // 跨设备复制粘贴
    /// 配对文件（设备编号、组密钥），WowType 设置配对时写。
    std::string syncStateFile() const;
    /// 放中转服务访问口令的文件。
    std::string syncRelayKeyFile() const;
    /// 照设置起停同步（applyConfig 里调）。
    void applySync();
    /// 每秒一次：把本机剪贴板交给核心，取别的设备复制过来的。
    void tickSync();

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
    /// 应用里光标前一个字（Unicode 码位）：光标前没有字是 0，应用不报告周围文字时没有值。
    std::optional<uint32_t> prevChar(fcitx::InputContext *ic) const;
    /// 应用里光标后一个字。不报告周围文字、有选区、光标在报来的文字末尾（有的应用只报光标前的字）时没有值。
    std::optional<uint32_t> nextChar(fcitx::InputContext *ic) const;
    /// 这个键对应的 fcitx5 全局翻页、移动候选热键（方向键不算，照横排竖排的规则走）。
    uint32_t keyAction(const fcitx::Key &key) const;
    /// 会话处理了一个键以后：上屏、记 emoji、照会话的候选框重画（或只挪页码和光标）。
    void applySessionFrame(fcitx::InputContext *ic, WowtypeState *state,
                           const WowtypeFrame *frame);
    /// 候选由会话算，外壳抄一份画候选框（fcitx5 的候选框要整个列表），连同页码、光标。
    void refreshCandidates(WowtypeState *state);
    /// 会话的候选重算过才重新抄；返回 true 表示重抄了。页码、光标每次都抄。
    bool syncView(WowtypeState *state);
    void fillGridPanel(fcitx::InputContext *ic, WowtypeState *state);
    /// 上屏以后的联想行（会话的 WOWTYPE_PANEL_ASSOCIATION）。
    void fillAssociation(fcitx::InputPanel &panel, WowtypeState *state);
    std::string segmentedRemaining(WowtypeState *state);
    /// 会话上屏以后：上屏 frame->commit、清空外壳的状态；frame->learned 时攒着存用户词库。
    void finishCommit(fcitx::InputContext *ic, WowtypeState *state, const WowtypeFrame *frame);
    /// 会话这次调用里引擎学到了选词（frame->learned）就记一次，返回记了没有。会话给的每个 frame 都要过
    /// 一遍（finishCommit 里也是它）：「译」里选的词进了原文、没有要上屏的字，也是学到了。
    bool countLearned(const WowtypeFrame *frame);
    /// 上屏已选的词 + 还没选的原始输入（切输入法、打到一半切英文），原始输入也记一次选词。
    void commitInput(fcitx::InputContext *ic, WowtypeState *state);
    /// 选中光标所在的候选；没有候选时上屏原始输入（交给会话按一次空格）。
    void commitCurrent(fcitx::InputContext *ic, WowtypeState *state);
    /// 攒够上屏次数（force 时不管次数）就在后台存用户词库和输入习惯（按键的线程上不等磁盘）。
    /// wait：等后台写完再返回（析构、换词库前：新引擎要读这些文件）。
    void maybeSaveUserDict(bool force, bool wait = false);
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
    /// GNOME 下由 WowType 扩展画语音浮条、展开面板的网格：插件经 D-Bus 把状态发给它。
    void setupOverlays();
    /// 展开面板的网格（#270）：盯着扩展登记的名字，收回执和鼠标点的格子。
    void setupGridOverlay();
    /// 扩展在跑、而且没被认定画不出来：展开面板交给扩展画网格，kimpanel 只拿到一个空列表。
    bool gridOverlay() const { return overlayBus_ && !gridOwner_.empty() && !gridBroken_; }
    /// 把展开面板这一屏的格子发给扩展；header 是本来画在 kimpanel 上的提示和编辑区。
    void sendGridOverlay(fcitx::InputContext *ic, WowtypeState *state, const std::string &header);
    /// 让扩展收起网格（不再显示展开面板了）。
    void hideGridOverlay();
    /// 发出去的网格过了 kGridAckUsec 还没有回执：认定扩展画不出来，退回 kimpanel 画的列表。
    void checkGridAck();
    /// 扩展上点了一个格子（serial 是那一屏的编号，index 是全局下标）。
    void selectGridCell(uint32_t serial, uint32_t index);
    /// 扩展上右键点了一格、选了「忘掉这个词」（#229）。
    void forgetGridCell(uint32_t serial, uint32_t index);
    void pageGrid(uint32_t serial, int32_t delta);
    /// 输入框换了面板（收起、上屏、失去焦点）：网格跟着收起。
    void onGridUiEvent(fcitx::Event &event);
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
    std::future<WowtypeLoaded> loading_;
    /// 用户词库（user.tsv）/ 输入习惯（history.tsv）文件在、这次载入却没读出来：存之前先把原文件改名成
    /// <原名>.bad-<时间戳> 留着（maybeSaveUserDict），不然会被只有这次运行里学到的内容盖掉。
    bool userDictUnread_ = false;
    bool historyUnread_ = false;
    /// 正在用的整句增强模型（WowtypeLoaded::nnlmStamp）
    std::string nnlmStamp_;
    /// core_ / loading_ 用的词库文件，和配置要的词库文件（不一样就该换了）。
    std::string lexicon_;
    std::string wantedLexicon_;
    /// lexicon_ 载入时的 (大小, 修改时间)：同一个路径的文件被换掉（更新了词库包）也要重载。
    std::pair<std::uintmax_t, long long> lexiconStamp_{0, 0};
    fcitx::FactoryFor<WowtypeState> factory_;
    /// 距离上次保存用户词库，引擎学到了几次（上屏、「译」里选词进原文、忘掉学错的词）。
    int unsavedCommits_ = 0;

    WowtypeConfig config_;
    // 生效中的设置（配置文件 + 环境变量覆盖）
    bool horizontal_ = true;
    WowtypeArrowKeys arrowKeys_ = WowtypeArrowKeys::Candidates;
    std::size_t pageSize_ = 9;
    bool fuzzy_ = false;
    /// 打开的模糊音分组（位掩码，见 wowtype_engine_set_fuzzy_groups）。
    unsigned fuzzyGroups_ = 0;
    bool typo_ = true;
    bool rareExt_ = false;
    bool inlineSpace_ = false; // InlineSpaceSeparator：输入框里的拼音用空格分音节（#247）
    WowtypeSelectKeys selectKeys_ = WowtypeSelectKeys::Off;
    bool pickChar_ = true;
    bool association_ = false;
    bool dateTime_ = true;
    bool calculator_ = true;
    bool toolbar_ = true;
    bool clipboardHistory_ = false;
    /// 跨设备复制粘贴（核心没带 sync 特性时一直是 nullptr）
    WowtypeSync *sync_ = nullptr;
    bool syncEnabled_ = false;
    /// 收到的也放进系统剪贴板
    bool syncPaste_ = true;
    std::unique_ptr<fcitx::EventSourceTime> syncTimer_;
    /// 双拼时编辑区显示打的键（#122）
    bool shuangpinShowKeys_ = false;
    /// 双拼的简拼：每个键都是声母时也当简拼（sm -> 什么，#268）
    bool shuangpinAbbrev_ = true;
    /// 自动补空格（wowtype_autospace 的 flags）：1 字母、2 数字，0 关。
    int autoSpaceFlags_ = 0;
    /// 中文标点自动配对（AutoPairPunct）。
    bool autoPairPunct_ = false;
    bool shuangpin_ = false;
    /// 五笔（设置里选了五笔；码表在 applyCoreSettings 里载入，没载入时会话照全拼打并提示）。
    bool wubi_ = false;
    /// 现在的引擎载入了五笔码表。
    bool wubiLoaded_ = false;
    /// 配置文件里的双拼方案名（传给核心）。
    std::string shuangpinScheme_ = "Ziranma";
    WowtypeShiftToggle shiftToggle_ = WowtypeShiftToggle::Both;
    /// 双击 Shift 不切换（#253）；环境变量 WOWTYPE_SHIFT_DOUBLE_TAP=0 时单按立刻切
    bool shiftDoubleTap_ = true;
    WowtypeInitialMode initialMode_ = WowtypeInitialMode::Chinese;
    /// 换到新窗口、新应用时的默认模式（#254）；Same 不动，跟以前一样。
    WowtypeWindowMode windowMode_ = WowtypeWindowMode::Same;
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
    /// 进「译」之前的模式（WOWTYPE_MODE_*）：别的输入框里进的「译」，在这个输入框里按互译键也回到那儿。
    int translateFrom_ = WOWTYPE_MODE_CHINESE;
    bool traditional_ = false;
    bool conversionLoaded_ = false;
    bool emojiSuggest_ = true;
    /// 表情面板快捷键，FcitxKey_None 表示关掉。
    fcitx::Key emojiKey_;
    /// 另设的切换中 / 英文、进出「译」的快捷键，FcitxKey_None 表示不用。
    fcitx::Key toggleKey_;
    fcitx::Key translateModeKey_;
    /// 最近用过的 emoji（最近的在前），存在 ~/.local/share/wowtype/emoji-recent.txt。

    /// 打字统计（按天聚合，见 core/src/stats.rs）；数据目录找不到时为空。TypingStats 关着时记录器什么都不做。
    WowtypeStats *stats_ = nullptr;
    bool typingStats_ = false;
    /// 开发者模式（DeveloperMode，默认关）：开着时核心把每次选词、上屏记进 devlog.jsonl（core/src/devlog.rs）。
    bool developerMode_ = false;

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

    // 自动配对（AutoPairPunct）要发给应用的键：挪光标（frame->cursor_delta）和成对删（frame->delete_next）。
    // 都走 sendAppKeys 一条路按顺序发；上屏后挪光标的那几下攒在 pendingCursorDelta_ 里，等上屏落到应用
    // （kCursorDelayUsec 以后，或者下一个键来的时候先发）
    fcitx::TrackableObjectReference<fcitx::InputContext> cursorTarget_;
    /// 还没发的光标挪动（负数左移），几次的加在一起。
    int pendingCursorDelta_ = 0;
    std::unique_ptr<fcitx::EventSourceTime> cursorTimer_;
    /// 上次自己给应用发键的输入框和时刻（单调时钟，微秒）：GTK 挪光标、删字时会重置输入法，
    /// 紧跟着自己发的键来的重置不算用户点了别处
    fcitx::TrackableObjectReference<fcitx::InputContext> appKeysTarget_;
    uint64_t appKeysAtUsec_ = 0;
    /// 这次按键开头刚把攒着的光标挪动发出去：应用报的周围文字还是挪之前的，不能拿来核对
    bool surroundingStale_ = false;
    /// frame 要挪光标就攒上；afterCommit：这次上屏了字，等上屏落到应用再发，不然（前面没有攒着的时）马上发。
    void applyCursorDelta(fcitx::InputContext *ic, const WowtypeFrame *frame, bool afterCommit);
    /// 把攒着的光标挪动发出去。发了返回 true。
    bool flushCursorDelta();
    /// 不发攒着的光标挪动（应用重置了输入法、失去焦点：光标已经在别处）。
    void dropCursorDelta(fcitx::InputContext *ic);
    /// 给应用发 count 下 sym（按下、松开）。
    void sendAppKeys(fcitx::InputContext *ic, fcitx::KeySym sym, int count);
    /// 会话没接的键要成对删（frame->delete_next）：吃掉这个退格，按顺序发 Delete、退格。删了返回 true。
    bool pairDelete(fcitx::InputContext *ic, const WowtypeFrame *frame, fcitx::KeyEvent &event);
    /// 这次重置是应用对自己刚发的键的反应（GTK 挪光标、删字时会重置输入法），不是用户点了别处。
    bool resetFromOwnKeys(fcitx::InputContext *ic) const;

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

    // 展开面板的网格（GNOME 扩展画，#270），和语音浮条共用 overlayBus_。
    // 每发一屏 serial 加一，扩展画好了回 Ack(serial)；最早一个没回执的发出去的时刻是 gridPendingSince_，
    // 等不到就把 gridBroken_ 置上、退回 kimpanel 的列表；之后迟到的回执（扩展只是慢）再把它清掉。
    std::unique_ptr<fcitx::dbus::ServiceWatcherEntry> gridWatch_;
    std::unique_ptr<fcitx::dbus::Slot> gridAckSlot_;
    std::unique_ptr<fcitx::dbus::Slot> gridSelectSlot_;
    std::unique_ptr<fcitx::dbus::Slot> gridForgetSlot_;
    std::unique_ptr<fcitx::dbus::Slot> gridPageSlot_;
    std::string gridOwner_;
    uint32_t gridSerial_ = 0;
    uint32_t gridAckedSerial_ = 0;
    uint64_t gridPendingSince_ = 0;
    bool gridBroken_ = false;
    /// 网格现在画在哪个输入框上（空：没在显示）。
    fcitx::TrackableObjectReference<fcitx::InputContext> gridIc_;
    std::unique_ptr<fcitx::EventSourceTime> gridAckTimer_;
    std::vector<std::unique_ptr<fcitx::HandlerTableEntry<std::function<void(fcitx::Event &)>>>>
        gridEventWatchers_;

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
