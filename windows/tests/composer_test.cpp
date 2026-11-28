// Windows 外壳的按键测试：用假的输入框把按键喂给 Composer，看上屏、编辑区、候选框。
// 不依赖 windows.h，Linux 和 Windows 都跑（windows/test.sh、CI 的 Windows 任务）。
//
//   wowtype-windows-harness [lexicon.tsv]
//
// 用例照 macos/Tests/main.swift、fcitx5-addon/test/key_harness.cpp 的同名用例抄：三端同一个会话，结果要一样。
// 没给词库时自己写一份小词库（shi 有 3 页候选，测翻页）。

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <map>
#include <functional>
#include <iterator>
#include <memory>
#include <string>
#include <vector>

#include "composer.h"
#include "config.h"
#include "app_update.h"
#include "custom_words.h"
#include "stats_view.h"
#include "keys.h"
#include "look.h"
#include "translate_engine.h"
#include "utf.h"
#include "voice.h"

using namespace wowtype;

namespace {

int failures = 0;

void check(bool ok, const std::string &name, const std::string &detail = "") {
    if (ok) {
        std::printf("ok   %s\n", name.c_str());
    } else {
        ++failures;
        std::printf("FAIL %s %s\n", name.c_str(), detail.c_str());
    }
}

std::string join(const std::vector<std::string> &v) {
    std::string out;
    for (const auto &s : v) {
        out += (out.empty() ? "" : " ") + s;
    }
    return out;
}

/// 假的输入框：上屏的字攒在 committed 里。
class FakeClient : public TextClient {
public:
    std::string committed;
    std::string marked;
    int markedCursor = 0;
    std::optional<CandidatePage> page;
    bool translationAllowed = true;

    void insertText(const std::string &text) override {
        committed += text;
        marked.clear();
    }
    void setMarkedText(const std::string &text, int cursorBytes) override {
        marked = text;
        markedCursor = cursorBytes;
    }
    void showCandidates(const CandidatePage *p) override {
        if (p) {
            page = *p;
        } else {
            page.reset();
        }
    }
    uint32_t previousCharacter() override { return lastCodepoint(committed); }
    bool allowsTranslation() override { return translationAllowed; }

    std::vector<std::string> texts() const { return page ? page->texts : std::vector<std::string>{}; }
};

/// 有光标的假输入框（自动配对）：text 是应用里的字（UTF-16），caret 是光标。
class CaretClient : public TextClient {
public:
    std::u16string text;
    std::size_t caret = 0;
    std::string marked;
    bool editable = true;

    std::string shown() const {
        return utf16To8(text.substr(0, caret)) + "|" + utf16To8(text.substr(caret));
    }
    void set(const std::string &s, std::size_t at) {
        text = utf8To16(s);
        caret = at;
    }
    void insertText(const std::string &s) override {
        const auto u = utf8To16(s);
        text.insert(caret, u);
        caret += u.size();
        marked.clear();
    }
    void setMarkedText(const std::string &s, int) override { marked = s; }
    void showCandidates(const CandidatePage *) override {}
    uint32_t previousCharacter() override { return caret > 0 ? text[caret - 1] : 0; }
    bool previousCharacterIsReliable() override { return editable; }
    bool canEditAroundCaret() override { return editable; }
    std::optional<uint32_t> nextCharacter() override {
        if (editable && caret < text.size()) {
            return text[caret];
        }
        return std::nullopt;
    }
    bool moveCaret(int delta) override {
        const long target = static_cast<long>(caret) + delta;
        if (!editable || target < 0 || target > static_cast<long>(text.size())) {
            return false;
        }
        caret = static_cast<std::size_t>(target);
        return true;
    }
    bool deletePair() override {
        if (!editable || caret == 0 || caret >= text.size()) {
            return false;
        }
        text.erase(caret - 1, 2);
        caret -= 1;
        return true;
    }
    /// 输入法交给应用的键：字插在光标处，退格删光标前一个，左右键挪光标
    void appKey(const KeyInput &key) {
        switch (key.keysym) {
        case keysym::backspace:
            if (caret > 0) {
                text.erase(caret - 1, 1);
                --caret;
            }
            break;
        case keysym::left:
            caret = caret > 0 ? caret - 1 : 0;
            break;
        case keysym::right:
            caret = std::min(caret + 1, text.size());
            break;
        default:
            if (const auto a = key.ascii()) {
                insertText(std::string(1, static_cast<char>(*a)));
            }
        }
    }
};

void type(Composer &c, const std::string &keys) {
    for (const char ch : keys) {
        c.handle(KeyInput::character(static_cast<unsigned char>(ch)));
    }
}

/// 打一串键（< 退格、{ 左键），输入法不要的交给假应用。
void pairType(Composer &c, CaretClient &client, const std::string &keys) {
    for (const char ch : keys) {
        KeyInput key = ch == '<'   ? KeyInput::key(keysym::backspace)
                       : ch == '{' ? KeyInput::key(keysym::left)
                                   : KeyInput::character(static_cast<unsigned char>(ch));
        if (!c.handle(key)) {
            client.appKey(key);
        }
    }
}

/// 外壳的定时器在 at 毫秒时到了（单按 Shift 等双击，#253）：返回这一下切没切模式。
bool settleShift(Composer &c, uint64_t at) {
    const auto mode = c.mode();
    const auto clock = c.clock;
    c.clock = [at] { return at; };
    c.pollTranslation();
    c.clock = clock;
    return c.mode() != mode;
}

/// 单按一下 Shift，等过双击间隔（定时器到了）。每次往后挪一秒，不会被当成双击或按住太久。
uint64_t shiftClock = 100000;
void tapShift(Composer &c) {
    shiftClock += 1000;
    c.shiftChanged(true, false, shiftClock, false);
    c.shiftChanged(false, false, shiftClock + 50, false);
    settleShift(c, shiftClock + 500);
}

std::string writeTestLexicon(const std::filesystem::path &dir) {
    std::vector<std::string> lines = {"nihao\t你好\t50000", "ni\t你\t40000",    "ni\t尼\t3000",
                                      "hao\t好\t40000",     "hao\t号\t5000",    "shishi\t事实\t8000",
                                      "lve\t略\t30000",      "kai xin\t开心\t30000"};
    const std::string shi = "是十时事市使实式试世师史石示视适识施室势诗释湿";
    std::size_t i = 0;
    int n = 0;
    while (i < shi.size()) {
        const std::size_t start = i;
        nextCodepoint(shi, i);
        lines.push_back("shi\t" + shi.substr(start, i - start) + "\t" + std::to_string(60000 - n * 1000));
        ++n;
    }
    const auto path = dir / "lexicon.tsv";
    std::ofstream out(path, std::ios::binary);
    for (const auto &line : lines) {
        out << line << "\n";
    }
    return path.string();
}

} // namespace

