#pragma once

// 组字：按键交给核心的输入会话（wowtype_session_*），按会话给的 frame 更新编辑区、候选框、上屏。
//
// 这是 macOS 的 Shared/Composer.swift（加上 Toolbar.swift 里画工具栏的部分）的 C++ 版，一行一行对着写的：
// 输入行为都在核心的会话里（docs/ABI.md「输入会话」），这里只决定哪些键交给会话、照 frame 画、上屏、
// 排互译的定时器。三端行为一样靠的是同一个会话，外壳不自己判断按键的含义。
//
// 不依赖 windows.h：TSF 外壳（tsf/text_service.cpp）实现 TextClient，按键测试（windows/tests/composer_test.cpp）
// 用一个假的 TextClient，在 Linux 和 Windows 上都跑。

#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <vector>

#include "config.h"
#include "keys.h"
#include "wowtype_core.h"

namespace wowtype {

/// 候选框要画的东西（会话给的这一页，或展开面板的这一屏）。
struct CandidatePage {
    std::vector<std::string> texts;
    /// 每个候选后面的小字（五笔还要打的码），和 texts 一样长；没有的是空串
    std::vector<std::string> comments;
    /// 光标在 texts 里的第几个；-1 不在这一页上
    int cursor = -1;
    bool hasPrev = false;
    bool hasNext = false;
    /// 展开面板、表情面板：每行 columns 个
    bool expanded = false;
    /// 候选上方的一行提示（工具栏、表情面板、五笔空码、切换中 / 英的提示）；texts 可以是空的，只画提示
    std::optional<std::string> aux;
    /// 竖排：一行一个
    bool vertical = false;
    /// 候选前面画序号。上屏以后的联想没按 Tab 进联想行时不画
    bool labels = true;
    /// 互译时候选上下多出来的两行
    struct Translate {
        std::string title;  // 「中→英 互译：」
        std::string source; // 攒着的原文 + 正在打的
        std::string status; // 翻译中、出错原因、怎么上屏；空串不画
        bool operator==(const Translate &o) const {
            return title == o.title && source == o.source && status == o.status;
        }
    };
    std::optional<Translate> translate;
    static constexpr int columns = 6;

    bool operator==(const CandidatePage &o) const {
        return texts == o.texts && comments == o.comments && cursor == o.cursor && hasPrev == o.hasPrev &&
               hasNext == o.hasNext && expanded == o.expanded && aux == o.aux && vertical == o.vertical &&
               labels == o.labels && translate == o.translate;
    }
};

/// 外壳要实现的：往输入框里写字、画编辑区和候选框。字符串都是 UTF-8。
class TextClient {
public:
    virtual ~TextClient() = default;
    /// 上屏（同时清掉编辑区）。
    virtual void insertText(const std::string &text) = 0;
    /// 编辑区；空串表示清掉。cursorBytes 是 UTF-8 字节偏移（会话给的），外壳自己换成 UTF-16。
    virtual void setMarkedText(const std::string &text, int cursorBytes) = 0;
    /// 画候选框；nullptr 表示收起。
    virtual void showCandidates(const CandidatePage *page) = 0;
    /// 光标前一个字符（Unicode 码位），不知道给 0。
    virtual uint32_t previousCharacter() = 0;
    /// previousCharacter 是应用告诉的（不是外壳猜的）。自动加空格只信应用告诉的。
    virtual bool previousCharacterIsReliable() { return true; }
    /// 能把打的字发去翻译（密码框不能）。
    virtual bool allowsTranslation() { return true; }
    /// 输入框的情况（WOWTYPE_KEY_HINT_NO_AUTO_SPACE、_NO_LEARN 这些），每个键都带上。
    virtual uint32_t inputHints() { return 0; }
    /// 能按位置改应用里的字（自动配对要挪光标、删补好的右半边）。
    virtual bool canEditAroundCaret() { return false; }
    /// 应用里光标后一个字；不知道是 nullopt。
    virtual std::optional<uint32_t> nextCharacter() { return std::nullopt; }
    /// 刚上屏以后把光标挪 delta 个字（负数往左）。改不了返回 false。
    virtual bool moveCaret(int /*delta*/) { return false; }
    /// 空的一对按退格：光标前后各删一个字。改不了返回 false（退格照常交给应用）。
    virtual bool deletePair() { return false; }
};

class Composer {
public:
    enum class Mode { Chinese, English, Translate };
    /// 开着的工具栏 / 表情面板（WOWTYPE_TOOL_*）
    enum class Panel { None, Menu, Clipboard, Phrases, Symbols, Emoji };

    Composer(WowtypeEngineHandle *engine, TextClient *client);
    ~Composer();
    Composer(const Composer &) = delete;
    Composer &operator=(const Composer &) = delete;

    // ---- 回调（外壳挂上）
    /// 上屏里有引擎学到的选词时调用（frame->learned；外壳攒够次数存一次学习数据）。
    std::function<void(const std::string &)> onCommit;
    /// 每次真正上屏时调用（text, source, scheme, candidateIndex），给打字统计用；只分类计数，不保存文字。
    /// candidateIndex 是选中的候选位置（1 起），0 表示不是选候选（和 macOS 的 onCommitStats 一样）。
    std::function<void(const std::string &, const std::string &, const std::string &, int)> onCommitStats;
    /// Ctrl+Delete 忘掉了学错的词以后调用（外壳马上存学习数据）。
    std::function<void()> onForget;
    /// 打开工具栏的剪贴板页时调用：外壳看一眼系统剪贴板，有新的交给 wowtype_clipboard_remember。
    std::function<void()> sampleClipboard;
    /// 会话要外壳过 ms 毫秒以后调 pollTranslation（互译去抖、等译文、单按 Shift 等双击）。
    std::function<void(uint32_t ms)> onTranslatePoll;
    /// 单调时钟（毫秒），测试里换成假的。
    std::function<uint64_t()> clock;