int main(int argc, char **argv) {
    const auto dir = std::filesystem::temp_directory_path() / ("wowtype-windows-harness-" + std::to_string(std::rand()));
    std::filesystem::create_directories(dir);
    const bool ownLexicon = argc <= 1;
    const std::string lexicon = ownLexicon ? writeTestLexicon(dir) : argv[1];
    WowtypeEngineHandle *engine = wowtype_engine_new(lexicon.c_str(), nullptr);
    if (!engine) {
        std::printf("FAIL 载入词库 %s\n", lexicon.c_str());
        return 1;
    }
    wowtype_engine_set_max_candidates(engine, 1000);
    {
        const auto english = dir / "english.txt";
        std::ofstream(english, std::ios::binary) << "hello\niPhone\n";
        wowtype_engine_load_english(engine, english.string().c_str());
    }
    // 最近用过的 emoji 只记在内存里
    wowtype_recent_emoji_path("");
    check(wowtype_abi_version() / 1000 == WOWTYPE_ABI_VERSION_MAJOR, "ABI 主版本对得上");

    // ---------------------------------------------------------------- 按键翻译（VK → keysym）
    {
        check(translateVirtualKey('A', U'a', 0, false)->keysym == 'a', "A 键打出 a");
        const auto bang = translateVirtualKey('1', U'!', mod::shift, false);
        check(bang && bang->keysym == '!' && bang->modifiers == mod::shift, "Shift+1 是 !");
        check(translateVirtualKey(vk::returnKey, 0, 0, false)->keysym == keysym::returnKey, "回车");
        check(translateVirtualKey(vk::returnKey, 0, 0, true)->keysym == keysym::keypadEnter, "小键盘回车");
        check(translateVirtualKey(vk::back, 8, 0, false)->keysym == keysym::backspace, "退格");
        check(translateVirtualKey(vk::numpad0 + 3, U'3', mod::numlock, false)->keysym == '3', "小键盘 3");
        check(translateVirtualKey(vk::next, 0, 0, true)->keysym == keysym::pageDown, "Page Down");
        check(!translateVirtualKey(0x70 /* F1 */, 0, 0, false), "F1 翻不出来");
        check(!translateVirtualKey('E', U'é', 0, false), "非 ASCII 的字符翻不出来");
        check(isModifierKey(vk::shift) && isModifierKey(vk::lwin) && !isModifierKey('A'), "修饰键");
        check(utf16Offset("你好a", 6) == 2 && utf16Offset("😀a", 4) == 2, "UTF-8 偏移转 UTF-16");
        check(utf16To8(utf8To16("你好😀")) == "你好😀", "UTF-8 ⇄ UTF-16");
    }

    // ---------------------------------------------------------------- 语音键（和 macOS 的 VoiceKey、Linux 的键名一样）
    {
        const auto altR = VoiceKey::parse("Alt_R");
        check(altR && altR->modifier && altR->matches(vk::menu, true) && !altR->matches(vk::menu, false) &&
                  altR->matches(vk::rmenu, false),
              "Alt_R 是右 Alt（扩展键位或 VK_RMENU）");
        const auto f8 = VoiceKey::parse("F8");
        check(f8 && !f8->modifier && f8->matches(0x77, false), "F8");
        check(VoiceKey::parse("Super_L")->matches(0x5B, false), "Super_L 是左 Win");
        check(!VoiceKey::parse("") && !VoiceKey::parse("Menu"), "留空、认不出的不用热键");
        check(voiceWave({}) == "▁▁▁▁▁▁" && voiceWave({100, 0, 50}) == "▁▁▁█▁▄", "音量波形", voiceWave({100, 0, 50}));
        VoiceInput voice;
        voice.configure(false, "Alt_R", false, "");
        check(!voice.key() && !voice.press(true, false, false, nullptr), "关掉语音时语音键交给应用");
    }

    // ---------------------------------------------------------------- 快捷键、设置
    {
        const Config d;
        check(d.emojiKey() && d.emojiKey()->name() == "Control+period", "表情面板默认 Control+period",
              d.value("EmojiKey"));
        check(Shortcut::parse("Super+period")->name() == "Control+period", "Super 当 Control");
        check(Shortcut::parse("Control+Shift+E")->name() == "Control+Shift+E", "Control+Shift+E");
        check(Shortcut::parse("Control+Shift+e")->matches(KeyInput::character('E', mod::shift | mod::control)),
              "字母不分大小写");
        check(!Shortcut::parse("Hyper+x"), "不认识的修饰键");
        const Config c = Config::parse("PageSize = 5\nTraditional=true\r\nFuzzy=True\n"
                                       "EmojiKey=\nTranslateBaseUrl=\"a b\"\nShuangpin=True\n[Hotkey]\nPageSize=7\n");
        check(c.pageSize() == 5, "PageSize 两边空格、[分组] 下的不认", c.value("PageSize"));
        check(!c.flag("Traditional") && c.flag("Fuzzy"), "开关只认 True / False");
        check(!c.emojiKey(), "EmojiKey 留空是不用");
        check(c.value("TranslateBaseUrl") == "a b" && !c.flag("TranslateLocal"), "引号、TranslateLocal 跟着接口");
        check(c.shuangpin(), "旧的 Shuangpin=True 是双拼");
        // #268：双拼的简拼默认开，文件里写 False 才关
        check(d.flag("ShuangpinAbbrev") && c.flag("ShuangpinAbbrev"), "双拼简拼默认开");
        check(!Config::parse("ShuangpinAbbrev=False\n").flag("ShuangpinAbbrev"), "ShuangpinAbbrev=False 关掉双拼简拼");
    }

    // ---------------------------------------------------------------- 设置窗口的主题和强调色（和 Linux、macOS 一样）
    {
        const Config d;
        check(d.value("SettingsTheme") == "System" && d.value("SettingsAccent") == "Green", "设置窗口默认跟随系统、绿色");
        const Config c = Config::parse("SettingsTheme=Dark\nSettingsAccent=Blue\n");
        check(c.value("SettingsTheme") == "Dark" && look::accent(c.value("SettingsAccent")).color == 0x3584E4,
              "SettingsTheme、SettingsAccent 读得出来");
        const Config wrong = Config::parse("SettingsTheme=dark\nSettingsAccent=Red\n");
        check(wrong.value("SettingsTheme") == "System" && wrong.value("SettingsAccent") == "Green", "认不出的用默认");
        check(std::string(look::accent("Red").value) == "Green", "认不出的强调色用绿色");
        check(look::dark("System", true) && !look::dark("System", false) && look::dark("Dark", false) &&
                  !look::dark("Light", true) && !look::dark("乱写", false),
              "主题：固定的不看系统，跟随系统看系统");
        check(look::blend(0xFFFFFF, 0x000000, 0.5) == 0x808080 && look::blend(0x0EAF76, 0xFFFFFF, 0) == 0xFFFFFF &&
                  look::blend(0x0EAF76, 0xFFFFFF, 1) == 0x0EAF76,
              "叠色");
        check(look::hex(0x0A8358) == "#0A8358", "颜色写成 #RRGGBB", look::hex(0x0A8358));
        check(look::textColor(look::accent("Green"), true) == 0x1AB37D &&
                  look::textColor(look::accent("Green"), false) == 0x0A8358,
              "强调色当字用：深色用 light，浅色用 strong");
    }

    // ---------------------------------------------------------------- 「翻译引擎」（和 Linux 的 translate_engine、
    // on_translate_engine_changed，macOS 的 setTranslateEngine 一样）
    {
        using translate::Engine;
        using translate::EngineChoice;
        const std::string bili = translate::kBilibiliUrl;
        const auto engine = [](const std::string &file) { return translate::engineOf(Config::parse(file)); };
        check(engine("") == Engine::Local, "默认是本地翻译");
        check(engine("TranslateLocal=True\nTranslateBaseUrl=" + bili + "\n") == Engine::Local, "TranslateLocal 优先");
        check(engine("TranslateLocal=False\nTranslateBaseUrl=" + bili + "\n") == Engine::Bilibili, "哔哩哔哩的地址");
        check(engine("TranslateLocal=False\nTranslateBaseUrl=HTTPS://Index-Translate.Bilibili.com/v1/chat/completions\n") ==
                  Engine::Bilibili,
              "哔哩哔哩：不分大小写、带不带 /chat/completions");
        check(engine("TranslateBaseUrl=" + bili + "\n") == Engine::Bilibili, "没写 TranslateLocal、填了哔哩哔哩");
        check(engine("TranslateLocal=False\nTranslateBaseUrl=https://api.deepseek.com/v1\n") == Engine::Custom, "别的地址是自定义");
        check(engine("TranslateLocal=False\n") == Engine::Custom, "地址空着也是自定义");
        check(!translate::isBilibili("https://index-translate.bilibili.com.example.org/v1") &&
                  translate::isBilibili("index-translate.bilibili.com/v1") &&
                  translate::isBilibili("https://user@index-translate.bilibili.com:443/v1"),
              "只认主机正好是哔哩哔哩的");
        check(translate::urlHost("http://[::1]:11434/v1") == "::1" && translate::urlHost(" HTTP://Example.COM/x") == "example.com",
              "主机名", translate::urlHost("http://[::1]:11434/v1"));

        const auto applied = [](const EngineChoice &choice, const Config &base) {
            Config c = base;
            choice.apply(c);
            return c;
        };
        const auto describe = [](const Config &c) {
            return c.value("TranslateLocal") + " " + c.value("TranslateBaseUrl") + " " + c.value("TranslateModel");
        };

        // 自定义 → 哔哩哔哩 → 自定义：自己填的地址、模型照原样写回
        const Config custom = Config::parse("TranslateLocal=False\nTranslateBaseUrl=https://api.deepseek.com/v1\n"
                                            "TranslateModel=deepseek-chat\n");
        EngineChoice choice;
        choice.load(custom);
        check(choice.engine() == Engine::Custom && applied(choice, custom) == custom, "没动过：写出来和读进来一样",
              describe(applied(choice, custom)));
        check(choice.customUrl() == "https://api.deepseek.com/v1" && choice.customModel() == "deepseek-chat",
              "自定义的框照配置填");
        choice.select(Engine::Bilibili);
        Config now = applied(choice, custom);
        check(now.value("TranslateLocal") == "False" && now.value("TranslateBaseUrl") == bili &&
                  now.value("TranslateModel") == "Index-Translate-2B",
              "换到哔哩哔哩：写上它的地址和默认模型（2B）", describe(now));
        check(choice.customUrl() == "https://api.deepseek.com/v1", "换到哔哩哔哩时自定义的地址留着");
        choice.pickBilibili(1);
        check(applied(choice, custom).value("TranslateModel") == "Index-Translate-9B", "哔哩哔哩选 9B");
        choice.select(Engine::Custom);
        check(applied(choice, custom) == custom, "换回自定义：地址、模型照原样写回", describe(applied(choice, custom)));
        choice.select(Engine::Bilibili);
        check(applied(choice, custom).value("TranslateModel") == "Index-Translate-9B", "再换到哔哩哔哩还是上次选的 9B");

        // 换到本地只改 TranslateLocal：地址和模型是上一个联网引擎的
        choice.select(Engine::Local);
        now = applied(choice, custom);
        check(now.value("TranslateLocal") == "True" && now.value("TranslateBaseUrl") == bili &&
                  now.value("TranslateModel") == "Index-Translate-9B",
              "哔哩哔哩 → 本地：地址、模型不动", describe(now));
        choice.select(Engine::Custom);
        check(applied(choice, custom) == custom, "本地 → 自定义：写回自定义的", describe(applied(choice, custom)));
        choice.setCustomUrl(" http://127.0.0.1:11434/v1 ");
        choice.setCustomModel("qwen3:4b");
        now = applied(choice, custom);
        check(now.value("TranslateBaseUrl") == "http://127.0.0.1:11434/v1" && now.value("TranslateModel") == "qwen3:4b",
              "自定义的框改了：去掉两边空白写进去", describe(now));
        choice.select(Engine::Local);
        check(applied(choice, custom).value("TranslateBaseUrl") == "http://127.0.0.1:11434/v1", "自定义 → 本地：地址不动");

        // 打开时是哔哩哔哩：自定义的框空着（那不是自己填的）；模型空着就不写成 2B
        const Config bilibili = Config::parse("TranslateLocal=False\nTranslateBaseUrl=" + bili + "/chat/completions\n");
        EngineChoice b;
        b.load(bilibili);
        check(b.engine() == Engine::Bilibili && b.customUrl().empty() && b.customModel().empty(), "哔哩哔哩：自定义的框空着");
        check(applied(b, bilibili) == bilibili && b.bilibiliIndex() == 0 && b.bilibiliSelected() == "Index-Translate-2B",
              "哔哩哔哩没动过：地址原样、模型空着（下拉框显示 2B）", describe(applied(b, bilibili)));
        b.select(Engine::Custom);
        now = applied(b, bilibili);
        check(now.value("TranslateLocal") == "False" && now.value("TranslateBaseUrl").empty() &&
                  now.value("TranslateModel").empty() && translate::engineOf(now) == Engine::Custom,
              "哔哩哔哩 → 自定义：地址、模型是空的框", describe(now));
        b.setCustomUrl("https://api.openai.com/v1");
        b.setCustomModel("gpt-4o-mini");
        b.select(Engine::Bilibili);
        now = applied(b, bilibili);
        check(now.value("TranslateBaseUrl") == bili && now.value("TranslateModel") == "Index-Translate-2B",
              "再换到哔哩哔哩：写上它的地址（不是读进来的那种写法）", describe(now));
        // 保存后读回来（还是哔哩哔哩）：这次填过的自定义地址还在
        b.load(now);
        check(b.customUrl() == "https://api.openai.com/v1" && b.customModel() == "gpt-4o-mini",
              "保存后读回来，这次填过的自定义地址、模型还在");
        b.select(Engine::Custom);
        check(applied(b, now).value("TranslateBaseUrl") == "https://api.openai.com/v1", "换回自定义写回这次填的");

        // 手写进配置文件的别的哔哩哔哩模型：列出来，不悄悄换掉
        const Config other = Config::parse("TranslateLocal=False\nTranslateBaseUrl=" + bili + "\nTranslateModel=Index-Translate-Next\n");
        EngineChoice o;
        o.load(other);
        const auto options = o.bilibiliOptions();
        check(options.size() == translate::bilibiliModels().size() + 1 && options.back().first == "Index-Translate-Next" &&
                  o.bilibiliIndex() == static_cast<int>(options.size()) - 1 && applied(o, other) == other,
              "配置里别的哔哩哔哩模型列在最后、选中它");

        // 本地（用着时切去了本地的哔哩哔哩）：换到哔哩哔哩用上次给它选的模型；换到自定义框是空的
        const Config localBili = Config::parse("TranslateLocal=True\nTranslateBaseUrl=" + bili + "\nTranslateModel=Index-Translate-9B\n");
        EngineChoice l;
        l.load(localBili);
        check(l.engine() == Engine::Local && applied(l, localBili) == localBili && l.customUrl().empty(),
              "本地（地址是哔哩哔哩的）：没动过写出来一样，自定义的框空着");
        l.select(Engine::Bilibili);
        check(applied(l, localBili).value("TranslateModel") == "Index-Translate-9B" &&
                  applied(l, localBili).value("TranslateLocal") == "False",
              "本地 → 哔哩哔哩：用上次给它选的 9B");
        const Config localCustom = Config::parse("TranslateLocal=True\nTranslateBaseUrl=https://api.deepseek.com/v1\n");
        l.load(localCustom);
        check(l.customUrl() == "https://api.deepseek.com/v1" && applied(l, localCustom) == localCustom,
              "本地（地址是自定义的）：自定义的框照配置填");
        l.select(Engine::Custom);
        check(applied(l, localCustom).value("TranslateBaseUrl") == "https://api.deepseek.com/v1" &&
                  !applied(l, localCustom).flag("TranslateLocal"),
              "本地 → 自定义：用配置里的地址");

        // 选项、说明和规格一样（规格对照在 test-config-contract.py --windows）
        check(translate::engines().size() == 3 && translate::engines()[1].engine == Engine::Bilibili &&
                  std::string(translate::engines()[0].name) == "本地翻译（离线）",
              "三个引擎，顺序固定");
        check(translate::testSummary("Hello\n", 0.84) == "✓ 你好 → Hello（0.8 秒）", "测试连接的结果",
              translate::testSummary("Hello\n", 0.84));
        check(translate::testSummary("\nHi\nthere", 3.0) == "✓ 你好 → Hi（3.0 秒），有点慢，可以换个小一点的模型",
              "测试连接：取第一行，慢了提一句", translate::testSummary("\nHi\nthere", 3.0));
    }

    // ---------------------------------------------------------------- 写回设置文件（和 macOS 的 serialized、merged 同名用例）
    {
        const Config d;
        const std::string tmpl = Config::templateText();
        check(d.serialized(nullptr) == tmpl, "没有设置文件：写出来的是模板");
        check(Config::parse(tmpl) == d, "模板读回来是默认值");
        Config one;
        one.setValue("PageSize", "5");
        one.setValue("Traditional", "True");
        const std::string fromTemplate = one.serialized(nullptr);
        check(fromTemplate.find("\nPageSize=5\n") != std::string::npos &&
                  fromTemplate.find("# PageSize=") == std::string::npos &&
                  fromTemplate.find("\n# Fuzzy=False\n") != std::string::npos,
              "从模板写只就地换掉改过的键", fromTemplate);
        check(Config::parse(fromTemplate) == one && one.serialized(&fromTemplate) == fromTemplate,
              "从模板写的读回来一样，再写一次不变");
        const std::string mine = "# 我的设置\n#PageSize=7\n";
        check(one.serialized(&mine) == "# 我的设置\nPageSize=5\nTraditional=True\n", "自己注释掉的设置行也就地换掉",
              one.serialized(&mine));

        const std::string linux = "# 自己写的注释\nCandidateLayout=horizontal\nPageSize=20\n  TypoCorrection = False\n"
                                  "CheckUpdate=False\nVoiceKey=Alt_R\nTranslateBaseUrl=https://api.deepseek.com/v1\n"
                                  "Lexicon=\"~/dicts/my lexicon.tsv\"\nTraditional=maybe\nShuangpinScheme=xiaohe\n"
                                  "EmojiKey=Super+period\n\n[Hotkey]\nPageSize=4\n";
        const Config parsed = Config::parse(linux);
        check(parsed.serialized(&linux) == linux, "设置没改：文件一个字都不动", parsed.serialized(&linux));
        Config changed = parsed;
        changed.setValue("PageSize", "5");
        changed.setValue("TypoCorrection", "True");
        changed.setValue("Fuzzy", "True");
        changed.setValue("Traditional", "True");
        const std::string out = changed.serialized(&linux);
        check(Config::parse(out) == changed, "改过的设置读回来一样", out);
        check(out.find("\nPageSize=5\n") != std::string::npos && out.find("\n  TypoCorrection = True\n") != std::string::npos,
              "改的行只换值，前面的空格留着", out);
        check(out.find("CheckUpdate=False\n") != std::string::npos && out.find("EmojiKey=Super+period\n") != std::string::npos,
              "Windows 还没有的键、读出来一样的写法原样留着", out);
        const std::string tail = "Fuzzy=True\n\n[Hotkey]\nPageSize=4\n";
        check(out.size() > tail.size() && out.compare(out.size() - tail.size(), tail.size(), tail) == 0,
              "新加的键补在 [分组] 前面", out);
        const std::string twice = "PageSize=5\r\nFuzzy=False\r\nPageSize=7\r\n";
        Config three = Config::parse(twice);
        three.setValue("PageSize", "3");
        three.setValue("Traditional", "True");
        check(three.serialized(&twice) == "PageSize=3\r\nFuzzy=False\r\nPageSize=3\r\nTraditional=True\r\n",
              "重复的键都改，\\r\\n 留着", three.serialized(&twice));
        const std::string old = "Shuangpin=True\nPageSize=7\n";
        const Config oldConfig = Config::parse(old);
        check(oldConfig.serialized(&old) == "PageSize=7\nInputScheme=Shuangpin\n", "旧的 Shuangpin 行换成 InputScheme",
              oldConfig.serialized(&old));
        const std::string opened = "PageSize=7\nFuzzy=False\nVoice=True\n";
        const Config base = Config::parse(opened);
        Config window = base;
        window.setValue("PageSize", "4");
        const std::string edited = "PageSize=7\nFuzzy=True\nVoice=True\nTraditional=True\n";
        check(window.merged(base, &edited) == "PageSize=4\nFuzzy=True\nVoice=True\nTraditional=True\n",
              "合并：别处改的留着，窗口改的写上", window.merged(base, &edited));
        Config quoted;
        quoted.setValue("Lexicon", "C:\\词库 \"新\".tsv");
        const std::string q = quoted.serialized(nullptr);
        check(Config::parse(q) == quoted && q.find("Lexicon=\"C:\\\\词库 \\\"新\\\".tsv\"") != std::string::npos,
              "带空格、引号的值加引号转义", q);
    }

    // ---------------------------------------------------------------- custom.tsv（和 macOS 的 CustomWords 同名用例）
    {
        using E = CustomWords::Entry;
        const std::string text = "# 我的常用语\r\nni hao\t你好呀\t100\nmail\thello@example.com\n\n坏行\nzhang san\t \nbjdx\t北京大学\n";
        CustomWords words{std::optional<std::string>(text)};
        check(words.entries() == std::vector<E>{{"ni hao", "你好呀"}, {"mail", "hello@example.com"}, {"bjdx", "北京大学"}},
              "读自定义词");
        check(words.text() == text, "没改：原样写回去（注释、频次、坏行都在）", words.text());
        check(CustomWords(std::optional<std::string>("\xEF\xBB\xBFmail\ta@b.c")).text() == "mail\ta@b.c\n",
              "去掉 BOM，补上末尾换行");
        check(!words.add("gs", "公司名"), "加新词");
        check(words.add("ni hao ya", "你好呀"), "加已有的词：换编码");
        check(words.text() == "# 我的常用语\r\nmail\thello@example.com\n\n坏行\nzhang san\t \nbjdx\t北京大学\ngs\t公司名\nni hao ya\t你好呀\n",
              "换编码的词挪到最后", words.text());
        check(words.remove("北京大学") == std::vector<E>{{"bjdx", "北京大学"}} && words.remove("没有").empty(), "删词");
        const auto incoming = CustomWords::parseImport(
            "# 注释\nNi Hǎo Ya\t你好呀\nzhang'san\t张三\nMAIL\thello@example.com\n123\t数字\nxyz?\t问号\n");
        check(incoming == std::vector<E>{{"ni hao ya", "你好呀"}, {"zhang san", "张三"}, {"mail", "hello@example.com"}},
              "导入时整理编码，不对的不要");
        CustomWords imported{std::optional<std::string>("mail\thello@example.com\nni hao\t你好呀\n")};
        const auto counts = imported.merge(incoming);
        check(counts.first == 1 && counts.second == 1, "导入：新增 1 个，更新 1 个，一样的不算");
        const CustomWords empty{std::nullopt};
        check(empty.entries().empty() && empty.text() == std::string(CustomWords::header()) + "\n", "新文件只有说明");
        CustomWords fresh = empty;
        fresh.add("gs", "公司");
        check(CustomWords(std::optional<std::string>(fresh.text())).entries() == std::vector<E>{{"gs", "公司"}},
              "新文件加词读回来");
        check(CustomWords::isValidWord("四川省\\n宜宾市") && !CustomWords::isValidWord("a\tb") &&
                  !CustomWords::isValidWord(""),
              "词里不能有 TAB、换行");
        check(CustomWords::shown("四川省\\n宜宾市") == "四川省⏎宜宾市", "界面上 \\n 画成 ⏎");
        check(CustomWords::guessPinyin("你好", "ni hao\t你好\t100\n") == std::optional<std::string>("ni hao"),
              "从词库猜拼音");
    }

    // ---------------------------------------------------------------- 统计页、诊断信息（和 macOS 的 StatsStore、DiagnosticsText 一样）
    {
        const std::string conf = "# 注释 TranslateBaseUrl=https://a@b/c\nPageSize=5\n"
                                 "TranslateBaseUrl=https://user:sk-123@api.example.com:8443/v1/sk-456\nTranslateKey=sk-789\n"
                                 "ApiToken = \"abc\"\nEmojiKey=Control+period\nTranslateModel=\nMyKey=\n[Hotkey]\nX=1";
        const std::string masked = diagnostics::maskConfig(conf);
        check(masked == "# 注释 TranslateBaseUrl=https://a@b/c\nPageSize=5\n"
                        "TranslateBaseUrl=https://api.example.com:8443/…\nTranslateKey=（已打码）\n"
                        "ApiToken=（已打码）\nEmojiKey=Control+period\nTranslateModel=\nMyKey=\n[Hotkey]\nX=1",
              "诊断信息里的设置：接口地址只留主机，像密钥的键打码，别的原样", masked);
        check(diagnostics::maskUrl("").empty() && diagnostics::maskUrl("http://127.0.0.1:11434/v1") == "http://127.0.0.1:11434/…" &&
                  diagnostics::maskUrl("\"https://k@x.org\"") == "https://x.org/…" && diagnostics::maskUrl("sk-abc") == "（已打码）",
              "网址只留协议和主机");

        const auto doc = StatsDocument::parse(R"({"version":1,"cleared":0,"days":{
            "2026-11-17":{"chars":100,"kinds":{"han":80,"latin":10},"activeMs":120000,"keys":{"KeyA":5,"Space":9}},
            "2026-11-18":{"chars":300,"kinds":{"han":200,"latin":40},"activeMs":30000,"keys":{"KeyA":7}},
            "2026-11-19":{"chars":50,"kinds":{"han":50},"activeMs":60000,"keys":{"Space":1},"selections":[3,1]}}})");
        check(doc.days.size() == 3 && doc.days.at("2026-11-19").selections[0] == 3, "读 stats.json");
        const auto m = stats::metrics(doc, "2026-11-19");
        check(m.todayChars == 50 && m.totalChars == 450 && m.recordedDays == 3, "今天、一共");
        check(m.bestDay == std::optional<std::string>("2026-11-18") && m.bestChars == 300, "打得最多的一天");
        check(m.fastestDay == std::optional<std::string>("2026-11-19") && static_cast<int>(m.fastestSpeed) == 50,
              "最快的一天至少 1 分钟活跃（11-18 只有 30 秒不算）");
        check(m.streak == 3 && m.longestStreak == 3 && stats::metrics(doc, "2026-11-21").streak == 0, "连续天数");
        check(stats::shift("2026-03-01", -1) == "2026-02-28" && stats::shift("2024-12-31", 1) == "2025-01-01",
              "日期加减");
        check(stats::formatActive(0) == "0分" && stats::formatActive(30000) == "30秒" &&
                  stats::formatActive(3720000) == "1小时2分",
              "活跃时间的写法");
        const auto keys = stats::topKeys(doc, 1);
        check(keys.size() == 1 && keys[0].first == "KeyA" && keys[0].second == 12, "按得最多的键");
        const auto days = stats::recentDays(doc, 30, "2026-11-19");
        check(days.size() == 30 && days.back().first == "2026-11-19" && days.back().second == 50 &&
                  days.front().first == "2026-10-21" && days[28].second == 300,
              "最近 30 天的柱子");
        check(stats::level(0, 10) == 0 && stats::level(1, 100) == 1 && stats::level(100, 100) == 4 &&
                  stats::level(50, 100) == 2,
              "热力图的深浅（和 macOS 一样）");
        std::size_t keyCount = 0;
        for (const auto &row : stats::keyboardRows()) {
            for (const auto &cap : row) {
                keyCount += cap.code.empty() ? 0 : 1;
            }
        }
        check(stats::keyboardRows().size() == 6 && keyCount == 74 && stats::keyTotals(doc).at("KeyA") == 12,
              "热力图的键盘", std::to_string(keyCount));
        check(StatsDocument::parse("不是 JSON").days.empty() && !stats::summary(StatsDocument{}, "2026-11-19").empty(),
              "读不出来是空的，空的也有一段说明");
    }

    // ---------------------------------------------------------------- 检查更新（和 macOS 的 AppUpdate 同名用例）
    {
        using namespace wowtype::update;
        check(version("v0.4.1") == std::optional<std::string>("0.4.1") && version("0.4.1") == std::optional<std::string>("0.4.1"),
              "tag 去掉 v");
        check(!version("") && !version("v") && !version("v1/../x") && !version("v1 2") && !version("-1"), "不像版本号的 tag 不认");
        check(packageName("0.4.1", "x64") == "WowType-0.4.1-windows-x64-setup.exe", "Windows 安装程序的名字");
        const std::string notes = "# WowType 0.5.2\n\n## 这一版\n\n### 新功能\n- 自动配对\n  - 套着打\n```\nbrew x\n```\n## 安装\n下载 pkg\n";
        check(highlights(notes) == "### 新功能\n- 自动配对\n  - 套着打\n```\nbrew x\n```", "更新内容只留「这一版」",
              highlights(notes));
        check(highlights("修了一个问题\n") == "修了一个问题", "没有「这一版」时原样");
        const auto r = [](const char *tag, bool pre = false, bool draft = false) {
            Release x;
            x.tag = tag;
            x.prerelease = pre;
            x.draft = draft;
            return x;
        };
        check(pickNewest({r("v0.4.0"), r("v0.5.0", true), r("v0.4.1")}) == std::optional<std::size_t>(1), "Beta：预发布也算");
        check(pickNewest({r("v0.5.0", true), r("v0.5.0")}) == std::optional<std::size_t>(1), "Beta：一样大要正式版");
        check(pickNewest({r("v0.4.0"), r("v0.6.0", false, true), r("lm-2026.11.09", true)}) == std::optional<std::size_t>(0),
              "Beta：草稿、数据的发布不算");
        check(pickNewest({r("v0.9.9", true), r("v0.10.0")}) == std::optional<std::size_t>(1), "Beta：按数字段比");
        check(!pickNewest({r("nnlm-2026.11.17", true)}) && !pickNewest({}), "Beta：没有合适的");
        check(isNewer("0.4.1", "0.4.0") && isNewer("0.10.0", "0.9.9") && isNewer("0.4.0.1", "0.4.0"), "新版本");
        check(!isNewer("0.4.0", "0.4.0") && !isNewer("0.3.12", "0.4.0"), "一样的、旧的不算新版本");
        check(!isNewer("0.4.1", "dev") && !isRelease("dev") && isRelease("0.4.0"), "开发版不提示更新");
        const State state = State::parse("checked=1700000000\nlatest=v0.4.1\n");
        check(state == State{1700000000, "v0.4.1"} && State::parse(state.text()) == state, "检查状态读写");
        check(State::parse("乱写\nchecked=abc\nlatest=../x\n") == State{}, "写坏的检查状态当没查过");
        check(!due(state, 1700000000 + 3600) && due(state, 1700000000 + 86400) && due(state, 1600000000) &&
                  due(State{}, 1700000000),
              "一天查一次，时钟往回拨了也查");
        {
            State tried = state;
            tried.tried = 1700000000 + 86400;
            check(State::parse(tried.text()) == tried, "检查状态记上次试的时间");
            check(!due(tried, 1700000000 + 86400 + 600) && due(tried, 1700000000 + 86400 + 3600),
                  "查不成以后所有应用合起来一小时最多试一次");
        }
        // 接口限流时改走网页（和 Linux 的 fetch_latest_web、macOS 的 AppUpdate.webCandidates 一样）
        check(tagFromLatestUrl("https://github.com/Gloridust/WowType/releases/tag/v0.6.0") == std::optional<std::string>("v0.6.0") &&
                  !tagFromLatestUrl("https://github.com/Gloridust/WowType/releases"),
              "releases/latest 跳到的地址里取 tag");
        std::string feed;
        for (const char *t : {"v0.8.0", "v0.7.0", "lm-2026.11.09", "v0.6.0", "v0.7.0"}) {
            feed += std::string("<link href=\"https://github.com/Gloridust/WowType/releases/tag/") + t + "\"/>";
        }
        check(webCandidates(std::string("v0.6.0"), std::nullopt) == std::vector<std::string>{"v0.6.0"},
              "网页：不开 Beta 只看最新正式版");
        check(webCandidates(std::string("v0.6.0"), feed) == std::vector<std::string>{"v0.8.0", "v0.7.0", "v0.6.0"},
              "网页：Beta 按版本号从大到小试，数据的发布不算、重复的去掉");
        const std::string sha(64, 'a');
        check(assetNames(sha + "  WowType-0.6.0-macos.pkg\n" + sha + " *wowtype_0.6.0_debian13_amd64.deb\nbad  x\n" + sha +
                         "  ../evil\n") == std::vector<std::string>{"WowType-0.6.0-macos.pkg", "wowtype_0.6.0_debian13_amd64.deb"},
              "SHA256SUMS 里的文件名");
        {
            // 检查更新走网页（和 Linux 的 test_update_check_uses_web_not_api 一样）：releases/latest 的跳转、releases.atom、
            // SHA256SUMS；更新说明下发布页上的 RELEASE-NOTES.md，更早的版本没有这个文件才问一次接口
            const std::string home = kRepoPage;
            std::map<std::string, std::string> sums = {
                {"v0.6.0", sha + "  WowType-0.6.0-windows-x64-setup.exe\n" + sha + " *WowType-0.6.0-macos.pkg\n"},
                {"v0.7.0", sha + "  WowType-0.7.0-windows-x64-setup.exe\n"},
                {"v0.7.1", sha + "  WowType-0.7.1-windows-x64-setup.exe\n"},
            };
            std::map<std::string, std::string> notesFiles = {{"v0.7.1", "## 这一版要注意\n\n- 网页取说明\n\n"}};
            // v0.8.0 只推了 tag、还没发出来：atom 里有，SHA256SUMS 是 404
            std::string atom;
            for (const char *t : {"v0.8.0", "v0.7.1", "v0.7.0", "lm-2026.11.09", "v0.6.0"}) {
                atom += "<link href=\"" + home + "/releases/tag/" + t + "\"/>";
            }
            std::vector<std::string> asked;
            std::function<HttpResult(const std::string &)> api;
            bool webBroken = false;
            const Fetch site = [&](const std::string &url) {
                asked.push_back(url);
                HttpResult r;
                if (url.find("api.github.com") != std::string::npos) {
                    return api(url);
                }
                r.status = 404;
                if (webBroken) {
                    r.status = 500;
                } else if (url == kLatestPage) {
                    r.status = 200;
                    r.finalUrl = home + "/releases/tag/v0.6.0";
                } else if (url == kAtomFeed) {
                    r.status = 200;
                    r.body = atom;
                } else {
                    for (const auto &[tag, body] : sums) {
                        if (url == home + "/releases/download/" + tag + "/SHA256SUMS") {
                            r.status = 200;
                            r.body = body;
                        } else if (url == home + "/releases/download/" + tag + "/RELEASE-NOTES.md" && notesFiles.count(tag)) {
                            r.status = 200;
                            r.body = notesFiles[tag];
                        }
                    }
                }
                return r;
            };
            const auto apiCalls = [&] {
                return std::count_if(asked.begin(), asked.end(),
                                     [](const std::string &u) { return u.find("api.github.com") != std::string::npos; });
            };
            const auto limited = [](const std::string &) {
                HttpResult r;
                r.status = 403;
                return r;
            };
            std::string error;
            // 现在装的是 0.6.0：正式版没有更新，不取说明，一次接口都不问
            api = limited;
            const auto stable = fetchLatest(site, false, "0.6.0", &error);
            check(stable && stable->tag == "v0.6.0" && !stable->prerelease && stable->notes.empty() &&
                      stable->assets.at("WowType-0.6.0-windows-x64-setup.exe") ==
                          home + "/releases/download/v0.6.0/WowType-0.6.0-windows-x64-setup.exe" &&
                      stable->assets.count("SHA256SUMS") && apiCalls() == 0,
                  "检查更新走网页：正式版从 releases/latest 的跳转和 SHA256SUMS 拼出来，没新版不取说明，不问接口", error);
            // Beta：跳过还没发出来的 v0.8.0，挑 v0.7.1，说明从 RELEASE-NOTES.md 来，也不问接口
            asked.clear();
            const auto beta = fetchLatest(site, true, "0.6.0", &error);
            check(beta && beta->tag == "v0.7.1" && beta->prerelease &&
                      beta->assets.count("WowType-0.7.1-windows-x64-setup.exe") && highlights(beta->notes) == "- 网页取说明" &&
                      apiCalls() == 0,
                  "Beta：跳过还没发出来的 v0.8.0，说明从 RELEASE-NOTES.md 来", beta ? beta->notes : error);
            // 更早的版本没有 RELEASE-NOTES.md：问一次接口要说明；接口也限流了就指向发布页，检查照样成功
            notesFiles.clear();
            sums.erase("v0.7.1");
            asked.clear();
            api = [&](const std::string &url) {
                HttpResult r;
                r.status = url == std::string("https://api.github.com/repos/Gloridust/WowType/releases/tags/v0.7.0") ? 200 : 404;
                r.body = R"({"tag_name":"v0.7.0","body":"## \u8fd9\u4e00\u7248\u8981\u6ce8\u610f\n\n- \u63a5\u53e3\u53d6\u8bf4\u660e\n"})";
                return r;
            };
            const auto older = fetchLatest(site, true, "0.6.0", &error);
            check(older && older->tag == "v0.7.0" && highlights(older->notes) == "- 接口取说明" && apiCalls() == 1,
                  "没有 RELEASE-NOTES.md 的版本问一次接口要说明", older ? older->notes : error);
            api = limited;
            const auto noNotes = fetchLatest(site, true, "0.6.0", &error);
            check(noNotes && noNotes->notes.find("发布页") != std::string::npos, "说明拿不到：指向发布页，检查照样成功");
            // 网页那条路走不通（页面改了）时退回接口；两条都不通报网页那条的错
            webBroken = true;
            api = [](const std::string &url) {
                HttpResult r;
                r.status = url == kLatestApi ? 200 : 500;
                r.body = R"({"tag_name":"v0.6.0","body":"x","assets":[]})";
                return r;
            };
            const auto fromApi = fetchLatest(site, false, "0.6.0", &error);
            check(fromApi && fromApi->tag == "v0.6.0", "网页走不通时退回接口", error);
            api = limited;
            error.clear();
            check(!fetchLatest(site, false, "0.6.0", &error) && error.find("发布页回了 500") != std::string::npos,
                  "两条路都不通：报网页那条路的错", error);
        }
        check(highlights("# 标题\n## 这一版要注意\n- 一\n## 安装\n步骤") == "- 一", "更新说明认「## 这一版要注意」");
        const auto release = parseRelease(R"({"tag_name":"v0.7.0","prerelease":false,"draft":false,"body":"## \u8fd9\u4e00\u7248\n- \u65b0",)"
                                          R"("assets":[{"name":"WowType-0.7.0-windows-x64-setup.exe","browser_download_url":"https://x/a.exe"},)"
                                          R"({"name":"SHA256SUMS","browser_download_url":"https://x/SHA256SUMS"}]})");
        check(release && release->tag == "v0.7.0" && !release->prerelease && release->assets.size() == 2 &&
                  release->assets.at("SHA256SUMS") == "https://x/SHA256SUMS" && highlights(release->notes) == "- 新",
              "读发布页的 JSON（\\u 转义的中文）", release ? release->notes : "");
        const auto list = parseReleaseList(R"([{"tag_name":"v0.6.0"},{"tag_name":"v0.7.0","prerelease":true}])");
        check(list.size() == 2 && list[1].prerelease && pickNewest(list) == std::optional<std::size_t>(1), "读发布列表");
        const std::string digest(64, 'a');
        const std::string sums = digest + "  WowType-0.7.0-windows-x64-setup.exe\n" + std::string(64, 'b') + " *SHA256SUMS\n";
        std::string error;
        check(checksum(sums, "WowType-0.7.0-windows-x64-setup.exe") == std::optional<std::string>(digest), "SHA256SUMS 里取校验值");
        check(!checksum(sums, "没有.exe", &error) && error.find("没有") != std::string::npos, "SHA256SUMS 里没有就不装");
        check(!checksum(sums + digest + "  WowType-0.7.0-windows-x64-setup.exe\n", "WowType-0.7.0-windows-x64-setup.exe"),
              "重复的不认");
    }
    {
        // 下载续传：206 的 Content-Range
        const auto range = update::parseContentRange("bytes 100-999/1000");
        check(range && range->start == 100 && range->total == 1000, "续传：Content-Range 的起点和总长");
        const auto unknown = update::parseContentRange("bytes 0-9/*");
        check(unknown && unknown->start == 0 && unknown->total == 0, "续传：总长不知道（*）");
        check(!update::parseContentRange("bytes */1000") && !update::parseContentRange("items 0-9/10") &&
                  !update::parseContentRange("bytes 10-5/100") && !update::parseContentRange("bytes 0-99/50") &&
                  !update::parseContentRange("bytes 0-9/10x"),
              "续传：看不懂的 Content-Range 不认（从头下）");
    }

    const auto fresh = [&](Config config = Config{}) {
        auto client = std::make_unique<FakeClient>();
        auto c = std::make_unique<Composer>(engine, client.get());
        c->apply(config);
        return std::make_pair(std::move(c), std::move(client));
    };

    // ---------------------------------------------------------------- 打字
    {
        auto [c, client] = fresh();
        type(*c, "nihao");
        check(c->isComposing(), "打 nihao 进编辑区");
        check(client->marked == "ni'hao", "编辑区分音节", client->marked);
        check(client->markedCursor == static_cast<int>(client->marked.size()), "光标在编辑区末尾");
        check(!client->texts().empty() && client->texts()[0] == "你好", "第一个候选是你好", join(client->texts()));
        c->handle(KeyInput::character(' '));
        check(client->committed == "你好", "空格上屏第一个", client->committed);
        check(!c->isComposing() && client->marked.empty() && !client->page, "上屏后清空编辑区和候选框");
    }
    {
        // InlineSpaceSeparator（#247）：输入框里音节用空格分，光标位置不变；默认关，照旧 '
        Config config;
        config.setValue("InlineSpaceSeparator", "True");
        auto [c, client] = fresh(config);
        type(*c, "nihao");
        check(client->marked == "ni hao" && client->markedCursor == static_cast<int>(client->marked.size()),
              "打开 InlineSpaceSeparator：输入框里是 ni hao", client->marked);
        c->handle(KeyInput::key(keysym::escape));
        type(*c, "xi'an");
        // 后面怎么切看词库（小词库里 an 可能切成 a'n），这里只看输入框里没有 '
        check(client->marked.rfind("xi ", 0) == 0 && client->marked.find('\'') == std::string::npos,
              "手动分隔的 xi'an：输入框里没有 '", client->marked);
    }
    {
        // 右键「忘掉这个词」（#229，和 macOS、fcitx5 一样）：学过的词才有，按显示的序号忘，光标不挪；
        // Ctrl+Delete 忘光标处的
        check(std::string(Composer::forgetMenuTitle) == "忘掉这个词", "右键菜单的字样");
        auto [c, client] = fresh();
        int forgets = 0;
        c->onForget = [&forgets] { ++forgets; };
        const auto indexOf = [&client = *client](const std::string &text) {
            const auto t = client.texts();
            const auto it = std::find(t.begin(), t.end(), text);
            return it == t.end() ? -1 : static_cast<int>(it - t.begin());
        };
        for (int i = 0; i < 2; ++i) {
            type(*c, "nihao");
            if (const int ni = indexOf("尼"); ni >= 0) {
                c->select(ni);
                if (const int hao = indexOf("号"); hao >= 0) {
                    c->select(hao);
                }
            }
        }
        check(client->committed == "尼号尼号", "选 尼 再选 号 上屏 尼号（两次）", client->committed);
        client->committed.clear();
        type(*c, "nihao");
        const auto learned = client->texts();
        const int at = indexOf("尼号");
        const int cursor = client->page ? client->page->cursor : -2;
        check(at >= 0 && c->canForget(at), "学会的 尼号 能忘", join(learned));
        check(!c->canForget(static_cast<int>(learned.size())) && !c->canForget(-1), "越界的不能忘");
        int plain = -1;
        for (int i = 0; i < static_cast<int>(learned.size()) && plain < 0; ++i) {
            if (!c->canForget(i)) {
                plain = i;
            }
        }
        // 小词库里这一页可能都选过（前面的用例上屏过 你好、你）：有没学过的才看它
        if (plain >= 0) {
            c->forget(plain);
            check(forgets == 0 && client->texts() == learned, "没学过的忘了也什么都不做");
        }
        const std::string marked = client->marked;
        c->forget(at);
        check(forgets == 1 && client->committed.empty() && client->marked == marked && c->input() == "nihao" &&
                  client->page && client->page->cursor == cursor,
              "右键忘掉以后马上存，编辑区、光标不动", std::to_string(forgets) + " " + client->marked);
        const int after = indexOf("尼号");
        check(after < 0 || after > at, "忘掉以后 尼号 不再排在原来的位置", join(learned) + "-> " + join(client->texts()));
        check(after < 0 || !c->canForget(after), "忘掉以后不再能忘");
        c->handle(KeyInput::key(keysym::escape));
        check(!c->canForget(0), "没在打字时没有右键菜单");
        // Ctrl+Delete：忘掉光标处的（再学一次，光标挪过去）
        for (int i = 0; i < 2; ++i) {
            type(*c, "nihao");
            if (const int ni = indexOf("尼"); ni >= 0) {
                c->select(ni);
                if (const int hao = indexOf("号"); hao >= 0) {
                    c->select(hao);
                }
            }
        }
        type(*c, "nihao");
        for (int i = 0, n = indexOf("尼号"); i < n; ++i) {
            c->handle(KeyInput::key(keysym::right));
        }
        check(c->handle(KeyInput::key(keysym::del, mod::control)) && forgets == 2 && c->input() == "nihao",
              "Ctrl+Delete 忘掉光标处学过的词", std::to_string(forgets));
        c->handle(KeyInput::key(keysym::escape));
    }
    {
        auto [c, client] = fresh();
        type(*c, "shi");
        const auto texts = client->texts();
        c->handle(KeyInput::character('2'));
        check(texts.size() > 1 && client->committed == texts[1], "数字 2 选第二个", client->committed);
    }
    {
        auto [c, client] = fresh();
        type(*c, "shi");
        const auto all = c->allCandidates();
        const std::size_t pageSize = 9;
        check(all.size() > pageSize, "shi 不止一页", std::to_string(all.size()));
        check(client->page && client->page->texts.size() == pageSize && client->page->hasNext && !client->page->hasPrev,
              "第一页 9 个，后面还有");
        if (all.size() > pageSize) {
            c->handle(KeyInput::character('='));
            check(client->page->hasPrev && client->page->texts[0] == all[pageSize], "= 翻到第二页");
            c->handle(KeyInput::character('-'));
            check(client->page->texts[0] == all[0] && client->committed.empty(), "- 翻回第一页，不当标点上屏");
            c->handle(KeyInput::character('-'));
            check(client->committed.empty() && c->isComposing(), "第一页再按 - 吃掉");
            c->handle(KeyInput::key(keysym::pageDown));
            c->handle(KeyInput::character('1'));
            check(client->committed == all[pageSize], "第二页按 1 选第二页的第一个", client->committed);
            client->committed.clear();
            type(*c, "shi");
            const auto firstPage = client->texts();
            c->handle(KeyInput::key(keysym::pageDown));
            const auto byKey = client->texts();
            c->handle(KeyInput::key(keysym::pageUp));
            c->turnPage(true);
            check(client->page->hasPrev && client->texts() == byKey, "点下一页箭头");
            c->turnPage(false);
            check(client->texts() == firstPage, "点上一页箭头");
            c->select(1);
            check(firstPage.size() > 1 && client->committed == firstPage[1], "点第二个候选", client->committed);
            c->turnPage(true);
            check(!c->isComposing() && client->committed == firstPage[1], "没在打字时点翻页什么都不做");
        }
    }
    {
        // 横排时下键展开面板：一行 6 个，下键走一行，上键在第一行收起
        auto [c, client] = fresh();
        type(*c, "shi");
        const auto all = c->allCandidates();
        c->handle(KeyInput::key(keysym::down));
        check(client->page && client->page->expanded, "下键展开面板");
        c->handle(KeyInput::key(keysym::down));
        check(client->page->cursor == CandidatePage::columns, "面板里下键走一行");
        c->handle(KeyInput::character('2'));
        check(client->committed == all[CandidatePage::columns + 1], "面板里数字选光标所在行的第几个",
              client->committed);
        type(*c, "shi");
        c->handle(KeyInput::key(keysym::down));
        c->handle(KeyInput::key(keysym::up));
        check(!client->page->expanded && c->isComposing(), "第一行再按上键收起面板");
    }
    {
        auto [c, client] = fresh();
        type(*c, "lue");
        check(!client->texts().empty() && client->texts()[0] == "略", "lue 出略");
    }
    {
        // 没在打字时：^ 省略号、_ 破折号、引号左右交替
        auto [c, client] = fresh();
        c->handle(KeyInput::character('^', mod::shift));
        c->handle(KeyInput::character('_', mod::shift));
        check(client->committed == "……——", "^ _", client->committed);
        c->handle(KeyInput::character('"', mod::shift));
        type(*c, "nihao");
        c->handle(KeyInput::character('"', mod::shift));
        check(client->committed == "……——“你好”", "双引号左右交替", client->committed);
    }
    {
        auto [c, client] = fresh();
        type(*c, "nih");
        c->handle(KeyInput::key(keysym::backspace));
        check(c->input() == "ni", "退格删一个字母", c->input());
        c->handle(KeyInput::key(keysym::escape));
        check(!c->isComposing() && client->committed.empty(), "Esc 清空不上屏");
        type(*c, "nihao");
        c->handle(KeyInput::key(keysym::returnKey));
        check(client->committed == "nihao", "回车上屏原始字母", client->committed);
    }
    {
        auto [c, client] = fresh();
        type(*c, "nihao");
        c->handle(KeyInput::character(','));
        check(client->committed == "你好，", "打字途中按逗号：先上屏候选再上屏中文逗号", client->committed);
        c->handle(KeyInput::character('.'));
        check(client->committed == "你好，。", "没在打字时句号是中文句号", client->committed);
    }
    {
        auto [c, client] = fresh();
        type(*c, "nihao");
        c->handle(KeyInput::character('['));
        check(client->committed == "你", "以词定字 [ 取第一个字", client->committed);
        type(*c, "nihao");
        c->handle(KeyInput::character(']'));
        check(client->committed == "你好", "以词定字 ] 取最后一个字", client->committed);
    }
    {
        auto [c, client] = fresh();
        check(!c->handle(KeyInput::character('@', mod::shift)), "@ 交给应用");
        c->handle(KeyInput::character('{', mod::shift));
        type(*c, "nihao");
        c->handle(KeyInput::character('}', mod::shift));
        check(client->committed == "「你好」", "{ } 是直角引号", client->committed);
    }
    {
        // 数字交给了应用，光标前是数字：后面的符号也交给应用原样上屏（20:22）
        auto [c, client] = fresh();
        client->committed = "20";
        check(!c->handle(KeyInput::character(':')), "数字后的冒号交给应用");
        client->committed += ":22";
        type(*c, "nihao");
        c->handle(KeyInput::character(':'));
        check(client->committed == "20:22你好：", "汉字后面的冒号还是中文冒号", client->committed);
    }
    {
        auto [c, client] = fresh();
        check(!c->handle(KeyInput::character('1')), "没在打字时数字交给应用");
        check(!c->handle(KeyInput::character('c', mod::control)), "Ctrl+C 交给应用");
        check(c->handle(KeyInput::character('H', mod::shift)) && c->input() == "H", "大写字母开始编辑区");
        type(*c, "ello");
        c->handle(KeyInput::key(keysym::returnKey));
        check(client->committed == "Hello", "回车上屏 Hello", client->committed);
    }
    {
        // 单按 Shift：打到一半切英文，字母原样上屏
        auto [c, client] = fresh();
        type(*c, "ni");
        check(!c->shiftChanged(true, false, 1000, false), "按下 Shift 不切");
        check(!c->shiftChanged(false, false, 1200, false) && c->isComposing(),
              "0.2 秒内松开算单按：先等双击（#253），拼音还在");
        check(settleShift(*c, 1600) && c->mode() == Composer::Mode::English && client->committed == "ni",
              "没有第二下：到时间切英文并上屏 ni", client->committed);
        check(!c->handle(KeyInput::character('a')), "英文模式字母交给应用");
        c->shiftChanged(true, false, 2000, false);
        c->handle(KeyInput::character('A', mod::shift));
        check(!c->shiftChanged(false, false, 2100, false) && !settleShift(*c, 2600), "Shift+A 不算单按");
        c->shiftChanged(true, false, 3000, false);
        check(!c->shiftChanged(false, false, 3800, false) && !settleShift(*c, 4300), "按太久不算单按");
        c->shiftChanged(true, false, 5000, true);
        c->shiftChanged(false, false, 5100, true);
        check(settleShift(*c, 5500) && c->mode() == Composer::Mode::Chinese, "右 Shift 单按切回中文");
        Config left;
        left.setValue("ShiftToggle", "Left");
        c->apply(left);
        c->shiftChanged(true, false, 6000, true);
        check(!c->shiftChanged(false, false, 6100, true) && !settleShift(*c, 6500), "ShiftToggle=Left 时右 Shift 不切");
    }
    {
        // #253：双击 Shift（JetBrains 的到处搜索）不切中英文。单按先等双击间隔，外壳排定时器
        auto [c, client] = fresh();
        uint32_t polled = 0;
        c->onTranslatePoll = [&polled](uint32_t ms) { polled = ms; };
        type(*c, "ni");
        c->shiftChanged(true, false, 1000, false);
        check(!c->shiftChanged(false, false, 1080, false) && polled > 0 && polled <= 400,
              "单按以后叫外壳排定时器", std::to_string(polled));
        c->shiftChanged(true, false, 1250, false);
        check(!c->shiftChanged(false, false, 1330, false), "间隔以内的第二下也不切");
        check(!settleShift(*c, 3000) && c->mode() == Composer::Mode::Chinese && c->isComposing() &&
                  client->committed.empty(),
              "双击 Shift：过了时间也不切，拼音留着", client->committed);
        // 单按以后接着按键：这个键之前先切（ni 原样上屏），键照英文交给应用
        c->shiftChanged(true, false, 5000, false);
        c->shiftChanged(false, false, 5080, false);
        check(!c->handle(KeyInput::character('a')) && c->mode() == Composer::Mode::English &&
                  client->committed == "ni",
              "单按以后接着按键：先切英文，a 交给应用", client->committed);
        // 按住 Shift 时按了 Ctrl（别的修饰键）：等着的那一下也先切
        c->shiftChanged(true, false, 6000, false);
        c->shiftChanged(false, false, 6080, false);
        c->otherModifierChanged();
        check(c->mode() == Composer::Mode::Chinese, "等双击时按了别的修饰键：先切回中文");
        // 过了间隔才按第二下（定时器晚了）：第一下在按下时切，第二下自己再等
        c->shiftChanged(true, false, 7000, false);
        c->shiftChanged(false, false, 7080, false);
        c->shiftChanged(true, false, 7600, false);
        check(c->mode() == Composer::Mode::English, "过了间隔才按第二下：第一下照切");
        c->shiftChanged(false, false, 7680, false);
        check(c->mode() == Composer::Mode::English && settleShift(*c, 8100) && c->mode() == Composer::Mode::Chinese,
              "第二下到时间也切");
    }
    {
        // #191：互译只翻一句（TranslateOneShot）。翻译器填了地址和模型就算能翻（这里连不上，不等译文：
        // 译文上屏以后回去在核心的会话测试、fcitx5 按键测试里测）
        WowtypeTranslator *translator = wowtype_translate_new();
        wowtype_translate_configure(translator, "http://127.0.0.1:9/v1", "mock", "en", 0, nullptr);
        Config config;
        config.setValue("Translate", "True");
        config.setValue("TranslateOneShot", "True");
        auto [c, client] = fresh(config);
        c->setTranslator(translator);
        std::vector<std::string> seen;
        c->onCommitStats = [&](const std::string &text, const std::string &source, const std::string &, int index) {
            seen.push_back(text + "|" + source + "|" + std::to_string(index));
        };
        using M = Composer::Mode;
        const auto doubleTap = [&c = c](uint64_t at) {
            c->shiftChanged(true, false, at, false);
            c->shiftChanged(false, false, at + 80, false);
            c->shiftChanged(true, false, at + 250, false);
            return c->shiftChanged(false, false, at + 330, false);
        };
        c->shiftChanged(true, false, 1000, false);
        c->shiftChanged(false, false, 1080, false);
        check(settleShift(*c, 1500) && c->mode() == M::English, "#191：单按 Shift 先到英文");
        check(doubleTap(2000) && c->mode() == M::Translate, "#191：英文里双击进「译」（这一下切了模式）");
        check(!settleShift(*c, 3000) && c->mode() == M::Translate, "#191：过了间隔也不再切");
        type(*c, "nihao ");
        check(c->translateSource() == "你好" && client->committed.empty(), "#191：打的字攒成原文", c->translateSource());
        check(c->handle(KeyInput::key(keysym::escape)) && c->mode() == M::English && client->committed.empty() &&
                  c->translateSource().empty(),
              "#191：Esc 放弃，回到英文", client->committed);
        c->shiftChanged(true, false, 4000, false);
        c->shiftChanged(false, false, 4080, false);
        check(settleShift(*c, 4500) && c->mode() == M::Chinese, "#191：单按回中文（不经过「译」）");
        // 打到一半双击：拼音带进「译」接着打；Shift+回车上屏原文，回到中文，照「译」记统计
        type(*c, "ni");
        check(doubleTap(5000) && c->mode() == M::Translate && c->isComposing() && client->committed.empty(),
              "#191：打到一半双击，拼音带进「译」", client->committed);
        type(*c, "hao ");
        check(c->translateSource() == "你好", "#191：接着打完进原文", c->translateSource());
        check(c->handle(KeyInput::key(keysym::returnKey, mod::shift)) && c->mode() == M::Chinese &&
                  client->committed == "你好" && seen.size() == 1 && seen[0] == "你好|translate|0",
              "#191：Shift+回车上屏原文，回到中文", client->committed + " " + join(seen));
        // 「译」里再双击：回去
        check(doubleTap(7000) && c->mode() == M::Translate, "#191：中文里双击进「译」");
        check(doubleTap(8000) && c->mode() == M::Chinese, "#191：「译」里再双击回中文");
        // 关着：双击两下都不算，单按照旧 中 → 英 → 译
        config.setValue("TranslateOneShot", "False");
        c->apply(config);
        check(!doubleTap(9000) && !settleShift(*c, 10000) && c->mode() == M::Chinese, "#191：关着时双击 Shift 不切");
        tapShift(*c);
        tapShift(*c);
        check(c->mode() == M::Translate, "#191：关着时单按照旧切到「译」");
        c->setTranslator(nullptr);
        wowtype_translate_free(translator);
    }
    {
        // 系统要结束组字：打的字母原样上屏，不带分音节的隔音符
        auto [c, client] = fresh();
        type(*c, "nihao");
        c->commitComposition();
        check(client->committed == "nihao" && client->marked.empty() && !client->page, "结束组字时原样上屏字母",
              client->committed);
        client->committed.clear();
        type(*c, "nihaoshi");
        const auto texts = client->texts();
        for (std::size_t i = 0; i < texts.size(); ++i) {
            if (texts[i] == "你好") {
                c->select(static_cast<int>(i));
                break;
            }
        }
        check(client->marked == "你好shi" && client->committed.empty(), "选了句首的词", client->marked);
        c->commitComposition();
        check(client->committed == "你好shi", "选了一半：已选的词 + 剩下的字母", client->committed);
    }
    {
        // 打字统计的回调：上屏的字、来源、候选位置（和 macOS 的 onCommitStats 一样）
        auto [c, client] = fresh();
        std::vector<std::string> seen;
        c->onCommitStats = [&](const std::string &text, const std::string &source, const std::string &scheme, int index) {
            seen.push_back(text + "|" + source + "|" + scheme + "|" + std::to_string(index));
        };
        type(*c, "shi");
        c->handle(KeyInput::character('2'));
        c->handle(KeyInput::character(','));
        check(seen.size() == 2 && seen[0].find("|quanpin||2") != std::string::npos && seen[1] == "，|quanpin||0",
              "统计：选第二个候选记位置 2，标点记 0", join(seen));
    }
    {
        // 词库还没载入：字母交给应用，载入以后照常打字
        FakeClient client;
        Composer c(nullptr, &client);
        check(!c.handle(KeyInput::character('n')) && !c.isComposing(), "没有词库时字母交给应用");
        c.setEngine(engine);
        type(c, "nihao ");
        check(client.committed == "你好", "载入词库后照常打字", client.committed);
    }
    {
        // v + 空格的工具栏、Control+. 的表情面板
        auto [c, client] = fresh();
        type(*c, "v");
        check(c->handle(KeyInput::character(' ')) && c->openPanel() == Composer::Panel::Menu, "v + 空格打开工具栏");
        check(client->marked.empty() && client->committed.empty() && !c->isComposing(), "打开工具栏时 v 不上屏");
        check(client->page && client->page->vertical && client->texts().size() == 4, "工具栏竖排四项",
              join(client->texts()));
        tapShift(*c);
        check(c->mode() == Composer::Mode::Chinese, "工具栏开着时单按 Shift 不切");
        check(!c->handle(KeyInput::character('c', mod::control)) && c->openPanel() == Composer::Panel::None &&
                  !client->page,
              "Ctrl+C 收起工具栏、交给应用");
        check(c->handle(KeyInput::character('.', mod::control)) && c->openPanel() == Composer::Panel::Emoji,
              "Control+. 打开表情面板");
        check(client->page && client->page->expanded && !client->texts().empty(), "表情面板是网格");
        c->handle(KeyInput::character('1'));
        check(!client->committed.empty() && c->openPanel() == Composer::Panel::None, "数字选表情上屏",
              client->committed);
    }
    {
        // 联想（Association）：上屏以后出一页，没进联想行时不画序号；按字母先关掉联想再照常打
        Config config;
        config.setValue("Association", "True");
        auto [c, client] = fresh(config);
        type(*c, "nihao ");
        check(client->committed == "你好", "联想开着照常上屏");
        if (client->page) {
            check(!client->page->labels, "联想没进联想行时不画序号");
        }
        type(*c, "ni");
        check(c->isComposing() && client->page && client->page->labels, "打字母关掉联想、照常打");
    }
    {
        // 互译没配好：单按 Shift 只在中英之间切
        Config config;
        config.setValue("Translate", "True");
        auto [c, client] = fresh(config);
        check(!c->translateAvailable(), "没有翻译器时「译」不可用");
        tapShift(*c);
        tapShift(*c);
        check(c->mode() == Composer::Mode::Chinese, "中 → 英 → 中");
        check(!c->setModeNamed("translate") && c->setModeNamed("en") && c->modeName() == "en", "外部命令切模式");
        Config english;
        english.setValue("InitialMode", "English");
        c->apply(english);
        c->setModeNamed("zh");
        c->applyInitialMode();
        check(c->mode() == Composer::Mode::English, "InitialMode=English");
    }
    {
        // #254：换窗口、换应用时按 WindowMode 定中 / 英；默认 Same 不动
        Config same;
        auto [c, client] = fresh(same);
        tapShift(*c);
        c->applyWindowMode();
        check(c->mode() == Composer::Mode::English, "WindowMode 默认 Same：换窗口还是英文");
        Config english;
        english.setValue("WindowMode", "English");
        c->apply(english);
        c->setModeNamed("zh");
        c->applyWindowMode();
        check(c->mode() == Composer::Mode::English, "WindowMode=English：换窗口后是英文");
        tapShift(*c);
        check(c->mode() == Composer::Mode::Chinese, "单按 Shift 还是能切回中文");
        c->applyWindowMode();
        check(c->mode() == Composer::Mode::English, "再换窗口又回到默认的英文");
        Config chinese;
        chinese.setValue("WindowMode", "Chinese");
        c->apply(chinese);
        c->applyWindowMode();
        check(c->mode() == Composer::Mode::Chinese && client->committed.empty(), "WindowMode=Chinese：换窗口后是中文");
        Config noWayBack;
        noWayBack.setValue("WindowMode", "English");
        noWayBack.setValue("ShiftToggle", "Off");
        c->apply(noWayBack);
        c->applyWindowMode();
        check(c->mode() == Composer::Mode::Chinese, "WindowMode=English 但切不回中文：总是中文");
    }

    // ---------------------------------------------------------------- 自动配对（和 macOS、fcitx5 的一样）
    const auto withPairing = [&](auto body) {
        Config config;
        config.setValue("AutoPairPunct", "True");
        config.setValue("EmojiSuggest", "False");
        CaretClient client;
        Composer c(engine, &client);
        c.apply(config);
        body(c, client);
    };
    withPairing([&](Composer &c, CaretClient &client) {
        pairType(c, client, "(");
        check(client.shown() == "（|）", "( 上屏（），光标在中间", client.shown());
        pairType(c, client, "3)");
        check(client.shown() == "（3）|", "( 3 ) 是（3）：) 跳过补好的右括号", client.shown());
    });
    withPairing([&](Composer &c, CaretClient &client) {
        pairType(c, client, "(nihao)");
        check(client.shown() == "（你好）|", "( nihao ) 上屏你好再跳过右括号", client.shown());
    });
    withPairing([&](Composer &c, CaretClient &client) {
        pairType(c, client, "nihao(");
        check(client.shown() == "你好（|）", "打拼音途中按 (：先上屏候选，再上屏（）", client.shown());
    });
    withPairing([&](Composer &c, CaretClient &client) {
        pairType(c, client, "((");
        pairType(c, client, "))");
        check(client.shown() == "（（））|", "套着的两层都跳过", client.shown());
    });
    withPairing([&](Composer &c, CaretClient &client) {
        pairType(c, client, "(");
        check(c.handle(KeyInput::key(keysym::backspace)) && client.shown() == "|", "空的一对退格：两个一起删",
              client.shown());
    });
    withPairing([&](Composer &c, CaretClient &client) {
        pairType(c, client, "(1<");
        check(client.shown() == "（|）", "里面有字时退格照常交给应用", client.shown());
        pairType(c, client, "<");
        check(client.shown() == "|", "删空了再退格：两个一起删", client.shown());
    });
    withPairing([&](Composer &c, CaretClient &client) {
        pairType(c, client, "({)");
        check(client.shown() == "）|（）", "按了方向键以后 ) 照常上屏", client.shown());
    });
    withPairing([&](Composer &c, CaretClient &client) {
        client.editable = false;
        pairType(c, client, "(");
        check(client.shown() == "（|", "说不清光标在哪的输入框里不配对", client.shown());
    });

    {
        // 输入框清空了（光标前没有字，应用说得清）：会话清掉记的上文，不拿上一次上屏的字学搭配。
        // 和 fcitx5、macOS 一样；对照：没清空时接着打，搭配照常学到
        auto [c, client] = fresh();
        const auto pairs = [&] {
            const auto path = dir / "context-history.tsv";
            wowtype_engine_save_history(engine, path.string().c_str());
            std::ifstream in(path, std::ios::binary);
            return std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
        };
        type(*c, "kaixin ");
        check(client->committed == "开心", "kaixin 空格上屏开心", client->committed);
        client->committed.clear();
        type(*c, "lve ");
        check(client->committed == "略", "清空输入框后打略", client->committed);
        check(pairs().find("p\t开心\t略\t") == std::string::npos, "清空输入框后不学上一次上屏的字的搭配（开心 → 略）");
        type(*c, "hao");
        const auto texts = client->texts();
        for (std::size_t i = 0; i < texts.size(); ++i) {
            if (texts[i] == "号") {
                c->select(static_cast<int>(i));
                break;
            }
        }
        check(client->committed == "略号", "没清空接着选号", client->committed);
        check(pairs().find("p\t略\t号\t") != std::string::npos, "没清空时照常学搭配（略 → 号）");
    }

    // ---------------------------------------------------------------- 开发者模式的打字记录（docs/DEVLOG.md）
    {
        check(!Config().flag("DeveloperMode") && Config::parse("DeveloperMode=True\n").flag("DeveloperMode"),
              "DeveloperMode 默认关、读得出来");
        const std::string devlog = (dir / "devlog.jsonl").string();
        auto lines = [&devlog]() {
            std::vector<std::string> out;
            std::ifstream in(devlog);
            for (std::string line; std::getline(in, line);) {
                out.push_back(line);
            }
            return out;
        };
        auto has = [](const std::string &line, const std::string &part) { return line.find(part) != std::string::npos; };
        auto [c, client] = fresh();
        type(*c, "nihao ");
        check(lines().empty() && wowtype_devlog_enabled() == 0, "开发者模式关着时什么都不记");
        // 外壳读到 DeveloperMode=True 时就是这样打开的（engine_host.cpp 的 loadConfig）
        check(wowtype_devlog_configure(devlog.c_str(), 1) == 0 && wowtype_devlog_enabled() == 1, "打开开发者模式");
        wowtype_devlog_set_app("notepad.exe");
        type(*c, "nihao ");
        auto got = lines();
        check(got.size() == 1 && has(got[0], "\"e\":\"commit\"") && has(got[0], "\"input\":\"nihao\"") &&
                  has(got[0], "\"pick\":1") && has(got[0], "\"via\":\"space\"") && has(got[0], "\"cands\":[") &&
                  has(got[0], "\"app\":\"notepad.exe\""),
              "开发者模式：上屏记一行（输入、选了第几个、怎么选的、候选、应用）", got.empty() ? "没有记录" : got[0]);
        check(wowtype_devlog_configure(nullptr, 0) == 0 && wowtype_devlog_enabled() == 0, "关上开发者模式");
        type(*c, "nihao ");
        check(lines().size() == 1, "开发者模式关掉以后不再记");
        check(wowtype_devlog_clear(devlog.c_str()) == 0 && lines().empty(), "清空打字记录");
        wowtype_devlog_set_app(nullptr);
    }

    wowtype_engine_free(engine);
    std::error_code ignored;
    std::filesystem::remove_all(dir, ignored);
    if (failures) {
        std::printf("\n%d 项没过\n", failures);
        return 1;
    }
    std::printf("\nwindows composer ok\n");
    return 0;
}