    // ---- 状态
    Mode mode() const;
    const Config &config() const { return config_; }
    bool hasEngine() const { return engine_ != nullptr; }
    WowtypeEngineHandle *engine() const { return engine_; }
    bool isComposing() const;
    std::string input() const;
    std::string translateSource() const;
    /// 输入法手里还有没上屏的字：正在打的拼音，或者互译攒着的原文。
    bool hasPendingText() const { return isComposing() || !translateSource().empty(); }
    Panel openPanel() const;
    bool translateAvailable() const;
    bool translating() const;
    bool canToggleMode() const;
    /// 外部命令里模式的叫法（zh、en、translate）。
    std::string modeName() const;
    /// 全部候选（不分页），测试用。
    std::vector<std::string> allCandidates() const;

    // ---- 外壳调
    void setClient(TextClient *client) { client_ = client; }
    void setEngine(WowtypeEngineHandle *engine);
    void apply(const Config &config);
    /// 用核心的翻译器（和 Linux 一样，curl 发请求），nullptr 去掉。翻译器要比 Composer 活得久。
    void setTranslator(WowtypeTranslator *translator);

    /// 处理一次按下；返回 true 表示吃掉了这个键（不交给应用）。
    bool handle(const KeyInput &key);
    /// Shift 的按下 / 松开。这一下切了模式时返回 true。right 是右 Shift。nowMs 是单调时钟（和 clock 同一个）。
    /// 单按先不切（双击 Shift 不切换，#253）：会话叫 onTranslatePoll 排定时器，到时间没有第二下在
    /// pollTranslation 里切；之前按了别的键时在那个键里先切（mode() 变了，外壳照常更新提示）。
    bool shiftChanged(bool down, bool otherModifiers, uint64_t nowMs, bool right);
    /// 别的修饰键按下了（Ctrl、Alt、Win）：这次 Shift 不算单按（等双击的那一下单按先切）。
    void otherModifierChanged();
    /// 切模式（菜单、外部命令）。
    void switchMode(Mode mode);
    /// 外部命令切模式：zh、en、translate、toggle。认不出、切不到返回 false。
    bool setModeNamed(const std::string &name);
    /// 切到 WowType 时按设置里的 InitialMode 定中 / 英（换窗口不调）。
    void applyInitialMode();
    /// 换到别的窗口、别的应用时按设置里的 WindowMode 定中 / 英（#254）：Same 不动；切不回中文时不进英文。
    /// 外壳只在窗口、应用变了时调；切到 WowType 的那一下按 InitialMode，不调这个。
    void applyWindowMode();
    /// 系统要结束组字（换输入框、点了别处、切走输入法）：已选的词 + 打的字母原样上屏。
    void commitComposition();
    /// 放弃正在打的。
    void cancel();
    /// 点候选框里显示的第 index 个（和按数字键一样）。
    void select(int index);
    /// 候选框上点了翻页箭头、滚了滚轮。
    void turnPage(bool forward);
    /// 外壳要上屏一段与拼音无关的字：补空格、记上文，互译时进原文。
    void insert(const std::string &text);
    /// 外壳排的定时器到了（onTranslatePoll）：返回还要不要再调（>0 是过多少毫秒）。
    uint32_t pollTranslation();
    /// 表情面板快捷键。
    void toggleEmojiPanel();
    void openTool(Panel panel);
    void closeTool();
    /// 重画编辑区和候选框（换了输入框以后）。
    void refresh();

private:
    void configure();
    bool handleIdle(const KeyInput &key);
    bool handleComposing(const KeyInput &key);
    bool handleToolKey(const KeyInput &key);
    std::optional<uint32_t> modeKeyAction(const KeyInput &key) const;
    void observe(const KeyInput &key);
    /// OBSERVE 的 frame 里切了模式（等双击的单按 Shift 被打断）：上屏、重画。
    void followObserved(const WowtypeFrame *frame);
    bool sendToSession(const KeyInput &key, uint32_t action = WOWTYPE_KEY_ACTION_NONE);
    void applyFrame(const WowtypeFrame *frame);
    void drawTool();
    void refreshTranslate(const WowtypeFrame *frame);
    std::optional<CandidatePage> candidatePage(const WowtypeFrame *frame);
    std::string translateSignature(const WowtypeFrame *frame) const;
    std::string statsSource(Mode mode) const;
    std::string statsScheme(Mode mode) const;
    uint32_t previousCharacter();
    uint32_t reliablePreviousCharacter();
    uint64_t now() const;

    WowtypeSession *session_ = nullptr;
    WowtypeEngineHandle *engine_ = nullptr;
    TextClient *client_ = nullptr;
    WowtypeTranslator *translator_ = nullptr;
    Config config_;
    std::string translateDrawn_;
    /// 上一次 applyFrame 以后的模式：离开「译」的 frame 里上屏的照「译」记统计
    Mode appliedMode_ = Mode::Chinese;
    bool associationShown_ = false;
    bool pairing_ = false;
};

/// 单调时钟（毫秒）。
uint64_t monotonicMs();

} // namespace wowtype
