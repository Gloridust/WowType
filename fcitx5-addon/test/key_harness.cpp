// 插件按键行为测试：起一个无界面、无 D-Bus 的私有 fcitx5 实例，只加载 wowtype，
// 用一个假的输入上下文按键，检查上屏结果。不会碰到正在运行的 fcitx5。
//
// 由 scripts/addon-test.sh 设置好隔离的 XDG 目录和词库后运行。

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

#include <fcitx/addoninstance.h>
#include <fcitx/addonfactory.h>
#include <fcitx/addonloader.h>
#include <unistd.h>
#include <iterator>

#include "clipboard_copy.h"
#include "data_files.h"
#include <fcitx/addonmanager.h>
#include <fcitx/candidatelist.h>
#include <fcitx/inputmethodentry.h>
#include <fcitx/inputmethodmanager.h>
#include <fcitx/event.h>
#include <fcitx/globalconfig.h>
#include <fcitx-config/rawconfig.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputcontextmanager.h>
#include <fcitx/inputpanel.h>
#include <fcitx/instance.h>
#include <cstdlib>
#include <fcitx-utils/dbus/bus.h>
#include <fcitx-utils/dbus/matchrule.h>
#include <fcitx-utils/dbus/message.h>
#include <fcitx-utils/event.h>
#include <fcitx-utils/eventdispatcher.h>
#include <fcitx-utils/key.h>
#include <fcitx-utils/keysym.h>
#include <fcitx-utils/utf8.h>

// 假的 fcitx5 clipboard 插件（scripts/addon-test.sh 写了它的 addon 配置）：插件从它拿最新一条剪贴板
FCITX_ADDON_DECLARE_FUNCTION(Clipboard, clipboard, std::string(const fcitx::InputContext *ic));

using namespace fcitx;

namespace {

class Clipboard final : public AddonInstance {
public:
    std::string clipboard(const InputContext * /*ic*/) { return text; }
    std::string text;

private:
    FCITX_ADDON_EXPORT_FUNCTION(Clipboard, clipboard);
};

Clipboard *fakeClipboard = nullptr;

class FakeClipboardFactory final : public AddonFactory {
public:
    AddonInstance *create(AddonManager * /*manager*/) override {
        fakeClipboard = new Clipboard;
        return fakeClipboard;
    }
};


class HarnessInputContext : public InputContext {
public:
    explicit HarnessInputContext(InputContextManager &manager)
        : InputContext(manager, "wowtype-harness") {
        created();
    }
    ~HarnessInputContext() override { destroy(); }

    const char *frontend() const override { return "wowtype-harness"; }
    void commitStringImpl(const std::string &text) override { committed += text; }
    void deleteSurroundingTextImpl(int, unsigned int) override {}
    void forwardKeyImpl(const ForwardKeyEvent &event) override {
        if (!event.isRelease()) {
            forwarded += Key::keySymToString(event.rawKey().sym()) + " ";
        }
    }
    void updatePreeditImpl() override {}

    std::string committed;
    /// 输入法发给应用的键（按下的那一下），空格隔开
    std::string forwarded;
    /// 输入法没接的键（直接交给应用的）
    std::string passed;
};

int failures = 0;
/// main 里建的事件分发器（fcitx5 5.1.7 的 Instance 还没有 eventDispatcher()）。
EventDispatcher *dispatcher = nullptr;

void check(bool ok, const std::string &what) {
    std::printf("%s %s\n", ok ? "ok  " : "FAIL", what.c_str());
    if (!ok) {
        ++failures;
    }
}

bool send(HarnessInputContext *ic, Key key) {
    KeyEvent press(ic, key, false);
    const bool handled = ic->keyEvent(press);
    KeyEvent release(ic, key, true);
    ic->keyEvent(release);
    if (!handled && key.isSimple()) {
        ic->passed += Key::keySymToUTF8(key.sym());
    }
    return handled;
}

/// 按一串键。<sp> <bs> <cr> <esc> <down> <right> <pgdn> 是特殊键，其余按字符。
void type(HarnessInputContext *ic, const std::string &keys) {
    for (std::size_t i = 0; i < keys.size(); ++i) {
        if (keys[i] == '<') {
            const auto end = keys.find('>', i);
            const std::string name = keys.substr(i + 1, end - i - 1);
            i = end;
            KeySym sym = FcitxKey_None;
            if (name == "sp") sym = FcitxKey_space;
            else if (name == "bs") sym = FcitxKey_BackSpace;
            else if (name == "cr") sym = FcitxKey_Return;
            else if (name == "esc") sym = FcitxKey_Escape;
            else if (name == "down") sym = FcitxKey_Down;
            else if (name == "right") sym = FcitxKey_Right;
            else if (name == "left") sym = FcitxKey_Left;
            else if (name == "up") sym = FcitxKey_Up;
            else if (name == "pgdn") sym = FcitxKey_Page_Down;
            else if (name == "tab") sym = FcitxKey_Tab;
            else if (name == "home") sym = FcitxKey_Home;
            else if (name == "end") sym = FcitxKey_End;
            else if (name == "del") sym = FcitxKey_Delete;
            if (name == "stab") {
                send(ic, Key(FcitxKey_ISO_Left_Tab, KeyState::Shift));
                continue;
            }
            send(ic, Key(sym));
            continue;
        }
        const char c = keys[i];
        if (c >= 'A' && c <= 'Z') {
            send(ic, Key(static_cast<KeySym>(c), KeyState::Shift));
        } else {
            send(ic, Key(static_cast<KeySym>(static_cast<unsigned char>(c))));
        }
    }
}

std::string preedit(HarnessInputContext *ic) {
    return ic->inputPanel().preedit().toString();
}

std::vector<std::string> page(HarnessInputContext *ic) {
    std::vector<std::string> out;
    if (auto list = ic->inputPanel().candidateList()) {
        for (int i = 0; i < list->size(); ++i) {
            out.push_back(list->candidate(i).text().toString());
        }
    }
    return out;
}

std::string join(const std::vector<std::string> &items) {
    std::string out;
    for (const auto &item : items) {
        out += item + " ";
    }
    return out;
}

/// 每个用例前清空上屏记录和编辑区。
void setClipboard(const std::string &text) {
    check(fakeClipboard != nullptr, "假的 clipboard 插件载入了");
    if (fakeClipboard) {
        fakeClipboard->text = text;
    }
}

void fresh(HarnessInputContext *ic) {
    type(ic, "<esc>");
    ic->committed.clear();
    ic->passed.clear();
    ic->forwarded.clear();
}

/// 单按一个修饰键（按下 + 松开），比如单按 Shift 切中英文。
void tapKey(HarnessInputContext *ic, KeySym sym) {
    KeyEvent press(ic, Key(sym), false);
    ic->keyEvent(press);
    KeyEvent release(ic, Key(sym, KeyState::Shift), true);
    ic->keyEvent(release);
}

void runCases(Instance &instance) {
    auto ic = std::make_unique<HarnessInputContext>(instance.inputContextManager());
    ic->focusIn();
    instance.setCurrentInputMethod(ic.get(), "wowtype", true);
    check(instance.inputMethod(ic.get()) == "wowtype", "当前输入法是 wowtype");
    std::string ims;
    instance.inputMethodManager().foreachEntries([&ims](const InputMethodEntry &entry) {
        ims += entry.uniqueName() + " ";
        return true;
    });
    std::printf("可用输入法：%s\n", ims.c_str());

    // 词库在后台载入，等它好（最多 20 秒）
    for (int i = 0; i < 200; ++i) {
        fresh(ic.get());
        type(ic.get(), "nihao");
        if (!page(ic.get()).empty()) {
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    fresh(ic.get());

    type(ic.get(), "nihao<sp>");
    check(ic->committed == "你好", "nihao 空格 -> 你好，实际 " + ic->committed);

    fresh(ic.get());
    type(ic.get(), "nihao,");
    check(ic->committed == "你好，", "打字途中按逗号：先上屏再出中文逗号，实际 " + ic->committed);

    // 数字后的句点是小数点（#50）：数字原样交给应用，句点也原样
    fresh(ic.get());
    type(ic.get(), "3.14");
    check(ic->committed.empty() && ic->passed == "3.14", "3.14 原样（小数点不换成句号），实际 上屏「" +
                                                            ic->committed + "」交给应用「" + ic->passed + "」");
    // 数字后面的其他符号也原样：20:22、3,000、50%
    for (const char *text : {"20:22", "3,000", "50%"}) {
        fresh(ic.get());
        type(ic.get(), text);
        check(ic->committed.empty() && ic->passed == text,
              std::string(text) + " 原样（数字后的符号不换成中文标点），实际 上屏「" + ic->committed +
                  "」交给应用「" + ic->passed + "」");
    }
    // 顿号没有半角形态：数字后面按 \ 还是顿号（#250）
    fresh(ic.get());
    type(ic.get(), "1\\");
    check(ic->passed == "1" && ic->committed == "、", "1\\ -> 1、，实际 上屏「" + ic->committed +
                                                       "」交给应用「" + ic->passed + "」");
    // 以词定字（#83）：[ 取首选的第一个字，] 取最后一个字；单字时照常先上屏再出【】
    fresh(ic.get());
    type(ic.get(), "nihao[");
    check(ic->committed == "你", "以词定字 nihao [ → 你，实际 " + ic->committed);
    fresh(ic.get());
    type(ic.get(), "nihao]");
    check(ic->committed == "好", "以词定字 nihao ] → 好，实际 " + ic->committed);
    // @ # % & * 没有中文写法，原样（#91）；{ } 是直角引号（#96）
    fresh(ic.get());
    type(ic.get(), "@#%&*");
    check(ic->committed.empty() && ic->passed == "@#%&*", "@#%&* 原样交给应用，实际 上屏「" + ic->committed +
                                                             "」交给应用「" + ic->passed + "」");
    fresh(ic.get());
    type(ic.get(), "nihao@");
    check(ic->committed == "你好@", "打字途中按 @：先上屏再出半角 @，实际 " + ic->committed);
    fresh(ic.get());
    type(ic.get(), "{nihao}");
    check(ic->committed == "「你好」", "{ } 是直角引号，实际 " + ic->committed);
    fresh(ic.get());
    type(ic.get(), "nihao:");
    check(ic->committed == "你好：", "汉字后面的冒号还是中文冒号，实际 " + ic->committed);
    fresh(ic.get());
    type(ic.get(), "nihao.");
    check(ic->committed == "你好。", "汉字后面的句点还是句号，实际 " + ic->committed);
    fresh(ic.get());
    type(ic.get(), "3<bs>.");
    check(ic->committed == "。", "删掉数字后句点是句号，实际 " + ic->committed);

    fresh(ic.get());
    type(ic.get(), "zhognguo<sp>");
    check(ic->committed == "中国", "按反纠错 zhognguo -> 中国，实际 " + ic->committed);

    fresh(ic.get());
    type(ic.get(), "nihao<cr>");
    check(ic->committed == "nihao", "回车上屏原始字母，实际 " + ic->committed);

    fresh(ic.get());
    type(ic.get(), "github<sp>");
    check(ic->committed == "GitHub", "英文词 github -> GitHub，实际 " + ic->committed);

    fresh(ic.get());
    type(ic.get(), "Hello<sp>");
    check(ic->committed == "Hello", "大写保留 Hello，实际 " + ic->committed);

    // 打全了的拼音正好是一个词：它排第一，不被高频补全（重点）、单字（看）换掉
    fresh(ic.get());
    type(ic.get(), "zhongdi<sp>");
    check(ic->committed == "种地", "zhongdi 空格 -> 种地，实际 " + ic->committed);
    fresh(ic.get());
    type(ic.get(), "ka<sp>");
    check(ic->committed == "卡", "ka 空格 -> 卡，实际 " + ic->committed);

    // Ctrl+Delete 忘掉学错的词（#102）：选够三次学进用户词库的词，光标挪到它上面按 Ctrl+Delete，
    // 编辑区不动，user.tsv 马上重写、里面没有它了
    fresh(ic.get());
    type(ic.get(), "ka");
    {
        const auto before = page(ic.get());
        const std::string word = before.size() > 1 ? before[1] : "";
        for (int i = 0; i < 3 && !word.empty(); ++i) {
            fresh(ic.get());
            type(ic.get(), "ka");
            const auto now = page(ic.get());
            const auto it = std::find(now.begin(), now.end(), word);
            if (it == now.end()) {
                break;
            }
            type(ic.get(), std::to_string(it - now.begin() + 1));
        }
        fresh(ic.get());
        type(ic.get(), "ka");
        const auto learned = page(ic.get());
        const auto at = std::find(learned.begin(), learned.end(), word);
        check(!word.empty() && at != learned.end(), "ka 选了三次的 " + word + " 还在第一页：" + join(learned));
        for (auto i = learned.begin(); i != at && at != learned.end(); ++i) {
            type(ic.get(), "<right>");
        }
        // 先删掉 user.tsv：按完以后它又出现了，说明是忘掉以后马上存的（平时攒 20 次上屏才存）
        const char *dictPath = std::getenv("WOWTYPE_USER_DICT");
        std::error_code ec;
        if (dictPath) {
            std::filesystem::remove(dictPath, ec);
        }
        const bool took = send(ic.get(), Key(FcitxKey_Delete, KeyState::Ctrl));
        const auto after = page(ic.get());
        check(took && preedit(ic.get()) == "ka" && ic->committed.empty() && ic->passed.empty() &&
                  !after.empty(),
              "Ctrl+Delete 吃掉，编辑区不动：" + preedit(ic.get()) + " / " + join(after));
        // 存盘在核心的后台线程上（按键的线程不等磁盘）：等它写出来，最多 3 秒
        for (int i = 0; dictPath && i < 300 && !std::filesystem::exists(dictPath, ec); ++i) {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        std::ifstream in(dictPath ? dictPath : "");
        const std::string dict((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        check(dictPath && in.is_open() && dict.find("\t" + word + "\t") == std::string::npos,
              "忘掉以后马上存了 user.tsv，里面没有 " + word + "：" + dict);
        type(ic.get(), "<sp>");
        check(!ic->committed.empty(), "接着按空格照常上屏：" + ic->committed);
    }
    fresh(ic.get());
    check(!send(ic.get(), Key(FcitxKey_Delete, KeyState::Ctrl)), "没在打字时 Ctrl+Delete 交给应用");

    // 打字途中会话不管的键（小键盘的 + - * / .、F 键、Insert、不是 ASCII 的键……）都吃掉：
    // 交给应用的话，小键盘的 + 先到应用、上屏后成了「+你好」，F5 把网页刷新掉
    fresh(ic.get());
    type(ic.get(), "nihao");
    {
        const std::string before = preedit(ic.get());
        const auto candidates = page(ic.get());
        std::string leaked;
        for (const KeySym sym :
             {FcitxKey_KP_Add, FcitxKey_KP_Subtract, FcitxKey_KP_Multiply, FcitxKey_KP_Divide,
              FcitxKey_KP_Decimal, FcitxKey_F1, FcitxKey_F5, FcitxKey_F12, FcitxKey_Insert,
              FcitxKey_Menu, FcitxKey_Pause, FcitxKey_Home, FcitxKey_Delete, FcitxKey_eacute,
              FcitxKey_Cyrillic_a, FcitxKey_dead_acute}) {
            if (!send(ic.get(), Key(sym))) {
                leaked += Key(sym).toString() + " ";
            }
        }
        // Shift 加上这些键也一样（Shift+F10 是右键菜单、Shift+Insert 是粘贴）
        for (const KeySym sym : {FcitxKey_F10, FcitxKey_Insert, FcitxKey_KP_Add}) {
            if (!send(ic.get(), Key(sym, KeyState::Shift))) {
                leaked += Key(sym, KeyState::Shift).toString() + " ";
            }
        }
        check(leaked.empty(), "打字途中会话不管的键都吃掉，漏给应用的：" + leaked);
        check(preedit(ic.get()) == before && page(ic.get()) == candidates && ic->committed.empty() &&
                  ic->passed.empty(),
              "吃掉以后编辑区和候选不动：" + preedit(ic.get()) + " 上屏「" + ic->committed + "」");
        // 修饰键、锁定键本身，松开的键，带 Ctrl / Alt / Super 的组合键照常交给应用
        std::string eaten;
        for (const KeySym sym : {FcitxKey_Control_L, FcitxKey_Alt_L, FcitxKey_Super_L,
                                 FcitxKey_Caps_Lock, FcitxKey_Num_Lock, FcitxKey_ISO_Level3_Shift}) {
            KeyEvent press(ic.get(), Key(sym), false);
            if (ic->keyEvent(press)) {
                eaten += Key(sym).toString() + " ";
            }
        }
        for (const KeySym sym : {FcitxKey_F5, FcitxKey_KP_Add, FcitxKey_Control_L}) {
            KeyEvent release(ic.get(), Key(sym), true);
            if (ic->keyEvent(release)) {
                eaten += Key(sym).toString() + "(松开) ";
            }
        }
        for (const Key &key : {Key(FcitxKey_c, KeyState::Ctrl), Key(FcitxKey_F4, KeyState::Alt),
                               Key(FcitxKey_F5, KeyState::Ctrl), Key(FcitxKey_KP_Add, KeyState::Super)}) {
            if (send(ic.get(), key)) {
                eaten += key.toString() + " ";
            }
        }
        check(eaten.empty(), "打字途中修饰键本身、松开的键、带 Ctrl / Alt / Super 的组合键照常交给应用，吃掉的：" +
                                 eaten);
        check(preedit(ic.get()) == before, "交给应用以后编辑区还在：" + preedit(ic.get()));
        type(ic.get(), "<sp>");
        check(ic->committed == "你好", "接着空格照常上屏，前面没有多出来的字，实际 " + ic->committed);
    }
    fresh(ic.get());
    check(!send(ic.get(), Key(FcitxKey_F5)) && !send(ic.get(), Key(FcitxKey_KP_Add)) &&
              !send(ic.get(), Key(FcitxKey_Insert)),
          "没在打字时这些键照常交给应用");
    // 上屏后紧接着按退格：刚才那次上屏学到的退回去（选了第二个又删掉，下次还是原来的第一个）；
    // 不删的话选过的就排到前面
    {
        // 挑第一页里第二个以后的第一个多字词（单字选过只放到第二，看不出来）；词库不同第一页不同
        // （新词库里 xian 第一页全是单字），挨个试，用第一个有的
        std::string input;
        std::vector<std::string> before;
        std::size_t pick = 1;
        bool found = false;
        for (const char *candidate : {"xian", "shiyan", "gongshi", "jiaoyu"}) {
            fresh(ic.get());
            type(ic.get(), candidate);
            before = page(ic.get());
            pick = 1;
            while (pick < before.size() && fcitx::utf8::length(before[pick]) < 2) {
                ++pick;
            }
            found = pick < before.size() && pick < 9;
            if (found) {
                input = candidate;
                break;
            }
        }
        const std::string word = found ? before[pick] : "";
        const std::string digit = std::to_string(pick + 1);
        bool ok = found;
        for (int i = 0; i < 3 && ok; ++i) {
            fresh(ic.get());
            type(ic.get(), input + digit + "<bs>");
            ok = ic->committed == word;
        }
        fresh(ic.get());
        type(ic.get(), input);
        const auto after = page(ic.get());
        check(ok && !after.empty() && after[0] == before[0],
              "选了 " + word + " 又马上退格（三次）：" + input + " 的第一个还是 " + (before.empty() ? "" : before[0]) +
                  "，实际 " + join(after));
        fresh(ic.get());
        type(ic.get(), input + digit);
        fresh(ic.get());
        type(ic.get(), input);
        const auto kept = page(ic.get());
        check(found && !kept.empty() && kept[0] == word,
              "不退格就记着：" + input + " 选过的 " + word + " 排第一，实际 " + join(kept));
        // 收拾：忘掉（后面的用例不受影响）
        send(ic.get(), Key(FcitxKey_Delete, KeyState::Ctrl));
    }

    // 上屏以后的联想（Association，默认关）：没有词级模型时只有学到的搭配。你好 -> 中国 上屏一次，
    // 再打你好：候选框是联想（中国），上方提示「联想」，不画序号；数字、字母、空格照常，Tab 进联想行再选
    fresh(ic.get());
    type(ic.get(), "nihao<sp>zhongguo<sp>");
    {
        const auto associations = [&]() {
            std::vector<std::string> out = page(ic.get());
            const std::string aux = ic->inputPanel().auxUp().toString();
            return aux.find("联想") != std::string::npos ? out : std::vector<std::string>{};
        };
        auto *associationAddon = instance.addonManager().addon("wowtype");
        fresh(ic.get());
        type(ic.get(), "nihao<sp>");
        check(associations().empty() && page(ic.get()).empty(), "联想默认关：上屏你好以后什么都不出");
        setenv("WOWTYPE_ASSOCIATION", "1", 1);
        associationAddon->reloadConfig();
        const auto hasZhongguo = [](const std::vector<std::string> &items) {
            return std::find(items.begin(), items.end(), "中国") != items.end();
        };
        fresh(ic.get());
        type(ic.get(), "nihao<sp>");
        const auto shown = associations();
        auto list = ic->inputPanel().candidateList();
        check(ic->committed == "你好" && preedit(ic.get()).empty() && hasZhongguo(shown),
              "上屏以后出联想（学到的 你好 -> 中国）：" + join(page(ic.get())) + " / " +
                  ic->inputPanel().auxUp().toString());
        check(list && list->size() > 0 && list->label(0).toString().empty() && list->cursorIndex() < 0,
              "没进联想行：不画序号、不画光标");
        type(ic.get(), "1");
        check(ic->committed == "你好" && ic->passed == "1" && page(ic.get()).empty() &&
                  ic->inputPanel().auxUp().toString().empty(),
              "联想开着按数字：不选联想、交给应用，联想收起。上屏「" + ic->committed + "」交给应用「" + ic->passed +
                  "」候选 " + join(page(ic.get())));

        fresh(ic.get());
        type(ic.get(), "nihao<sp>");
        type(ic.get(), "<sp>");
        check(ic->committed == "你好" && ic->passed == " " && page(ic.get()).empty(),
              "联想开着按空格：交给应用，实际上屏「" + ic->committed + "」交给应用「" + ic->passed + "」");
        fresh(ic.get());
        type(ic.get(), "nihao<sp>shijie<sp>");
        check(ic->committed == "你好世界", "联想开着接着打拼音：照常，实际 " + ic->committed);
        fresh(ic.get());
        type(ic.get(), "nihao<sp>,");
        check(ic->committed == "你好，", "联想开着打标点：照常，实际 " + ic->committed);

        fresh(ic.get());
        type(ic.get(), "nihao<sp><tab>");
        auto *focused = dynamic_cast<CommonCandidateList *>(ic->inputPanel().candidateList().get());
        check(focused && focused->cursorIndex() == 0 && !focused->label(0).toString().empty() && ic->passed.empty(),
              "Tab 进联想行：光标在第一个、画序号，Tab 不交给应用");
        const auto row = associations();
        const auto at = std::find(row.begin(), row.end(), "中国");
        for (auto i = row.begin(); i != at && at != row.end(); ++i) {
            type(ic.get(), "<right>");
        }
        type(ic.get(), "<sp>");
        check(ic->committed == "你好中国", "进了联想行按空格上屏联想，实际 " + ic->committed);
        fresh(ic.get());
        type(ic.get(), "nihao<sp><tab><esc>");
        check(ic->committed == "你好" && page(ic.get()).empty(), "联想行里 Esc 退出");

        // 鼠标点联想（没按 Tab 也能点）
        fresh(ic.get());
        type(ic.get(), "nihao<sp>");
        const auto items = associations();
        const auto hit = std::find(items.begin(), items.end(), "中国");
        if (auto clicked = ic->inputPanel().candidateList(); clicked && hit != items.end()) {
            clicked->candidate(static_cast<int>(hit - items.begin())).select(ic.get());
        }
        check(ic->committed == "你好中国", "鼠标点联想上屏，实际 " + ic->committed);
        unsetenv("WOWTYPE_ASSOCIATION");
        associationAddon->reloadConfig();
    }
    fresh(ic.get());
    // 单音节不出拆开音节的句首词（dan -> 大）
    fresh(ic.get());
    type(ic.get(), "dan");
    {
        const auto dan = page(ic.get());
        bool split = false;
        for (const auto &t : dan) split = split || t == "大";
        check(!dan.empty() && !split, "dan 第一页没有 大：" + join(dan));
    }

    // 长句第一页不能全是只差最后一个字的整句，要有词和单字（截图里的问题）
    fresh(ic.get());
    type(ic.get(), "hengxianghouxuanci");
    {
        const auto heng = page(ic.get());
        int tailVariants = 0;
        bool single = false;
        for (const auto &t : heng) {
            if (t.rfind("横向候选", 0) == 0 && t.size() == std::string("横向候选词").size()) {
                ++tailVariants;
            }
            single = single || t == "横";
        }
        check(!heng.empty() && heng[0] == "横向候选词" && tailVariants == 1 && single,
              "hengxianghouxuanci 第一页：整句 + 词 + 单字：" + join(heng));
    }

    // 有的音节只打声母（省略韵母）：k yi -> 可以，yong z wen -> 用中文
    for (const auto &[keys, want] : {std::pair<const char *, const char *>{"kyi", "可以"},
                                     {"yongzwen", "用中文"}}) {
        fresh(ic.get());
        type(ic.get(), keys);
        const auto got = page(ic.get());
        check(!got.empty() && got[0] == want,
              std::string(keys) + " 第一个是 " + want + "：" + join(got));
    }

    // 长句先选开头的词
    fresh(ic.get());
    type(ic.get(), "nihaozhongguo");
    auto cands = page(ic.get());
    int prefix = -1;
    for (std::size_t i = 0; i < cands.size(); ++i) {
        if (cands[i] == "你好") {
            prefix = static_cast<int>(i);
        }
    }
    check(prefix >= 0, "nihaozhongguo 第一页有句首词 你好：" + join(cands));
    if (prefix >= 0) {
        type(ic.get(), std::string(1, static_cast<char>('1' + prefix)));
        check(ic->committed.empty(), "选句首词不上屏，实际 " + ic->committed);
        check(preedit(ic.get()) == "你好zhong'guo", "编辑区 = 已选 + 剩余拼音（分好音节），实际 " + preedit(ic.get()));
        // 退格先撤销选词（#49），剩余拼音不动；没有选词了才删字母
        type(ic.get(), "<bs>");
        check(preedit(ic.get()) == "ni'hao'zhong'guo", "退格先撤销选词，实际 " + preedit(ic.get()));
        type(ic.get(), "<bs>");
        check(preedit(ic.get()) == "ni'hao'zhong'gu", "没有选词了退格删字母，实际 " + preedit(ic.get()));
        type(ic.get(), "o");
        cands = page(ic.get());
        for (std::size_t i = 0; i < cands.size(); ++i) {
            if (cands[i] == "你好") {
                type(ic.get(), std::string(1, static_cast<char>('1' + i)));
                break;
            }
        }
        type(ic.get(), "<sp>");
        check(ic->committed == "你好中国", "选完开头再选剩下的，整句上屏，实际 " + ic->committed);
    }

    // 翻页后数字按当前页选
    fresh(ic.get());
    type(ic.get(), "shi");
    const auto first = page(ic.get());
    type(ic.get(), "<pgdn>");
    const auto second = page(ic.get());
    check(!second.empty() && second != first, "翻到第二页：" + join(second));
    if (!second.empty()) {
        type(ic.get(), "1");
        check(ic->committed == second[0], "第二页按 1 选第二页第一个，实际 " + ic->committed);
    }

    // 候选横排（和微信输入法一样）：下键展开成 6 列的面板，右键移动光标
    auto layout = [&]() {
        auto list = ic->inputPanel().candidateList();
        auto *common = list ? dynamic_cast<CommonCandidateList *>(list.get()) : nullptr;
        return common ? common->layoutHint() : CandidateLayoutHint::NotSet;
    };
    fresh(ic.get());
    type(ic.get(), "shi");
    check(layout() == CandidateLayoutHint::Horizontal, "候选横排");
    const auto firstPage = page(ic.get());
    type(ic.get(), "<down>");
    const auto grid = page(ic.get());
    if (std::getenv("WOWTYPE_HARNESS_SHOW")) {
        for (const auto &row : grid) {
            std::fprintf(stderr, "GRID|%s|\n", row.c_str());
        }
    }
    check(layout() == CandidateLayoutHint::Vertical && !grid.empty() && firstPage.size() >= 8 &&
              grid[0].rfind("\uFF11\u3010" + firstPage[0] + "\u3011", 0) == 0 &&
              grid[0].find(firstPage[5]) != std::string::npos &&
              grid[0].find(firstPage[6]) == std::string::npos,
          "下键展开：第一行 6 个、光标框住第一个：" + join(grid));
    type(ic.get(), "<right><right><sp>");
    check(firstPage.size() > 2 && ic->committed == firstPage[2],
          "展开后右移两格空格选第三个，实际 " + ic->committed);
    // 选过词后排序会变（学习、上文），每次按之前重新取当前这一页
    // （用 zhi：shi 的第七个是「十」后面跟的 🔟，选了会进表情面板的「最近用过」）
    fresh(ic.get());
    type(ic.get(), "zhi");
    auto now = page(ic.get());
    type(ic.get(), "<down><down><sp>");
    check(now.size() > 6 && ic->committed == now[6],
          "展开后下移一行空格选第七个，实际 " + ic->committed);
    fresh(ic.get());
    type(ic.get(), "zhi");
    now = page(ic.get());
    type(ic.get(), "<down><down>2");
    check(now.size() > 7 && ic->committed == now[7],
          "展开后数字选光标所在行，实际 " + ic->committed);
    fresh(ic.get());
    type(ic.get(), "shi<down><down><up><up>");
    // （前面选过词，排序会变，这里只看收起没有）
    check(layout() == CandidateLayoutHint::Horizontal && page(ic.get()).size() == firstPage.size(),
          "展开后在第一行按上键收起：" + join(page(ic.get())));
    fresh(ic.get());
    type(ic.get(), "shi<down><esc>");
    check(layout() == CandidateLayoutHint::Horizontal && preedit(ic.get()) == "shi",
          "展开后 Esc 只收起，不清空输入");
    type(ic.get(), "<down>j");
    check(layout() == CandidateLayoutHint::Horizontal && preedit(ic.get()) == "shi'j",
          "展开后接着打字：收起并照常输入，实际 " + preedit(ic.get()));
    // 展开后一直按下键走到第二屏：面板跟着翻到光标那一屏；收起后横排候选框也停在光标那一页
    auto common = [&]() -> CommonCandidateList * {
        auto list = ic->inputPanel().candidateList();
        return list ? dynamic_cast<CommonCandidateList *>(list.get()) : nullptr;
    };
    fresh(ic.get());
    type(ic.get(), "shi<down>");
    const int gridRows = common() ? common()->totalSize() : 0;
    check(gridRows > 7, "shi 展开后超过一屏（" + std::to_string(gridRows) + " 行）");
    if (gridRows > 7) {
        type(ic.get(), "<down><down><down><down><down><down><down>");
        const auto screen = page(ic.get());
        bool framed = false;
        for (const auto &row : screen) {
            framed = framed || row.find("\u3010") != std::string::npos;
        }
        check(common() && common()->cursorIndex() >= 0 && common()->currentPage() == 1 && framed,
              "展开后下移 7 行：面板翻到第二屏，看得到光标：" + join(screen));
        type(ic.get(), "<esc>");
        const auto shown = page(ic.get());
        check(layout() == CandidateLayoutHint::Horizontal && common() &&
                  common()->cursorIndex() >= 0,
              "第二屏收起后，横排候选框停在光标那一页：" + join(shown));
        if (common() && common()->cursorIndex() >= 0) {
            const std::string cur = shown[static_cast<std::size_t>(common()->cursorIndex())];
            type(ic.get(), "<sp>");
            check(ic->committed == cur, "收起后空格选光标处的候选，实际 " + ic->committed);
        }
    }

    // 空格选光标所在的候选
    fresh(ic.get());
    type(ic.get(), "shi<right>");
    const auto list = page(ic.get());
    type(ic.get(), "<sp>");
    check(list.size() > 1 && ic->committed == list[1], "右移光标后空格选第二个，实际 " + ic->committed);

    // 翻页和光标的细节（候选列表的页和光标各管各的，挪进会话前先钉住）
    fresh(ic.get());
    type(ic.get(), "shi<pgdn>");
    {
        const auto p2 = page(ic.get());
        type(ic.get(), "<sp>");
        check(!p2.empty() && ic->committed == p2[0], "翻页后空格选这一页第一个，实际 " + ic->committed);
    }
    fresh(ic.get());
    type(ic.get(), "shi");
    {
        const auto p1 = page(ic.get());
        for (std::size_t i = 0; i < p1.size(); ++i) {
            type(ic.get(), "<right>");
        }
        const auto p2 = page(ic.get());
        auto *list = common();
        check(list && p2 != p1 && list->cursorIndex() == 0 &&
                  list->globalCursorIndex() == static_cast<int>(p1.size()),
              "右键走过这一页最后一个：翻到下一页、光标在第一个");
        type(ic.get(), "<sp>");
        check(!p2.empty() && ic->committed == p2[0], "接着空格选下一页第一个，实际 " + ic->committed);
    }
    fresh(ic.get());
    type(ic.get(), "shi");
    {
        const auto p1 = page(ic.get());
        type(ic.get(), "<left>");
        auto *list = common();
        check(list && list->hasNext() && !list->hasPrev() && list->cursorIndex() == 0 &&
                  page(ic.get()) == p1,
              "第一个上按左键：停在第一个，不绕到最后一页");
        type(ic.get(), "<sp>");
        check(!p1.empty() && ic->committed == p1[0], "空格选第一个，实际 " + ic->committed);
    }
    fresh(ic.get());
    type(ic.get(), "shi");
    {
        const auto p1 = page(ic.get());
        if (auto *list = common()) {
            list->next(); // 候选框上的翻页按钮直接调列表
        }
        const auto p2 = page(ic.get());
        type(ic.get(), "1");
        check(!p2.empty() && p2 != p1 && ic->committed == p2[0],
              "点翻页按钮以后数字按新的一页选，实际 " + ic->committed);
    }
    fresh(ic.get());
    type(ic.get(), "shi");
    {
        // 展开面板翻一屏（36 个）再 Esc 收起：翻到光标那一页，光标看得见
        type(ic.get(), "<down>");
        send(ic.get(), Key(FcitxKey_Page_Down));
        type(ic.get(), "<esc>");
        auto *list = common();
        const auto shown = page(ic.get());
        check(list && list->globalCursorIndex() == 36 && list->cursorIndex() >= 0 &&
                  list->currentPage() == 36 / list->pageSize(),
              "展开面板翻屏后收起：停在光标那一页、光标看得见：" + join(shown));
        const std::string cur = list && list->cursorIndex() >= 0
                                    ? shown[static_cast<std::size_t>(list->cursorIndex())]
                                    : std::string();
        type(ic.get(), "<sp>");
        check(!cur.empty() && ic->committed == cur, "这时空格选光标处，实际 " + ic->committed);
    }
    fresh(ic.get());
    type(ic.get(), "shi<down>");
    send(ic.get(), Key(FcitxKey_Page_Down));
    type(ic.get(), "<esc>");
    {
        const auto p1 = page(ic.get());
        type(ic.get(), "2");
        check(p1.size() > 1 && ic->committed == p1[1], "收起后数字按当前页选，实际 " + ic->committed);
    }
    // 展开面板上点翻页按钮、滚滚轮（直接调列表的 next / prev）：会话的光标跟着到那一屏，
    // 看到的这一屏上框着的词就是空格选的，数字选的是光标那一行的
    /// 一行里【】框着的词；没有框是空的
    auto framedIn = [](const std::vector<std::string> &rows) {
        for (const auto &row : rows) {
            const auto open = row.find("\u3010");
            const auto close = row.find("\u3011");
            if (open != std::string::npos && close != std::string::npos && close > open) {
                return row.substr(open + 3, close - open - 3);
            }
        }
        return std::string();
    };
    /// 有光标的那一行里标着 label（１–６）的词
    auto labelledIn = [](const std::vector<std::string> &rows, const std::string &label) {
        for (const auto &row : rows) {
            auto at = row.find(label + "\u3000");
            if (row.find("\u3010") == std::string::npos || at == std::string::npos) {
                continue;
            }
            at += label.size() + 3;
            std::string text = row.substr(at, row.find("\u3000", at) - at);
            if (const auto pad = text.find("\u2002"); pad != std::string::npos) {
                text.resize(pad); // 补宽度的半角空格
            }
            return text;
        }
        return std::string();
    };
    fresh(ic.get());
    type(ic.get(), "shi<down>");
    if (auto *list = common(); list && list->hasNext()) {
        const auto screen1 = page(ic.get());
        list->next();
        list = common();
        const auto screen2 = page(ic.get());
        const std::string framed = framedIn(screen2);
        check(list && list->currentPage() == 1 && list->cursorIndex() == 0 && screen2 != screen1 &&
                  !framed.empty(),
              "展开面板点下一屏：光标跟到第二屏第一个：" + join(screen2));
        type(ic.get(), "<sp>");
        check(!framed.empty() && ic->committed == framed,
              "展开面板点下一屏后空格选这一屏框着的（" + framed + "），实际 " + ic->committed);
        fresh(ic.get());
        type(ic.get(), "shi<down>");
        if ((list = common())) {
            list->next();
        }
        const std::string second = labelledIn(page(ic.get()), "\uFF12");
        type(ic.get(), "2");
        check(!second.empty() && ic->committed == second,
              "展开面板点下一屏后数字选这一屏的（" + second + "），实际 " + ic->committed);
        fresh(ic.get());
        type(ic.get(), "shi<down>");
        if ((list = common())) {
            list->next();
        }
        if ((list = common())) {
            list->prev();
        }
        list = common();
        const std::string back = framedIn(page(ic.get()));
        check(list && list->currentPage() == 0 && !back.empty(), "展开面板点上一屏：回到第一屏：" + back);
        type(ic.get(), "<sp>");
        check(!back.empty() && ic->committed == back, "回到第一屏后空格选框着的，实际 " + ic->committed);
    } else {
        std::printf("skip 展开面板点翻页按钮（这个词库里 shi 的候选不到两屏）\n");
    }
    fresh(ic.get());
    type(ic.get(), "shi");
    {
        const auto p1 = page(ic.get());
        type(ic.get(), "<tab>");
        auto *list = common();
        check(list && page(ic.get()) == p1 && list->globalCursorIndex() == 1,
              "Tab（fcitx5 全局的下一个候选）移光标，实际光标 " +
                  std::to_string(list ? list->globalCursorIndex() : -9));
        type(ic.get(), "<stab>");
        check(list && common()->globalCursorIndex() == 0, "Shift+Tab 移回来");
    }
    fresh(ic.get());
    type(ic.get(), "v1-2");
    check(ic->committed.empty() && preedit(ic.get()) == "v1-2", "V 模式里 - 是减号不翻页：" + preedit(ic.get()));
    type(ic.get(), "=");
    check(ic->committed == "-1", "V 模式 = 上屏结果，实际 " + ic->committed);
    fresh(ic.get());
    type(ic.get(), "shi");
    send(ic.get(), Key(FcitxKey_2, KeyState::NumLock));
    check(!ic->committed.empty(), "带 NumLock 的数字不当选词键，实际上屏 " + ic->committed +
                                      " 交给应用 " + ic->passed);
    fresh(ic.get());
    type(ic.get(), "shi");
    send(ic.get(), Key(FcitxKey_KP_3));
    {
        const auto p1 = page(ic.get());
        check(ic->committed.size() > 0, "小键盘数字选词，实际 " + ic->committed);
    }
    auto horizontalList = [&]() {
        auto *list = common();
        return list && list->layoutHint() == CandidateLayoutHint::Horizontal;
    };
    fresh(ic.get());
    type(ic.get(), "shi");
    {
        const auto p1 = page(ic.get());
        type(ic.get(), "<down><tab>");
        auto *list = common();
        check(horizontalList() && page(ic.get()) == p1 && list && list->globalCursorIndex() == 1,
              "展开后按 Tab：收起，再按全局的下一个候选移光标");
    }
    fresh(ic.get());
    type(ic.get(), "shi");
    {
        const auto p1 = page(ic.get());
        type(ic.get(), "<down>");
        check(send(ic.get(), Key(FcitxKey_Home)) && horizontalList() && page(ic.get()) == p1 &&
                  ic->committed.empty(),
              "展开后按 Home：收起、吃掉");
    }
    fresh(ic.get());
    type(ic.get(), "shi");
    {
        const auto p1 = page(ic.get());
        type(ic.get(), "<down><right>,");
        check(p1.size() > 1 && ic->committed == p1[1] + "，",
              "展开后右移再按逗号：收起，上屏光标处的词和逗号，实际 " + ic->committed);
    }
    fresh(ic.get());
    type(ic.get(), "shi");
    {
        const auto p1 = page(ic.get());
        type(ic.get(), "<down>");
        KeyEvent press(ic.get(), Key(FcitxKey_Shift_R), false);
        ic->keyEvent(press);
        check(horizontalList() && page(ic.get()) == p1 && ic->committed.empty(),
              "展开后按下 Shift：收起，不上屏");
    }
    fresh(ic.get());
    type(ic.get(), "shi");
    {
        const auto p1 = page(ic.get());
        send(ic.get(), Key(FcitxKey_Right, KeyState::Shift));
        auto *list = common();
        check(list && list->globalCursorIndex() == 1, "Shift+右键也移光标");
        send(ic.get(), Key(FcitxKey_space, KeyState::Shift));
        check(p1.size() > 1 && ic->committed == p1[1], "Shift+空格选光标处的词，实际 " + ic->committed);
    }
    fresh(ic.get());
    type(ic.get(), "shi");
    {
        const auto p1 = page(ic.get());
        if (auto *list = common()) {
            list->nextCandidate(); // 候选框上滚轮、按钮直接调列表
        }
        type(ic.get(), "<sp>");
        check(p1.size() > 1 && ic->committed == p1[1], "列表 nextCandidate 后空格选第二个，实际 " + ic->committed);
    }
    fresh(ic.get());
    type(ic.get(), "shi");
    {
        const auto p1 = page(ic.get());
        if (auto *list = common()) {
            list->prevCandidate();
        }
        auto *list = common();
        check(list && list->cursorIndex() == 0 && page(ic.get()) == p1,
              "列表 prevCandidate 在第一个上停住");
        type(ic.get(), "<sp>");
        check(!p1.empty() && ic->committed == p1[0], "接着空格选第一个，实际 " + ic->committed);
    }
    fresh(ic.get());
    type(ic.get(), "shi");
    {
        const auto p1 = page(ic.get());
        type(ic.get(), "<pgdn>");
        if (auto *list = common()) {
            list->prev();
        }
        auto *list = common();
        check(page(ic.get()) == p1 && list && list->cursorIndex() == 0, "列表 prev 翻回第一页、光标在第一个");
        type(ic.get(), "2");
        check(p1.size() > 1 && ic->committed == p1[1], "接着数字按第一页选，实际 " + ic->committed);
    }
    fresh(ic.get());
    type(ic.get(), "shi<pgdn>");
    {
        const auto p2 = page(ic.get());
        if (auto list = ic->inputPanel().candidateList(); list && list->size() > 1) {
            list->candidate(1).select(ic.get()); // 鼠标点候选
        }
        check(p2.size() > 1 && ic->committed == p2[1], "翻页后点第二个候选，实际 " + ic->committed);
    }

    fresh(ic.get());
    type(ic.get(), "shi");
    {
        // 一直 PgDn 翻到最后一页：停在最后一页，光标在这页开头，空格选它
        auto *list = common();
        int guard = 0;
        while (list && list->hasNext() && guard++ < 100) {
            type(ic.get(), "<pgdn>");
            list = common();
        }
        const auto last = page(ic.get());
        check(list && !list->hasNext() && list->totalPages() > 1 &&
                  list->currentPage() == list->totalPages() - 1 && list->cursorIndex() == 0,
              "PgDn 翻到最后一页");
        type(ic.get(), "<pgdn>");
        list = common();
        check(list && list->currentPage() == list->totalPages() - 1, "最后一页再按 PgDn 不动");
        type(ic.get(), "<sp>");
        check(!last.empty() && ic->committed == last[0], "最后一页空格选第一个，实际 " + ic->committed);
    }
    fresh(ic.get());
    type(ic.get(), "shi");
    {
        // 翻页按钮（直接调列表的 next）翻到最后一页
        auto *list = common();
        int guard = 0;
        while (list && list->currentPage() + 2 < list->totalPages() && guard++ < 100) {
            type(ic.get(), "<pgdn>");
            list = common();
        }
        if (list) {
            list->next();
        }
        list = common();
        check(list && !list->hasNext() && list->currentPage() == list->totalPages() - 1 &&
                  list->usedNextBefore(),
              "列表 next 翻到最后一页");
        // 最后一页有几个看词库（新词库下 shi 的最后一页可能只剩一个）：有第二个就按 2，否则按 1
        const auto last = page(ic.get());
        const std::size_t pick = last.size() > 1 ? 2 : 1;
        type(ic.get(), std::to_string(pick));
        check(!last.empty() && ic->committed == last[pick - 1],
              "接着数字按最后一页选，实际 " + ic->committed);
    }
    fresh(ic.get());
    type(ic.get(), "shi");
    {
        // 光标右移跨到下一页：候选框跟着翻页，光标在新一页的第一个
        auto *list = common();
        const int size = list ? list->size() : 0;
        for (int i = 0; i < size; ++i) {
            type(ic.get(), "<right>");
        }
        list = common();
        const auto p2 = page(ic.get());
        check(list && list->currentPage() == 1 && list->cursorIndex() == 0,
              "右键跨页");
        type(ic.get(), "<sp>");
        check(!p2.empty() && ic->committed == p2[0], "跨页后空格选新一页第一个，实际 " + ic->committed);
    }

    // 退格删到空，编辑区关闭
    fresh(ic.get());
    type(ic.get(), "ni<bs><bs>");
    check(preedit(ic.get()).empty() && page(ic.get()).empty(), "退格删光后编辑区关闭");
    type(ic.get(), ",");
    check(ic->committed == "，", "空编辑区按逗号出中文逗号，实际 " + ic->committed);

    // 空编辑区时数字直接交给应用
    fresh(ic.get());
    type(ic.get(), "1");
    check(ic->committed.empty() && ic->passed == "1", "空编辑区数字交给应用");

    // 打到一半切换输入法：原始字母上屏
    fresh(ic.get());
    type(ic.get(), "nihao");
    instance.setCurrentInputMethod(ic.get(), "testim", true);
    check(ic->committed == "nihao", "切换输入法时打了一半的字母上屏，实际 " + ic->committed);
    instance.setCurrentInputMethod(ic.get(), "wowtype", true);

    // 失去焦点：不往别的窗口上屏，编辑区清空
    fresh(ic.get());
    type(ic.get(), "nihao");
    ic->focusOut();
    ic->focusIn();
    check(ic->committed.empty() && preedit(ic.get()).empty(), "失去焦点不上屏、编辑区清空，实际 " + ic->committed);

    // 编辑区画在输入框里时（应用支持 preedit）：失去焦点、应用重置输入框，GTK / Qt 的输入模块会把
    // 编辑区里没标 DontCommit 的字上屏，不支持的（XIM）由 fcitx5 代劳。WowType 的编辑区整段标了
    // DontCommit：文档里不留「ni'hao」、选了一半的「你好zhong'guo」、五笔码
    ic->setCapabilityFlags(CapabilityFlag::Preedit);
    {
        const auto client = [&]() { return ic->inputPanel().clientPreedit(); };
        fresh(ic.get());
        type(ic.get(), "nihao");
        check(client().toString() == "ni'hao" && client().toStringForCommit().empty(),
              "输入框里的编辑区是 ni'hao，失去焦点时没有要上屏的：[" + client().toStringForCommit() + "]");
        ic->focusOut();
        ic->focusIn();
        check(ic->committed.empty() && client().toString().empty(),
              "失去焦点：fcitx5 替应用上屏的也是空的，实际 " + ic->committed);
        fresh(ic.get());
        type(ic.get(), "nihaozhongguo");
        const auto cands = page(ic.get());
        const auto at = std::find(cands.begin(), cands.end(), "你好");
        if (at != cands.end() && at - cands.begin() < 9) {
            type(ic.get(), std::to_string(at - cands.begin() + 1));
        }
        check(client().toString() == "你好zhong'guo" && client().toStringForCommit().empty(),
              "选了一半的句子也不会被应用上屏：" + client().toString());
        ic->reset();
        check(ic->committed.empty() && client().toString().empty() && preedit(ic.get()).empty(),
              "应用重置输入框（点了别处）：丢掉，实际 " + ic->committed);
        // GTK 4.14 的输入框全选（Ctrl+A）时会重置输入法：Ctrl+A 交给应用、编辑区留着，应用一重置就丢掉
        fresh(ic.get());
        type(ic.get(), "nihao");
        check(!send(ic.get(), Key(FcitxKey_a, KeyState::Ctrl)) && client().toString() == "ni'hao",
              "打字途中 Ctrl+A 交给应用，编辑区留着：" + client().toString());
        ic->reset();
        check(ic->committed.empty() && client().toString().empty(),
              "应用跟着重置输入框：丢掉，不留 ni'hao，实际 " + ic->committed);
        fresh(ic.get());
    }
    ic->setCapabilityFlags(CapabilityFlags{});

    // 上文跟着文档走：「不」后面 ma 的候选和没有上文时不一样；「不」删掉了（退格、全选再删、点到别处）
    // 再打 ma 要回到没有上文时的样子，不能还当「不」在前面。看整页的顺序，不看哪个词排第一
    // （词库、语言模型不同，首选不一样：雾凇是「骂」，万象还是「吗」）
    {
        const auto ma = [&]() {
            type(ic.get(), "ma");
            const auto cands = join(page(ic.get()));
            type(ic.get(), "<esc>");
            return cands;
        };
        fresh(ic.get());
        type(ic.get(), "<bs>");
        const std::string alone = ma();
        type(ic.get(), "bu<sp>");
        const std::string afterBu = ma();
        if (ic->committed != "不" || afterBu == alone) {
            // 这个词库、语言模型里「不」不改 ma 的排序：没法从候选上看出上文
            std::printf("skip 上文跟着文档走（「不」不改 ma 的排序：%s）\n", alone.c_str());
        } else {
            check(true, "「不」后面 ma 的候选变了：" + alone + "/ " + afterBu);
            type(ic.get(), "<bs>");
            check(ma() == alone, "退格删掉「不」以后回到没有上文的样子");
            type(ic.get(), "bu<sp>");
            send(ic.get(), Key(FcitxKey_a, KeyState::Ctrl));
            type(ic.get(), "<del>");
            check(ma() == alone, "全选再 Delete 以后回到没有上文的样子");
            type(ic.get(), "bu<sp>");
            ic->focusOut();
            ic->focusIn();
            check(ma() == alone, "失去焦点再回来以后回到没有上文的样子");
            // 读得到周围文字：拿光标前的字核对（在应用里用鼠标改过，会话没看到键）
            ic->setCapabilityFlags(CapabilityFlag::SurroundingText);
            type(ic.get(), "bu<sp>");
            ic->surroundingText().setText("不", 1, 1);
            check(ma() == afterBu, "光标前还是「不」：照样用它");
            ic->surroundingText().setText("你好", 2, 2);
            check(ma() != afterBu, "光标前换成了别的字：不再当「不」在前面");
            type(ic.get(), "bu<sp>");
            ic->surroundingText().setText("", 0, 0);
            check(ma() == alone, "文档清空了：回到没有上文的样子");
            ic->surroundingText().invalidate();
            ic->setCapabilityFlags(CapabilityFlags{});
        }
        fresh(ic.get());
    }

    // 连续上屏很多字，上下文按 UTF-8 截断不出错
    fresh(ic.get());
    for (int i = 0; i < 30; ++i) {
        type(ic.get(), "zhongguo<sp>");
    }
    type(ic.get(), "renmin<sp>");
    check(ic->committed.size() > 30 * 6, "连续上屏 31 次没出错");

    // 编辑区给拼音分音节，回车仍上屏原始字母
    fresh(ic.get());
    type(ic.get(), "hengxiang");
    check(preedit(ic.get()) == "heng'xiang", "编辑区分音节，实际 " + preedit(ic.get()));
    type(ic.get(), "<cr>");
    check(ic->committed == "hengxiang", "回车上屏原始字母（不带隔音符），实际 " + ic->committed);
    fresh(ic.get());
    type(ic.get(), "zhongg");
    check(preedit(ic.get()) == "zhong'g", "打了一半也分，实际 " + preedit(ic.get()));

    // 打拼音时按语音热键（右 Alt）：不抢，编辑区不动
    fresh(ic.get());
    type(ic.get(), "ni");
    const bool tookAlt = send(ic.get(), Key(FcitxKey_Alt_R));
    check(!tookAlt && preedit(ic.get()) == "ni", "打拼音时右 Alt 交给应用、编辑区不动");

    // / 不再进符号面板：直接交给应用，后面的拼音照常打（issue：/jixu 卡在编辑区）
    fresh(ic.get());
    type(ic.get(), "/jixu<sp>");
    check(ic->passed == "/" && ic->committed == "继续",
          "/ 交给应用、jixu 照常打，交给应用 " + ic->passed + " 上屏 " + ic->committed);
    fresh(ic.get());
    type(ic.get(), "nihao/");
    check(ic->committed == "你好/" && ic->passed.empty(),
          "打字途中按 /：先上屏再出 /，实际 " + ic->committed);
    fresh(ic.get());
    type(ic.get(), "nihao+");
    check(ic->committed == "你好+", "打字途中按 +：先上屏再出 +，实际 " + ic->committed);

    // 打字时推荐 emoji：插在第三个候选
    fresh(ic.get());
    type(ic.get(), "kaixin");
    {
        const auto kaixin = page(ic.get());
        check(kaixin.size() > 2 && kaixin[0] == "开心" && kaixin[2] == "😊",
              "kaixin 第三个是 😊：" + join(kaixin));
    }
    type(ic.get(), "3");
    check(ic->committed == "😊", "选 emoji 只上屏 emoji，实际 " + ic->committed);
    fresh(ic.get());
    type(ic.get(), "jintianhaokaixin");
    {
        const auto sentence = page(ic.get());
        int at = -1;
        for (std::size_t i = 0; i < sentence.size(); ++i) {
            if (sentence[i] == "开心😊") at = static_cast<int>(i);
        }
        check(at >= 0, "句尾是开心时推荐「开心😊」：" + join(sentence));
        if (at >= 0) {
            type(ic.get(), std::string(1, static_cast<char>('1' + at)));
            check(ic->committed == sentence[0] + "😊", "句尾推荐：整句 + emoji，实际 " + ic->committed);
        }
    }
    fresh(ic.get());
    type(ic.get(), "shi");
    {
        bool emoji = false;
        for (const auto &t : page(ic.get())) emoji = emoji || t == "✅";
        check(!emoji, "单字不推荐 emoji（数字后面的按键 emoji 除外）：" + join(page(ic.get())));
    }

    // 表情面板：Super+. 打开，空搜索列全部，空格选第一个，Esc 关闭
    const Key emojiKey(FcitxKey_period, KeyState::Super);
    fresh(ic.get());
    check(send(ic.get(), emojiKey), "Super+. 被输入法接住");
    check(ic->inputPanel().auxUp().toString().find("表情") != std::string::npos &&
              !page(ic.get()).empty(),
          "打开表情面板：" + ic->inputPanel().auxUp().toString());
    // 上面刚选过 😊：最近用过的排最前。第二个是什么看前面的用例选过什么
    // （词库不同，前面翻页、展开时可能选到 🔟 这类按键 emoji；什么都没选过就是全部 emoji 的 😀）
    const std::string recentGrid = page(ic.get()).empty() ? std::string() : page(ic.get())[0];
    check(recentGrid.find("【😊】") != std::string::npos && recentGrid.find("【😊】") < recentGrid.find("２"),
          "最近用过的排最前：" + recentGrid);
    std::string recentSecond;
    if (auto at = recentGrid.find("２　"); at != std::string::npos) {
        at += std::string("２　").size();
        recentSecond = recentGrid.substr(at, recentGrid.find("　", at) - at);
    }
    type(ic.get(), "<right><sp>");
    check(!recentSecond.empty() && ic->committed == recentSecond,
          "右键移到第二个（" + recentSecond + "）再选，实际 " + ic->committed);
    fresh(ic.get());
    send(ic.get(), emojiKey);
    type(ic.get(), "<sp>");
    check(ic->committed == recentSecond, "空格选第一个（刚用过的 " + recentSecond + "），实际 " + ic->committed);
    // 搜拼音、英文和符号名
    fresh(ic.get());
    send(ic.get(), emojiKey);
    type(ic.get(), "xiao");
    check(join(page(ic.get())).find("😂") != std::string::npos, "搜 xiao 有 😂：" + join(page(ic.get())));
    type(ic.get(), "<cr>");
    check(!ic->committed.empty() && preedit(ic.get()).empty(), "回车选中并关闭面板，实际 " + ic->committed);
    fresh(ic.get());
    send(ic.get(), emojiKey);
    type(ic.get(), "pizza<sp>");
    check(ic->committed == "🍕", "搜英文 pizza -> 🍕，实际 " + ic->committed);
    fresh(ic.get());
    send(ic.get(), emojiKey);
    type(ic.get(), "youjiantou<sp>");
    check(ic->committed == "→", "符号也能搜：youjiantou -> →，实际 " + ic->committed);
    // 打了一半的拼音带进面板当搜索词
    fresh(ic.get());
    type(ic.get(), "gou");
    send(ic.get(), emojiKey);
    check(ic->inputPanel().auxUp().toString().find("gou") != std::string::npos &&
              join(page(ic.get())).find("🐶") != std::string::npos,
          "gou + Super+. 搜狗：" + join(page(ic.get())));
    type(ic.get(), "<esc>");
    check(ic->committed.empty() && preedit(ic.get()).empty() && page(ic.get()).empty(),
          "Esc 关闭面板，不上屏");
    // 再按一次快捷键也关闭；退格删空后再退格关闭
    fresh(ic.get());
    send(ic.get(), emojiKey);
    send(ic.get(), emojiKey);
    check(page(ic.get()).empty() && ic->committed.empty(), "再按一次快捷键关闭");
    send(ic.get(), emojiKey);
    type(ic.get(), "a<bs><bs>");
    check(page(ic.get()).empty() && ic->committed.empty() && ic->passed.empty(), "退格删空再退格关闭");
    // 面板里退格删搜索词一个字；删空了面板还开着（列全部），再退格才关闭
    fresh(ic.get());
    send(ic.get(), emojiKey);
    type(ic.get(), "xiaox<bs>");
    check(preedit(ic.get()) == "xiao" && join(page(ic.get())).find("😂") != std::string::npos,
          "面板里退格删一个字：xiaox 退格 = xiao，实际 " + preedit(ic.get()));
    type(ic.get(), "<bs><bs><bs><bs>");
    check(preedit(ic.get()).empty() && !page(ic.get()).empty() &&
              ic->inputPanel().auxUp().toString().find("表情") != std::string::npos,
          "搜索词删空面板还开着：" + ic->inputPanel().auxUp().toString());
    type(ic.get(), "<bs>");
    check(page(ic.get()).empty() && ic->committed.empty() && ic->passed.empty(),
          "再退格关闭面板");

    // 数字字后面跟按键 emoji：ba -> 吧 八 8️⃣ 把
    // （放在表情面板后面：选过的 8️⃣ 会进「最近用过」）
    fresh(ic.get());
    type(ic.get(), "ba");
    {
        const auto ba = page(ic.get());
        int at = -1;
        for (std::size_t i = 0; i < ba.size(); ++i) {
            if (ba[i] == "8️⃣") at = static_cast<int>(i);
        }
        check(at > 0 && ba[at - 1] == "八", "ba：八 后面是 8️⃣：" + join(ba));
        if (at >= 0) {
            type(ic.get(), std::string(1, static_cast<char>('1' + at)));
            check(ic->committed == "8️⃣", "选 8️⃣ 只上屏 8️⃣，实际 " + ic->committed);
        }
    }
    fresh(ic.get());
    type(ic.get(), "shi");
    {
        // 词库不同（还有前面学到的）时「十」排第几不一定：在第一页上的话 🔟 紧跟在它后面
        // （「十」是第一页最后一个时 🔟 在第二页开头），不在第一页就不出 🔟。看全部候选
        auto list = ic->inputPanel().candidateList();
        auto *all = list ? dynamic_cast<CommonCandidateList *>(list.get()) : nullptr;
        int ten = -1, keycap = -1;
        std::vector<std::string> shi;
        for (int i = 0; all && i < all->totalSize(); ++i) {
            shi.push_back(all->candidateFromAll(i).text().toString());
            ten = ten < 0 && shi.back() == "十" ? i : ten;
            keycap = keycap < 0 && shi.back() == "🔟" ? i : keycap;
        }
        const bool firstPage = all && ten >= 0 && ten < all->pageSize();
        shi.resize(std::min<std::size_t>(shi.size(), 12));
        check(firstPage ? keycap == ten + 1 : keycap < 0, "shi：十 后面是 🔟：" + join(shi));
    }
    fresh(ic.get());
    type(ic.get(), "bage");
    {
        bool keycap = false;
        for (const auto &t : page(ic.get())) keycap = keycap || t == "8️⃣";
        check(!keycap, "bage：拼音没打完的「八」不跟 8️⃣：" + join(page(ic.get())));
    }

    // 设置：改配置文件和自定义词，reloadConfig 后立刻生效（设置界面走的就是这条路）
    fresh(ic.get());
    const std::string configDir = std::string(std::getenv("XDG_CONFIG_HOME")) + "/fcitx5/conf";
    const std::string customFile = std::string(std::getenv("XDG_DATA_HOME")) + "/wowtype/custom.tsv";
    std::filesystem::create_directories(configDir);
    std::filesystem::create_directories(std::filesystem::path(customFile).parent_path());
    auto *addon = instance.addonManager().addon("wowtype");
    check(addon && addon->getConfig(), "插件有配置项");
    {
        std::ofstream(configDir + "/wowtype.conf")
            << "CandidateLayout=Vertical\nPageSize=5\nVoice=False\nEmojiSuggest=False\n"
               "ClipboardHistory=True\n";
        std::ofstream(customFile) << "# 测试\nni hao\t妮好\nwo de you xiang\t我的邮箱\n";
    }
    addon->reloadConfig();
    type(ic.get(), "nihao");
    auto panelList = ic->inputPanel().candidateList();
    check(panelList && panelList->layoutHint() == CandidateLayoutHint::Vertical, "设置竖排后候选竖排");
    check(page(ic.get()).size() == 5, "每页 5 个：" + join(page(ic.get())));
    check(!page(ic.get()).empty() && page(ic.get())[0] == "妮好",
          "自定义词排第一：" + join(page(ic.get())));
    // 竖排时下键移动光标（不翻页）
    const auto vertical = page(ic.get());
    type(ic.get(), "<down><sp>");
    check(vertical.size() > 1 && ic->committed == vertical[1],
          "竖排下键选第二个，实际 " + ic->committed);
    fresh(ic.get());
    type(ic.get(), "shi");
    {
        const auto v1 = page(ic.get());
        type(ic.get(), "<right>");
        const auto v2 = page(ic.get());
        check(!v2.empty() && v2 != v1, "竖排右键翻页：" + join(v2));
        type(ic.get(), "<left>");
        check(page(ic.get()) == v1, "竖排左键翻回来");
        type(ic.get(), "<up>");
        auto list = ic->inputPanel().candidateList();
        check(list && list->cursorIndex() == 0 && page(ic.get()) == v1,
              "竖排第一个上按上键：停在第一个，不绕到最后一个");
        type(ic.get(), "<sp>");
        check(!v1.empty() && ic->committed == v1[0], "空格选第一个，实际 " + ic->committed);
    }
    fresh(ic.get());
    check(!send(ic.get(), Key(FcitxKey_Alt_R)), "关掉语音后右 Alt 交给应用");
    type(ic.get(), "wdyx<sp>");
    check(ic->committed == "我的邮箱", "自定义词也能简拼：wdyx -> " + ic->committed);
    fresh(ic.get());
    type(ic.get(), "kaixin");
    check(join(page(ic.get())).find("😊") == std::string::npos, "关掉 emoji 推荐后没有 😊：" + join(page(ic.get())));

    // V 模式工具栏：v + 空格打开，菜单里选剪贴板、常用语、符号、表情
    fresh(ic.get());
    type(ic.get(), "v<sp>");
    check(page(ic.get()).size() == 4 && page(ic.get())[0] == "剪贴板" && ic->committed.empty(),
          "v + 空格打开工具栏：" + join(page(ic.get())));
    type(ic.get(), "a");
    check(ic->passed.empty() && page(ic.get()).size() == 4, "工具栏里别的键吃掉、不收起");
    type(ic.get(), "2");
    check(page(ic.get()).size() == 2 && page(ic.get())[0] == "ni hao　妮好" &&
              page(ic.get())[1] == "wo de you xiang　我的邮箱",
          "常用语按文件顺序：" + join(page(ic.get())));
    type(ic.get(), "2");
    check(ic->committed == "我的邮箱" && page(ic.get()).empty(), "数字键选常用语：" + ic->committed);
    if (std::getenv("WOWTYPE_HARNESS_REAL_CLIPBOARD")) {
        // 系统装的 clipboard 插件（没有显示器，历史是空的）：只确认调用它不出错
        fresh(ic.get());
        type(ic.get(), "v<sp>1");
        check(ic->inputPanel().auxUp().toString().find("剪贴板") != std::string::npos,
              "真的 clipboard 插件：打开剪贴板不出错：" + ic->inputPanel().auxUp().toString());
        type(ic.get(), "<esc>");
    } else {
    // 剪贴板：插件从 fcitx5 的 clipboard 插件取最新一条记下来，最新的在前；
    // 换行显示成 ⏎、上屏时是真的换行
    fresh(ic.get());
    type(ic.get(), "v<sp>1");
    check(ic->inputPanel().auxUp().toString().find("还没有记录") != std::string::npos,
          "空剪贴板提示：" + ic->inputPanel().auxUp().toString());
    type(ic.get(), "<cr>");
    check(ic->inputPanel().auxUp().empty() && ic->committed.empty(), "空列表回车关闭");
    setClipboard("第一条");
    type(ic.get(), "v<sp>1");
    check(page(ic.get()).size() == 1 && page(ic.get())[0] == "第一条",
          "打开剪贴板时记下最新一条：" + join(page(ic.get())));
    fresh(ic.get());
    setClipboard("line1\nline2");
    type(ic.get(), "v<sp>1");
    check(page(ic.get()).size() == 2 && page(ic.get())[0] == "line1\u23CEline2",
          "剪贴板历史最新的在前：" + join(page(ic.get())));
    type(ic.get(), "<down><sp>");
    check(ic->committed == "第一条", "下键再空格选第二条：" + ic->committed);
    fresh(ic.get());
    type(ic.get(), "v<sp>1<cr>");
    check(ic->committed == "line1\nline2", "回车选第一条，换行原样：" + ic->committed);
    }
    // 退格返回菜单，菜单里再退格关闭
    fresh(ic.get());
    type(ic.get(), "v<sp>1<bs>");
    check(page(ic.get()).size() == 4, "退格回到菜单：" + join(page(ic.get())));
    type(ic.get(), "<bs>");
    check(page(ic.get()).empty() && ic->committed.empty() && ic->passed.empty(), "菜单里退格关闭");
    // 组合键（Ctrl+C）收起工具栏，交给应用
    type(ic.get(), "v<sp>");
    check(!send(ic.get(), Key(FcitxKey_c, KeyState::Ctrl)) && page(ic.get()).empty(),
          "Ctrl+C 收起工具栏、交给应用");
    // 符号：列全部内置符号，空格选第一个
    fresh(ic.get());
    type(ic.get(), "v<sp>3");
    check(ic->inputPanel().auxUp().toString().find("符号") != std::string::npos &&
              !page(ic.get()).empty(),
          "工具栏打开符号面板：" + ic->inputPanel().auxUp().toString());
    type(ic.get(), "<sp>");
    check(ic->committed == "，", "符号面板空格选第一个（，）：" + ic->committed);
    fresh(ic.get());
    type(ic.get(), "v<sp>4");
    check(ic->inputPanel().auxUp().toString().find("表情") != std::string::npos,
          "工具栏打开表情面板：" + ic->inputPanel().auxUp().toString());
    fresh(ic.get());
    // vim 照常打字，v1+2 照常算
    type(ic.get(), "vim");
    check(preedit(ic.get()) != "" && ic->inputPanel().auxUp().empty(), "vim 不打开工具栏：" + preedit(ic.get()));
    fresh(ic.get());
    type(ic.get(), "v1+2<sp>");
    check(ic->committed == "3", "v1+2 空格仍上屏结果：" + ic->committed);
    fresh(ic.get());
    type(ic.get(), "v100.5<sp>");
    check(ic->committed == "壹佰元伍角", "v 后面只打一个数：空格上屏大写金额：" + ic->committed);
    fresh(ic.get());

    // 符号面板（和表情面板、展开面板一样是 6 列的网格）点翻页按钮、滚滚轮：光标跟着到那一屏，
    // 屏幕上框着的就是空格选的、标着 ２ 的就是按 2 选的（以前只是 fcitx5 自己换了一屏，选的还是第一屏的）
    fresh(ic.get());
    type(ic.get(), "v<sp>3");
    {
        auto *list = common();
        check(list && list->hasNext() && list->totalPages() == 2, "符号面板有两屏");
        const auto screen1 = page(ic.get());
        if (list) {
            list->next(); // 候选框上的翻页按钮、滚轮直接调列表
        }
        list = common();
        const auto screen2 = page(ic.get());
        const std::string framed = framedIn(screen2);
        check(list && list->currentPage() == 1 && list->cursorIndex() == 0 && !list->hasNext() &&
                  screen2 != screen1 && !framed.empty(),
              "符号面板点下一屏：光标跟到第二屏：" + join(screen2));
        type(ic.get(), "<sp>");
        check(!framed.empty() && ic->committed == framed,
              "符号面板点下一屏后空格选这一屏框着的（" + framed + "），实际 " + ic->committed);
    }
    // 表情面板（不止三屏）：连着翻、翻回来、滚轮移光标、直接跳到某一屏
    fresh(ic.get());
    type(ic.get(), "v<sp>4");
    {
        if (auto *list = common()) {
            list->next();
        }
        if (auto *list = common()) {
            list->next();
        }
        auto *list = common();
        const std::string third = labelledIn(page(ic.get()), "\uFF13");
        check(list && list->currentPage() == 2 && !third.empty(), "表情面板连点两次下一屏：到第三屏");
        type(ic.get(), "3");
        check(!third.empty() && ic->committed == third,
              "表情面板第三屏按 3 选这一屏标着 ３ 的（" + third + "），实际 " + ic->committed);
    }
    fresh(ic.get());
    type(ic.get(), "v<sp>4");
    {
        if (auto *list = common()) {
            list->next();
        }
        if (auto *list = common()) {
            list->next();
        }
        if (auto *list = common()) {
            list->prev();
        }
        auto *list = common();
        const std::string framed = framedIn(page(ic.get()));
        check(list && list->currentPage() == 1 && !framed.empty(), "表情面板点上一屏：回到第二屏");
        if (list) {
            list->nextCandidate(); // 滚轮移到下一行
        }
        list = common();
        const std::string below = framedIn(page(ic.get()));
        check(list && list->cursorIndex() == 1 && !below.empty() && below != framed,
              "表情面板列表 nextCandidate：光标到下一行：" + below);
        type(ic.get(), "<cr>");
        check(!below.empty() && ic->committed == below, "接着回车选框着的，实际 " + ic->committed);
    }
    fresh(ic.get());
    type(ic.get(), "v<sp>4");
    {
        if (auto *list = common()) {
            list->setPage(2); // 直接跳到第三屏也是一屏一屏翻会话
        }
        auto *list = common();
        const std::string framed = framedIn(page(ic.get()));
        check(list && list->currentPage() == 2 && !framed.empty(), "表情面板 setPage(2)：到第三屏");
        type(ic.get(), "<sp>");
        check(!framed.empty() && ic->committed == framed, "setPage 后空格选框着的，实际 " + ic->committed);
    }
    // 工具栏的列表（常用语 11 条，一页 9 个）也一样：点下一页后数字、空格选的是第二页的
    {
        std::ofstream(customFile) << "ce jia\t测甲\nce yi\t测乙\nce bing\t测丙\nce ding\t测丁\nce wu\t测戊\n"
                                     "ce ji\t测己\nce geng\t测庚\nce xin\t测辛\nce ren\t测壬\nce gui\t测癸\n"
                                     "ce zi\t测子\n";
    }
    addon->reloadConfig();
    fresh(ic.get());
    type(ic.get(), "v<sp>2");
    {
        auto *list = common();
        check(list && list->totalSize() == 11 && list->size() == 9 && list->hasNext(),
              "常用语 11 条分两页：" + join(page(ic.get())));
        if (list) {
            list->next();
        }
        list = common();
        const auto p2 = page(ic.get());
        check(list && list->currentPage() == 1 && list->cursorIndex() == 0 && p2.size() == 2 &&
                  p2[0] == "ce gui\u3000测癸" && p2[1] == "ce zi\u3000测子",
              "常用语点下一页：第二页、光标在第一个：" + join(p2));
        type(ic.get(), "2");
        check(ic->committed == "测子", "常用语点下一页后按 2 选第二页第二个，实际 " + ic->committed);
    }
    fresh(ic.get());
    type(ic.get(), "v<sp>2");
    {
        if (auto *list = common()) {
            list->next();
        }
        type(ic.get(), "<sp>");
        check(ic->committed == "测癸", "常用语点下一页后空格选第二页第一个，实际 " + ic->committed);
    }
    fresh(ic.get());
    type(ic.get(), "v<sp>2");
    {
        if (auto *list = common()) {
            list->next();
        }
        if (auto *list = common()) {
            list->prev();
        }
        auto *list = common();
        check(list && list->currentPage() == 0 && list->cursorIndex() == 0 && page(ic.get()).size() == 9,
              "常用语点上一页：回到第一页");
        if (list) {
            list->nextCandidate();
        }
        type(ic.get(), "<sp>");
        check(ic->committed == "测乙", "常用语列表 nextCandidate 后空格选第二个，实际 " + ic->committed);
    }
    fresh(ic.get());
    type(ic.get(), "v<sp>2");
    {
        if (auto *list = common()) {
            list->next();
        }
        if (auto list = ic->inputPanel().candidateList(); list && list->size() > 1) {
            list->candidate(1).select(ic.get()); // 鼠标点第二页第二个
        }
        check(ic->committed == "测子", "常用语点下一页后点第二个，实际 " + ic->committed);
    }
    fresh(ic.get());

    // 删掉文件再 reload：回到默认
    std::filesystem::remove(configDir + "/wowtype.conf");
    std::filesystem::remove(customFile);
    addon->reloadConfig();
    fresh(ic.get());
    type(ic.get(), "nihao");
    panelList = ic->inputPanel().candidateList();
    check(panelList && panelList->layoutHint() == CandidateLayoutHint::Horizontal &&
              page(ic.get()).size() == 9 && page(ic.get())[0] == "你好",
          "恢复默认：横排、9 个、你好第一：" + join(page(ic.get())));
    fresh(ic.get());
    // 剪贴板历史默认关：关掉时清空，工具栏里提示去哪打开
    type(ic.get(), "v<sp>1");
    check(page(ic.get()).empty() &&
              ic->inputPanel().auxUp().toString().find("没打开") != std::string::npos,
          "默认不记剪贴板，关掉时清空：" + ic->inputPanel().auxUp().toString() + " | " +
              join(page(ic.get())));
    fresh(ic.get());

    // #129：「方向键」设成左右键移动光标：左键把光标移进拼音，字母插在光标处，退格删光标前一个；
    // 右键到了末尾不去挑候选，上下键选词
    {
        std::ofstream(configDir + "/wowtype.conf") << "ArrowKeys=Caret\n";
    }
    addon->reloadConfig();
    type(ic.get(), "nihao<left><left><left>");
    {
        const fcitx::Text &shown = ic->inputPanel().preedit();
        check(shown.cursor() >= 0 && shown.toString().substr(0, static_cast<std::size_t>(shown.cursor())) == "ni",
              "左键三下光标在 ni 后面：" + shown.toString() + " @" + std::to_string(shown.cursor()));
    }
    type(ic.get(), "x");
    check(preedit(ic.get()).find('x') != std::string::npos && ic->committed.empty(),
          "字母插在光标处：" + preedit(ic.get()));
    type(ic.get(), "<bs><end><right>");
    {
        auto *list = common();
        check(ic->inputPanel().preedit().cursor() == static_cast<int>(preedit(ic.get()).size()) && list &&
                  list->cursorIndex() == 0,
              "退格删掉插进去的 x，End 回末尾，末尾的右键不挑候选：" + preedit(ic.get()));
    }
    {
        const std::string want = page(ic.get()).at(1);
        type(ic.get(), "<down><sp>");
        check(ic->committed == want, "下键选第 2 个，空格上屏它：" + ic->committed + " / " + want);
    }
    fresh(ic.get());
    std::filesystem::remove(configDir + "/wowtype.conf");
    addon->reloadConfig();
    type(ic.get(), "nihao<left>");
    check(ic->inputPanel().preedit().cursor() == static_cast<int>(preedit(ic.get()).size()),
          "默认（都用来选词）左键不动编辑区的光标：@" + std::to_string(ic->inputPanel().preedit().cursor()));
    fresh(ic.get());

    // 单按 Shift 切英文（#28）：右 Shift 不是 fcitx 默认的临时切换键，走的是 WowType 自己的英文模式。
    // 按下、松开都不接受（照常交给应用）：外壳只在没接受时才把键转给应用，吞掉松开的 Shift，
    // Wayland 上的应用会以为它一直按着（#225）
    const auto tapShift = [&](KeySym sym) {
        KeyEvent press(ic.get(), Key(sym), false);
        const bool pressTaken = ic->keyEvent(press);
        KeyEvent release(ic.get(), Key(sym, KeyState::Shift), true);
        const bool releaseTaken = ic->keyEvent(release);
        return !pressTaken && !releaseTaken;
    };
    check(instance.inputMethodLabel(ic.get()) == "中", "中文时提示「中」：" + instance.inputMethodLabel(ic.get()));
    check(tapShift(FcitxKey_Shift_R), "单按右 Shift 切英文，按下和松开都交给应用（#225）");
    check(instance.inputMethodLabel(ic.get()) == "英", "英文时提示「英」：" + instance.inputMethodLabel(ic.get()));
    type(ic.get(), "nihao,");
    check(ic->committed.empty() && ic->passed == "nihao," && preedit(ic.get()).empty(),
          "英文模式字母、标点原样交给应用，实际 passed=" + ic->passed);
    tapShift(FcitxKey_Shift_R);
    fresh(ic.get());
    type(ic.get(), "nihao<sp>");
    check(ic->committed == "你好", "再按一次回到中文：" + ic->committed);
    fresh(ic.get());
    type(ic.get(), "nih");
    tapShift(FcitxKey_Shift_R);
    check(ic->committed == "nih" && preedit(ic.get()).empty(), "打到一半切英文，字母原样上屏：" + ic->committed);
    tapShift(FcitxKey_Shift_R);
    fresh(ic.get());
    {
        // Shift 按着打了别的键（大写字母）就不算单按
        const std::string before = instance.inputMethodLabel(ic.get());
        KeyEvent press(ic.get(), Key(FcitxKey_Shift_R), false);
        ic->keyEvent(press);
        send(ic.get(), Key(FcitxKey_A, KeyState::Shift));
        KeyEvent release(ic.get(), Key(FcitxKey_Shift_R, KeyState::Shift), true);
        check(!ic->keyEvent(release) && instance.inputMethodLabel(ic.get()) == before,
              "Shift+字母后松开 Shift 不切换");
        type(ic.get(), "<esc>nihao<sp>");
        check(ic->committed == "你好", "仍是中文：" + ic->committed);
    }
    fresh(ic.get());
    {
        // #158：切到英文后换到别的输入法再切回来，回到中文（InitialMode 默认 Chinese）；换窗口不算
        const auto english = [&]() {
            fresh(ic.get());
            type(ic.get(), "a");
            const bool ascii = ic->passed == "a" && preedit(ic.get()).empty();
            fresh(ic.get());
            return ascii;
        };
        tapShift(FcitxKey_Shift_R);
        ic->focusOut();
        ic->focusIn();
        check(english(), "换窗口后还是英文");
        instance.setCurrentInputMethod(ic.get(), "testim", true);
        instance.setCurrentInputMethod(ic.get(), "wowtype", true);
        check(!english(), "从别的输入法切回来是中文");
        // InitialMode=English：切回来是英文（#121）
        std::ofstream(configDir + "/wowtype.conf") << "InitialMode=English\n";
        addon->reloadConfig();
        check(!english(), "改设置不改当前的模式");
        instance.setCurrentInputMethod(ic.get(), "testim", true);
        instance.setCurrentInputMethod(ic.get(), "wowtype", true);
        check(english(), "InitialMode=English：切回来是英文");
        // InitialMode=Last：和切走时一样
        std::ofstream(configDir + "/wowtype.conf") << "InitialMode=Last\n";
        addon->reloadConfig();
        tapShift(FcitxKey_Shift_R);
        instance.setCurrentInputMethod(ic.get(), "testim", true);
        instance.setCurrentInputMethod(ic.get(), "wowtype", true);
        check(!english(), "InitialMode=Last：切走时是中文，切回来还是中文");
        tapShift(FcitxKey_Shift_R);
        instance.setCurrentInputMethod(ic.get(), "testim", true);
        instance.setCurrentInputMethod(ic.get(), "wowtype", true);
        check(english(), "InitialMode=Last：切走时是英文，切回来还是英文");
        tapShift(FcitxKey_Shift_R);
        std::filesystem::remove(configDir + "/wowtype.conf");
        addon->reloadConfig();
        check(!english(), "测完回到中文");
    }
    {
        // #254：换窗口、换应用时按 WindowMode 定中 / 英；默认 Same，和以前一样不动
        const auto english = [&]() {
            fresh(ic.get());
            type(ic.get(), "a");
            const bool ascii = ic->passed == "a" && preedit(ic.get()).empty();
            fresh(ic.get());
            return ascii;
        };
        const auto switchWindow = [&]() {
            ic->focusOut();
            ic->focusIn();
        };
        std::ofstream(configDir + "/wowtype.conf") << "WindowMode=English\n";
        addon->reloadConfig();
        switchWindow();
        check(english(), "WindowMode=English：换窗口后是英文");
        // 在窗口里切回中文，再换窗口又按默认定成英文
        tapShift(FcitxKey_Shift_R);
        check(!english(), "单按 Shift 还是能切回中文");
        switchWindow();
        check(english(), "再换窗口又回到默认的英文");
        // 只设了 WindowMode、没设 InitialMode 时，切输入法仍按 InitialMode 的默认中文
        instance.setCurrentInputMethod(ic.get(), "testim", true);
        instance.setCurrentInputMethod(ic.get(), "wowtype", true);
        check(!english(), "切输入法时 InitialMode 优先，回到中文");
        // WindowMode=Chinese：换窗口定成中文
        std::ofstream(configDir + "/wowtype.conf") << "WindowMode=Chinese\n";
        addon->reloadConfig();
        tapShift(FcitxKey_Shift_R);
        check(english(), "先切到英文");
        switchWindow();
        check(!english(), "WindowMode=Chinese：换窗口后是中文");
        // 默认 Same：换窗口保持当前模式（和以前一样）
        std::filesystem::remove(configDir + "/wowtype.conf");
        addon->reloadConfig();
        tapShift(FcitxKey_Shift_R);
        check(english(), "默认 WindowMode：先在当前窗口切到英文");
        switchWindow();
        check(english(), "WindowMode 默认 Same：换窗口还是英文");
        tapShift(FcitxKey_Shift_R);
        check(!english(), "测完回到中文");
    }
    {
        // #82：认 Shift 松开要看键码。xkb 选项（grp:shifts_toggle 等）或 fcitx5 按输入法布局重新翻译时，
        // 松开那一下 Shift 已经算按着，同一个键（左 Shift 键码 50）可能翻成 ISO_Next_Group
        const auto english = [&]() {
            fresh(ic.get());
            type(ic.get(), "a");
            const bool ascii = ic->passed == "a" && preedit(ic.get()).empty();
            fresh(ic.get());
            return ascii;
        };
        const auto tapCoded = [&](Key down, Key up) {
            const std::string before = instance.inputMethodLabel(ic.get());
            KeyEvent press(ic.get(), down, false);
            ic->keyEvent(press);
            KeyEvent release(ic.get(), up, true);
            ic->keyEvent(release);
            return instance.inputMethodLabel(ic.get()) != before;
        };
        check(tapCoded(Key(FcitxKey_Shift_L, KeyStates(), 50),
                       Key(FcitxKey_ISO_Next_Group, KeyState::Shift, 50)) &&
                  english(),
              "松开时符号变了（同一键码）也算单按 Shift");
        check(tapCoded(Key(FcitxKey_Shift_R, KeyStates(), 62), Key(FcitxKey_Shift_R, KeyStates(), 62)) &&
                  !english(),
              "松开时状态里没带 Shift 也切换（切回中文）");
        check(!tapCoded(Key(FcitxKey_Shift_L, KeyStates(), 50), Key(FcitxKey_Shift_R, KeyState::Shift, 62)) &&
                  !english(),
              "按左 Shift 松右 Shift 不算单按");
        {
            KeyEvent release(ic.get(), Key(FcitxKey_Shift_L, KeyState::Shift, 50), true);
            ic->keyEvent(release);
        }
        {
            // 按住时的自动重复不打断单按
            KeyEvent press(ic.get(), Key(FcitxKey_Shift_R, KeyStates(), 62), false);
            ic->keyEvent(press);
            KeyEvent repeat(ic.get(), Key(FcitxKey_Shift_R, KeyState::Repeat, 62), false);
            ic->keyEvent(repeat);
            KeyEvent release(ic.get(), Key(FcitxKey_Shift_R, KeyState::Shift, 62), true);
            const std::string before = instance.inputMethodLabel(ic.get());
            ic->keyEvent(release);
            check(instance.inputMethodLabel(ic.get()) != before && english(),
                  "按住 Shift 有自动重复也算单按");
            tapShift(FcitxKey_Shift_R);
            check(!english(), "再按一下回中文");
        }
        // fcitx5 全局快捷键里任何一项用了单按的 Shift（不只「切换输入法」「临时切换输入法」），
        // fcitx5 都先把它吃掉，WowType 收不到。设置界面「Shift 只给 WowType 用」要把这几项都清掉。
        {
            RawConfig raw;
            raw.setValueByPath("Hotkey/EnumerateForwardKeys/0", "Shift_R");
            instance.globalConfig().load(raw, true);
        }
        tapShift(FcitxKey_Shift_R);
        check(instance.inputMethod(ic.get()) != "wowtype" || !english(),
              "EnumerateForwardKeys=Shift_R 时 fcitx5 先拿走右 Shift");
        {
            RawConfig raw;
            raw.setValueByPath("Hotkey/EnumerateForwardKeys", "");
            instance.globalConfig().load(raw, true);
        }
        instance.setCurrentInputMethod(ic.get(), "wowtype", true);
        check(instance.inputMethod(ic.get()) == "wowtype" && !english(), "回到 WowType 中文");
        check(tapShift(FcitxKey_Shift_R) && english(), "清掉以后右 Shift 又归 WowType");
        tapShift(FcitxKey_Shift_R);
        check(!english(), "回中文");
    }
    {
        // #225：Wayland 上 KWin 把键交给输入法，外壳（fcitx5）只在没接受的时候才经虚拟键盘
        // 把键转给应用。单按 Shift 切了模式也不能吞掉松开的 Shift：应用收不到松开，会以为
        // Shift 还按着——之后 shift+单击开新窗口、滚轮变横向、快捷键错乱。
        // Shift 单独按下、松开不出字，交给应用没有副作用。
        KeyEvent press(ic.get(), Key(FcitxKey_Shift_R), false);
        check(!ic->keyEvent(press), "#225：Shift 按下交给应用");
        KeyEvent release(ic.get(), Key(FcitxKey_Shift_R, KeyState::Shift), true);
        check(!ic->keyEvent(release), "#225：单按 Shift 切了模式，松开的 Shift 也交给应用");
        check(instance.inputMethodLabel(ic.get()) == "英", "#225：这一下仍然切到了英文");
        tapShift(FcitxKey_Shift_R);
        check(instance.inputMethodLabel(ic.get()) == "中", "#225：再单按一下回到中文");
    }
    fresh(ic.get());
    {
        // #253：JetBrains 的双击 Shift（到处搜索）不该切中英文。开着双击判断（插件默认，别的用例为了
        // 连按不用等，用 WOWTYPE_SHIFT_DOUBLE_TAP=0 关着）：单按先等 0.35 秒，这么久以内又单按一下两下都不算。
        // 这里事件循环不走、定时器不来：靠接着按的键让等着的那一下先切（定时器那条路在互译用例里测）
        ::unsetenv("WOWTYPE_SHIFT_DOUBLE_TAP");
        addon->reloadConfig();
        const auto label = [&]() { return instance.inputMethodLabel(ic.get()); };
        const auto settle = []() { std::this_thread::sleep_for(std::chrono::milliseconds(400)); };
        // 双击：两下的按下、松开都不接受（交给应用，JetBrains 才看得到双击），模式不变
        const bool first = tapShift(FcitxKey_Shift_R);
        const bool second = tapShift(FcitxKey_Shift_R);
        check(first && second && label() == "中", "#253：双击 Shift 四个事件都交给应用，不切：" + label());
        settle();
        type(ic.get(), "nihao<sp>");
        check(ic->committed == "你好" && label() == "中", "#253：双击以后还是中文：" + ic->committed);
        fresh(ic.get());
        // 左 Shift 也一样（Shift_L 不是 fcitx5 默认的临时切换键时）
        KeyEvent leftPress(ic.get(), Key(FcitxKey_Shift_L), false);
        const bool leftTaken = ic->keyEvent(leftPress);
        KeyEvent leftRelease(ic.get(), Key(FcitxKey_Shift_L, KeyState::Shift), true);
        const bool leftReleaseTaken = ic->keyEvent(leftRelease);
        check(!leftTaken && !leftReleaseTaken, "#253：等双击时左 Shift 的按下、松开也交给应用");
        check(tapShift(FcitxKey_Shift_L) && label() == "中", "#253：左 Shift 双击也不切");
        settle();
        fresh(ic.get());
        // 单按：先不切；接着打字时先切，这个字母照英文交给应用（和以前单按立刻切一样）
        check(tapShift(FcitxKey_Shift_R) && label() == "中", "#253：单按先不切（等双击）");
        type(ic.get(), "a");
        check(ic->passed == "a" && ic->committed.empty() && preedit(ic.get()).empty() && label() == "英",
              "#253：单按以后接着打字：先切英文，a 交给应用：" + ic->passed + " " + label());
        fresh(ic.get());
        // 慢的第二下（过了间隔才按下）：第一下照切，第二下自己再等
        tapShift(FcitxKey_Shift_R);
        settle();
        KeyEvent slowPress(ic.get(), Key(FcitxKey_Shift_R), false);
        check(!ic->keyEvent(slowPress) && label() == "中", "#253：过了间隔才按第二下：第一下照切（回中文）");
        KeyEvent slowRelease(ic.get(), Key(FcitxKey_Shift_R, KeyState::Shift), true);
        check(!ic->keyEvent(slowRelease) && label() == "中", "#253：第二下松开也交给应用，先不切");
        // 等着的时候输入框重置（点了别处、换窗口）：那一下照切
        ic->focusOut();
        ic->focusIn();
        check(label() == "英", "#253：等双击时输入框重置，照切英文：" + label());
        type(ic.get(), "b");
        check(ic->passed == "b" && label() == "英", "#253：重置后是英文：" + ic->passed);
        fresh(ic.get());
        tapShift(FcitxKey_Shift_R);
        type(ic.get(), "ni");
        check(label() == "中" && preedit(ic.get()) == "ni", "#253：单按回中文，接着打拼音：" + preedit(ic.get()));
        // 打到一半双击：拼音留着，什么也不上屏
        tapShift(FcitxKey_Shift_R);
        tapShift(FcitxKey_Shift_R);
        settle();
        check(ic->committed.empty() && preedit(ic.get()) == "ni" && label() == "中",
              "#253：打到一半双击 Shift：拼音留着，不上屏：" + ic->committed + "|" + preedit(ic.get()));
        type(ic.get(), "hao<sp>");
        check(ic->committed == "你好", "#253：接着打完照常上屏：" + ic->committed);
        // 打到一半单按：等的时候拼音还在，接着按键时字母原样上屏、切英文
        fresh(ic.get());
        type(ic.get(), "nih");
        tapShift(FcitxKey_Shift_R);
        check(ic->committed.empty() && preedit(ic.get()) == "ni'h" && label() == "中", "#253：打到一半单按：先不上屏：" + ic->committed + "|" + preedit(ic.get()) + "|" + label());
        type(ic.get(), "a");
        check(ic->committed == "nih" && ic->passed == "a" && label() == "英",
              "#253：接着按键：字母原样上屏，切英文，a 交给应用：" + ic->committed + "|" + ic->passed);
        fresh(ic.get());
        tapShift(FcitxKey_Shift_R);
        ::setenv("WOWTYPE_SHIFT_DOUBLE_TAP", "0", 1);
        addon->reloadConfig();
        type(ic.get(), "nihao<sp>");
        check(ic->committed == "你好" && label() == "中", "#253：测完回到中文：" + ic->committed);
        fresh(ic.get());
    }

    // fcitx5 全局翻页热键（#27）：设成 , . 后打字途中按它们翻页，不上屏标点
    {
        RawConfig raw;
        raw.setValueByPath("Hotkey/PrevPage/0", "comma");
        raw.setValueByPath("Hotkey/NextPage/0", "period");
        instance.globalConfig().load(raw, true);
    }
    type(ic.get(), "shi");
    const auto shiPage = page(ic.get());
    type(ic.get(), ".");
    check(ic->committed.empty() && page(ic.get()) != shiPage, "全局翻页键 . 翻到下一页");
    type(ic.get(), ",");
    check(ic->committed.empty() && page(ic.get()) == shiPage, "全局翻页键 , 翻回上一页");
    type(ic.get(), ",");
    check(ic->committed.empty(), "第一页再按 , 也不上屏标点");
    {
        RawConfig raw;
        raw.setValueByPath("Hotkey/PrevPage/0", "Up");
        raw.setValueByPath("Hotkey/NextPage/0", "Down");
        instance.globalConfig().load(raw, true);
    }
    fresh(ic.get());

    // 双拼方案：微软双拼（分号是 ing）
    {
        std::ofstream(configDir + "/wowtype.conf") << "Shuangpin=True\nShuangpinScheme=Microsoft\n";
    }
    addon->reloadConfig();
    type(ic.get(), "vsgo");
    check(preedit(ic.get()).find("zhong") != std::string::npos, "双拼编辑区显示全拼：" + preedit(ic.get()));
    type(ic.get(), "<sp>");
    check(ic->committed == "中国", "微软双拼 vsgo -> 中国：" + ic->committed);
    fresh(ic.get());
    type(ic.get(), "x;");
    check(preedit(ic.get()).find("xing") != std::string::npos && ic->committed.empty(),
          "微软双拼分号当 ing：x; -> " + preedit(ic.get()));
    fresh(ic.get());
    type(ic.get(), "ni;");
    check(ic->committed.find("；") != std::string::npos, "成对之后的分号还是标点：" + ic->committed);
    fresh(ic.get());
    // #160：双拼时 v 是声母键，计算器用大写 V
    type(ic.get(), "V1+2*3");
    check(preedit(ic.get()) == "V1+2*3" && !page(ic.get()).empty() && page(ic.get())[0] == "7",
          "双拼 V1+2*3 -> 7：" + preedit(ic.get()) + " | " + join(page(ic.get())));
    type(ic.get(), "=");
    check(ic->committed == "7", "双拼按 = 上屏结果：" + ic->committed);
    fresh(ic.get());
    // #268：双拼的简拼，每个键都是声母（sm，微软双拼里读不通）时当成只打了声母
    type(ic.get(), "sm");
    check(!page(ic.get()).empty() && page(ic.get())[0] == "什么",
          "双拼简拼 sm -> 什么：" + join(page(ic.get())));
    type(ic.get(), "<sp>");
    check(ic->committed == "什么", "双拼简拼选「什么」：" + ic->committed);
    fresh(ic.get());
    {
        std::ofstream(configDir + "/wowtype.conf")
            << "Shuangpin=True\nShuangpinScheme=Microsoft\nShuangpinAbbrev=False\n";
    }
    addon->reloadConfig();
    type(ic.get(), "sm");
    {
        const auto cands = page(ic.get());
        check(std::find(cands.begin(), cands.end(), "什么") == cands.end(),
              "关掉双拼简拼后 sm 没有「什么」：" + join(cands));
    }
    fresh(ic.get());
    // #122：设置里打开「双拼时编辑区显示打的键」
    {
        std::ofstream(configDir + "/wowtype.conf")
            << "Shuangpin=True\nShuangpinScheme=Microsoft\nShuangpinShowKeys=True\n";
    }
    addon->reloadConfig();
    type(ic.get(), "vsgo");
    check(preedit(ic.get()) == "vsgo", "双拼编辑区显示打的键：" + preedit(ic.get()));
    type(ic.get(), "<sp>");
    check(ic->committed == "中国", "显示打的键时照样出中国：" + ic->committed);
    std::filesystem::remove(configDir + "/wowtype.conf");
    addon->reloadConfig();
    fresh(ic.get());

    // 五笔：码表用一小段（rime-wubi 的原样几行），WOWTYPE_WUBI 指过去
    {
        const auto auxUp = [&] { return ic->inputPanel().auxUp().toString(); };
        const std::string table = configDir + "/wubi86.tsv";
        std::ofstream(table) << "g\t一\t2015124793\nggl\t一\t2830000000\nggll\t一\t2830000000\n"
                                "v\t发\t395047607\nw\t人\t1002212710\nwq\t你\t597727619\n"
                                "wqin\t您\t3090000000\nwqvb\t你好\t70500000\nwqvb\t您好\t34700000\n";
        // 先试没有码表：照全拼打，候选框上方说为什么
        setenv("WOWTYPE_WUBI", (configDir + "/没有这个文件.tsv").c_str(), 1);
        std::ofstream(configDir + "/wowtype.conf") << "InputScheme=Wubi86\n";
        addon->reloadConfig();
        type(ic.get(), "nihao");
        check(auxUp().find("没有五笔码表") != std::string::npos, "五笔没有码表时提示：" + auxUp());
        type(ic.get(), "<sp>");
        check(ic->committed == "你好", "五笔没有码表时照全拼打：" + ic->committed);
        fresh(ic.get());
        setenv("WOWTYPE_WUBI", table.c_str(), 1);
        addon->reloadConfig();
        type(ic.get(), "ggll");
        check(ic->committed == "一" && preedit(ic.get()).empty(), "五笔四码唯一自动上屏 ggll -> 一：" + ic->committed);
        fresh(ic.get());
        type(ic.get(), "wqvb");
        {
            const auto p = page(ic.get());
            check(ic->committed.empty() && p.size() >= 2 && p[0] == "你好" && p[1] == "您好",
                  "五笔重码按码表顺序：" + join(p));
        }
        type(ic.get(), "g");
        check(ic->committed == "你好" && preedit(ic.get()) == "g", "五笔第五码顶字：" + ic->committed + " / " + preedit(ic.get()));
        fresh(ic.get());
        type(ic.get(), "wq");
        {
            const auto p = page(ic.get());
            check(!p.empty() && p[0] == "你" && std::find(p.begin(), p.end(), "您 in") != p.end(),
                  "五笔逐码提示带还要打的码：" + join(p));
        }
        type(ic.get(), ",");
        check(ic->committed == "你，", "五笔标点顶字：" + ic->committed);
        fresh(ic.get());
        type(ic.get(), "wx");
        check(auxUp() == "空码" && page(ic.get()).empty() && preedit(ic.get()) == "wx", "五笔空码提示：" + auxUp());
        type(ic.get(), "<sp>");
        check(ic->committed.empty() && preedit(ic.get()).empty() && auxUp().empty(), "五笔空码空格清空");
        fresh(ic.get());
        type(ic.get(), "znihao");
        check(preedit(ic.get()) == "zni'hao" && !page(ic.get()).empty() && page(ic.get())[0] == "你好 wqvb",
              "五笔 z 临时拼音带反查的五笔码：" + preedit(ic.get()) + " | " + join(page(ic.get())));
        type(ic.get(), "<sp>");
        check(ic->committed == "你好", "临时拼音上屏：" + ic->committed);
        fresh(ic.get());
        type(ic.get(), "v<sp>");
        check(ic->committed == "发" && auxUp().empty(), "五笔 v + 空格上屏「发」，不开工具栏：" + ic->committed);
        fresh(ic.get());
        type(ic.get(), "V1+2*3=");
        check(ic->committed == "7", "五笔计算器用大写 V：" + ic->committed);
        fresh(ic.get());
        // 四码唯一自动上屏关掉：ggll 等空格
        std::ofstream(configDir + "/wowtype.conf") << "InputScheme=Wubi86\nWubiAutoCommit=False\nWubiHint=False\n";
        addon->reloadConfig();
        type(ic.get(), "ggll");
        check(ic->committed.empty() && preedit(ic.get()) == "ggll", "关掉四码唯一自动上屏：" + ic->committed);
        fresh(ic.get());
        type(ic.get(), "wq");
        {
            const auto p = page(ic.get());
            check(std::find(p.begin(), p.end(), "您") != p.end(), "关掉编码提示：候选不带码：" + join(p));
        }
        fresh(ic.get());
        unsetenv("WOWTYPE_WUBI");
        std::filesystem::remove(table);
    }
    std::filesystem::remove(configDir + "/wowtype.conf");
    addon->reloadConfig();
    fresh(ic.get());

    // 日期时间候选（#36）：只认全拼 riqi / shijian / xingqi，格式从第二个开始
    type(ic.get(), "riqi");
    {
        const auto items = page(ic.get());
        check(items.size() > 2 && items[0] == "日期" && items[1].find("年") != std::string::npos &&
                  items[2].find('-') != std::string::npos,
              "riqi：日期 + 当前日期：" + join(items));
        type(ic.get(), "2");
        check(ic->committed == items[1], "选第二个上屏日期：" + ic->committed);
    }
    fresh(ic.get());
    type(ic.get(), "shijian");
    check(page(ic.get()).size() > 1 && page(ic.get())[0] == "时间" &&
              page(ic.get())[1].find(':') != std::string::npos,
          "shijian：时间 + 当前时间：" + join(page(ic.get())));
    fresh(ic.get());
    type(ic.get(), "xingqi");
    check(page(ic.get()).size() > 1 && page(ic.get())[1].rfind("星期", 0) == 0,
          "xingqi：星期几：" + join(page(ic.get())));
    fresh(ic.get());
    type(ic.get(), "sj");
    {
        // 简拼 sj 也出时间，但首选仍是普通词，格式从第二个开始
        const auto p = page(ic.get());
        check(p.size() > 1 && p[0].find(':') == std::string::npos && p[1].find(':') != std::string::npos,
              "简拼 sj 首选是词、第二个是时间：" + join(p));
    }
    fresh(ic.get());

    // V 模式计算器
    type(ic.get(), "v1+2*3");
    check(preedit(ic.get()) == "v1+2*3" && !page(ic.get()).empty() && page(ic.get())[0] == "7",
          "v1+2*3 -> 7：" + preedit(ic.get()) + " | " + join(page(ic.get())));
    type(ic.get(), "<sp>");
    check(ic->committed == "7", "空格上屏结果：" + ic->committed);
    fresh(ic.get());
    type(ic.get(), "v(1.5-0.5)/4");
    check(ic->committed.empty() && preedit(ic.get()) == "v(1.5-0.5)/4", "算式里的 . - 不翻页也不上屏：" + preedit(ic.get()));
    check(!page(ic.get()).empty() && page(ic.get())[0] == "0.25", "v(1.5-0.5)/4 -> 0.25：" + join(page(ic.get())));
    type(ic.get(), "=");
    check(ic->committed == "0.25", "按 = 上屏结果：" + ic->committed);
    fresh(ic.get());
    type(ic.get(), "very");
    check(join(page(ic.get())).find("very") != std::string::npos, "v 开头的英文照常打：" + join(page(ic.get())));
    fresh(ic.get());

    // 模糊音分组：n=l 默认关，打开后 liunai 能出牛奶
    {
        std::ofstream(configDir + "/wowtype.conf") << "Fuzzy=True\nTypoCorrection=False\n";
    }
    addon->reloadConfig();
    type(ic.get(), "liunai");
    check(join(page(ic.get())).find("牛奶") == std::string::npos, "n=l 默认不开：" + join(page(ic.get())));
    fresh(ic.get());
    {
        std::ofstream(configDir + "/wowtype.conf") << "Fuzzy=True\nFuzzyNL=True\nTypoCorrection=False\n";
    }
    addon->reloadConfig();
    type(ic.get(), "liunai");
    check(join(page(ic.get())).find("牛奶") != std::string::npos, "打开 n=l 后 liunai 出牛奶：" + join(page(ic.get())));
    fresh(ic.get());

    // 扩展 B 区以后的生僻字默认不列（常见字体显示成方块），RareExtChars 打开才列
    {
        // 返回（候选总数，有没有 𠯜）。𠯜 在扩展 B 区，Noto CJK 没有；𬭤 这种规范字表里的照常出
        auto houChars = [&]() {
            auto list = ic->inputPanel().candidateList();
            auto *all = list ? dynamic_cast<CommonCandidateList *>(list.get()) : nullptr;
            int total = 0;
            bool ext = false;
            for (int i = 0; all && i < all->totalSize(); ++i) {
                ++total;
                ext = ext || all->candidateFromAll(i).text().toString() == "𠯜";
            }
            return std::make_pair(total, ext);
        };
        std::ofstream(configDir + "/wowtype.conf") << "";
        addon->reloadConfig();
        type(ic.get(), "hou");
        const auto [total, ext] = houChars();
        check(total > 40 && !ext, "hou 默认不列扩展 B 区以后的字（𠯜）：共 " + std::to_string(total) + " 个");
        fresh(ic.get());
        std::ofstream(configDir + "/wowtype.conf") << "RareExtChars=True\n";
        addon->reloadConfig();
        type(ic.get(), "hou");
        const auto [totalOn, extOn] = houChars();
        check(extOn && totalOn > total, "打开 RareExtChars 后列出 𠯜：共 " + std::to_string(totalOn) + " 个");
        fresh(ic.get());
        std::ofstream(configDir + "/wowtype.conf") << "";
        addon->reloadConfig();
    }

    // 标点样式：半角（#51）
    {
        std::ofstream(configDir + "/wowtype.conf") << "PunctuationStyle=Halfwidth\n";
    }
    addon->reloadConfig();
    type(ic.get(), "nihao,");
    check(ic->committed == "你好,", "半角：打字途中逗号是英文逗号，实际 " + ic->committed);
    fresh(ic.get());
    type(ic.get(), "(.)");
    check(ic->committed.empty() && ic->passed == "(.)", "半角：没在打字时标点原样交给应用，实际 " + ic->passed);
    fresh(ic.get());

    // 翻页键可选（#36）：打开 , . 和 Tab，关掉 - =
    {
        std::ofstream(configDir + "/wowtype.conf")
            << "PageKeysMinusEqual=False\nPageKeysCommaPeriod=True\nPageKeysTab=True\n";
    }
    addon->reloadConfig();
    type(ic.get(), "shi");
    {
        const auto p1 = page(ic.get());
        type(ic.get(), ",");
        check(ic->committed.empty() && page(ic.get()) == p1, "第一页按 , 不上屏也不翻页");
        type(ic.get(), ".");
        const auto p2 = page(ic.get());
        check(ic->committed.empty() && !p2.empty() && p2 != p1, ". 翻到下一页：" + join(p2));
        type(ic.get(), "<stab>");
        check(page(ic.get()) == p1, "Shift+Tab 翻回第一页：" + join(page(ic.get())));
        type(ic.get(), "<tab>");
        check(page(ic.get()) == p2, "Tab 翻到下一页：" + join(page(ic.get())));
        type(ic.get(), "=");
        check(!ic->committed.empty(), "关掉 - = 后按 = 先上屏候选：" + ic->committed);
    }
    fresh(ic.get());

    // 自定义词：非拼音编码、\n 换行
    {
        std::ofstream(configDir + "/wowtype.conf") << "EmojiSuggest=False\n";
        std::ofstream(customFile) << "mail\tme@example.com\ndi zhi\t四川省\\n宜宾市\n";
    }
    addon->reloadConfig();
    type(ic.get(), "mail");
    check(!page(ic.get()).empty() && page(ic.get())[0] == "me@example.com", "自定义编码 mail：" + join(page(ic.get())));
    type(ic.get(), "<sp>");
    check(ic->committed == "me@example.com", "上屏自定义编码的词：" + ic->committed);
    fresh(ic.get());
    type(ic.get(), "dizhi");
    check(!page(ic.get()).empty() && page(ic.get())[0] == "四川省⏎宜宾市", "候选里换行画成 ⏎：" + join(page(ic.get())));
    type(ic.get(), "<sp>");
    check(ic->committed == "四川省\n宜宾市", "上屏真的换行：" + ic->committed);
    std::filesystem::remove(customFile);
    fresh(ic.get());

    // 分号、引号选词（默认关）
    type(ic.get(), "ni;");
    check(ic->committed == "你；", "默认分号还是标点：" + ic->committed);
    fresh(ic.get());
    {
        std::ofstream(configDir + "/wowtype.conf") << "SelectKeys=Semicolon\nEmojiSuggest=False\n";
    }
    addon->reloadConfig();
    type(ic.get(), "shi");
    {
        const auto items = page(ic.get());
        type(ic.get(), ";");
        check(items.size() > 1 && ic->committed == items[1], "分号选第二个：" + ic->committed);
    }
    fresh(ic.get());
    type(ic.get(), "xi'an");
    check(preedit(ic.get()).find("xi'an") != std::string::npos, "只开分号时引号仍是隔音符：" + preedit(ic.get()));
    fresh(ic.get());
    {
        std::ofstream(configDir + "/wowtype.conf") << "SelectKeys=SemicolonQuote\nEmojiSuggest=False\n";
    }
    addon->reloadConfig();
    type(ic.get(), "shi");
    {
        const auto items = page(ic.get());
        type(ic.get(), "'");
        check(items.size() > 2 && ic->committed == items[2], "引号选第三个：" + ic->committed);
    }
    fresh(ic.get());
    type(ic.get(), "shi<pgdn>");
    {
        const auto items = page(ic.get());
        type(ic.get(), ";");
        check(items.size() > 1 && ic->committed == items[1], "翻页后分号选这一页第二个：" + ic->committed);
    }
    std::filesystem::remove(configDir + "/wowtype.conf");
    addon->reloadConfig();
    fresh(ic.get());

    // 自动补空格（#36）：只看光标前一个字和要上屏的第一个字；读不到光标前的文字、密码框不补
    {
        std::ofstream(configDir + "/wowtype.conf") << "AutoSpace=True\nEmojiSuggest=False\n";
    }
    addon->reloadConfig();
    auto surround = [&](const std::string &text, int cursorBack = 0, int anchorBack = 0) {
        const auto len = static_cast<unsigned>(utf8::length(text));
        ic->surroundingText().setText(text, len - cursorBack, len - anchorBack);
    };
    ic->setCapabilityFlags(CapabilityFlag::SurroundingText);
    fresh(ic.get());
    surround("第");
    type(ic.get(), "5");
    check(ic->committed == " 5" && ic->passed.empty(), "汉字后打数字补空格：[" + ic->committed + "]");
    fresh(ic.get());
    surround("第 5");
    // 测的是补空格，不是排序：用首选不受上文影响的你好（zhangjie 的章节 / 张杰会随前面用例上屏的字变）
    type(ic.get(), "nihao<sp>");
    check(ic->committed == " 你好", "数字后上屏汉字补空格：[" + ic->committed + "]");
    fresh(ic.get());
    surround("Linux");
    type(ic.get(), "xitong<sp>");
    check(ic->committed == " 系统", "字母后上屏汉字补空格：[" + ic->committed + "]");
    fresh(ic.get());
    surround("你好");
    tapKey(ic.get(), FcitxKey_Shift_R);  // 切到英文
    type(ic.get(), "L");
    surround("你好 L");
    type(ic.get(), "i");
    tapKey(ic.get(), FcitxKey_Shift_R);  // 回中文
    check(ic->committed == " L" && ic->passed == "i",
          "英文模式汉字后第一个字母补空格，后面的照常交给应用：[" + ic->committed + "] " + ic->passed);
    // 按下 Shift 还没松开，输入框就被重置（Shift+点鼠标选字）或者失去焦点又回来：再松开不算单按 Shift，
    // 还是中文；之后单按 Shift 照常切换
    for (const bool blur : {false, true}) {
        fresh(ic.get());
        surround("");
        KeyEvent press(ic.get(), Key(FcitxKey_Shift_L), false);
        ic->keyEvent(press);
        if (blur) {
            ic->focusOut();
            ic->focusIn();
        } else {
            ic->reset();
        }
        KeyEvent release(ic.get(), Key(FcitxKey_Shift_L, KeyState::Shift), true);
        const bool took = ic->keyEvent(release);
        type(ic.get(), "nihao<sp>");
        const bool chinese = ic->committed == "你好";
        check(!took && chinese,
              std::string(blur ? "按下 Shift 后失去焦点又回来" : "按下 Shift 后输入框被重置") +
                  "：再松开不切中英文，实际上屏「" + ic->committed + "」交给应用「" + ic->passed + "」");
        if (!chinese) {
            tapKey(ic.get(), FcitxKey_Shift_L); // 切走了就切回来，别带坏后面的用例
        }
    }
    fresh(ic.get());
    tapKey(ic.get(), FcitxKey_Shift_L);
    type(ic.get(), "ni");
    tapKey(ic.get(), FcitxKey_Shift_L);
    check(ic->committed.empty() && ic->passed == "ni", "之后单按 Shift 照常切到英文再切回来，实际交给应用「" +
                                                          ic->passed + "」上屏「" + ic->committed + "」");
    fresh(ic.get());
    surround("第 ");
    type(ic.get(), "5");
    check(ic->committed.empty() && ic->passed == "5", "已经有空格不补：[" + ic->committed + "]");
    fresh(ic.get());
    surround("你好");
    type(ic.get(), "shijie<sp>");
    check(ic->committed == "世界", "纯中文不补：[" + ic->committed + "]");
    fresh(ic.get());
    surround("你好abc", 3, 0);  // 光标在「好」后面、选中了 abc
    type(ic.get(), "5");
    check(ic->committed == " 5", "有选区时看选区前面的字：[" + ic->committed + "]");
    fresh(ic.get());
    ic->setCapabilityFlags(CapabilityFlags{CapabilityFlag::SurroundingText, CapabilityFlag::Password});
    surround("第");
    type(ic.get(), "5");
    check(ic->committed.empty() && ic->passed == "5", "密码框不补：[" + ic->committed + "]");
    fresh(ic.get());
    for (const auto flag : {CapabilityFlag::Url, CapabilityFlag::Email}) {
        ic->setCapabilityFlags(CapabilityFlags{CapabilityFlag::SurroundingText, flag});
        surround("第");
        type(ic.get(), "5");
        check(ic->committed.empty() && ic->passed == "5", "网址、邮箱输入框不补：[" + ic->committed + "]");
        fresh(ic.get());
    }
    ic->setCapabilityFlags(CapabilityFlags{});
    type(ic.get(), "5");
    check(ic->committed.empty() && ic->passed == "5", "读不到光标前的文字不补");
    {
        std::ofstream(configDir + "/wowtype.conf") << "AutoSpace=True\nAutoSpaceDigits=False\nEmojiSuggest=False\n";
    }
    addon->reloadConfig();
    ic->setCapabilityFlags(CapabilityFlag::SurroundingText);
    fresh(ic.get());
    surround("第");
    type(ic.get(), "5");
    check(ic->committed.empty() && ic->passed == "5", "关掉数字那项后数字不补");
    fresh(ic.get());
    surround("Linux");
    type(ic.get(), "xitong<sp>");
    check(ic->committed == " 系统", "字母那项还开着：[" + ic->committed + "]");
    std::filesystem::remove(configDir + "/wowtype.conf");
    addon->reloadConfig();
    ic->setCapabilityFlags(CapabilityFlags{});
    fresh(ic.get());

    // 中文标点自动配对（AutoPairPunct）：上屏「（）」后发一下左键把光标放中间（等上屏落到应用，最晚在下一个键
    // 之前；这里没跑事件循环，是在松开的那一下发的），跳过补好的右括号发右键，空的一对退格吃掉、按顺序发 Delete 和退格
    {
        std::ofstream(configDir + "/wowtype.conf") << "AutoPairPunct=True\nEmojiSuggest=False\n";
    }
    addon->reloadConfig();
    // 换个焦点：清掉配对和「刚给应用发过键」的记号
    const auto pairFresh = [&ic] {
        ic->focusOut();
        ic->focusIn();
        fresh(ic.get());
    };
    const auto pairReport = [&ic] {
        return "上屏「" + ic->committed + "」交给应用「" + ic->passed + "」发的键「" + ic->forwarded + "」";
    };
    pairFresh();
    type(ic.get(), "(");
    check(ic->committed == "（）" && ic->forwarded == "Left ", "( 上屏（），再发左键：" + pairReport());
    type(ic.get(), "3)");
    check(ic->committed == "（）" && ic->passed == "3" && ic->forwarded == "Left Right ",
          "( 3 ) 是（3）：左键在 3 之前发，) 跳过补好的右括号：" + pairReport());
    pairFresh();
    type(ic.get(), "(<sp>)");
    check(ic->committed == "（）" && ic->passed == " " && ic->forwarded == "Left Right ",
          "( 空格 ) 是（ ）：" + pairReport());
    pairFresh();
    type(ic.get(), "(nihao)");
    check(ic->committed == "（）你好" && ic->forwarded == "Left Right ",
          "( nihao ) 上屏你好再跳过右括号：" + pairReport());
    pairFresh();
    type(ic.get(), "((");
    check(ic->committed == "（）（）" && ic->forwarded == "Left Left ", "连着两个 (：" + pairReport());
    type(ic.get(), "))");
    check(ic->forwarded == "Left Left Right Right ", "套着的两层都跳过：" + pairReport());
    pairFresh();
    type(ic.get(), "(");
    const bool tookBackspace = send(ic.get(), Key(FcitxKey_BackSpace));
    check(tookBackspace && ic->forwarded == "Left Delete BackSpace ",
          "空的一对退格：吃掉退格，按顺序发左键、Delete、退格：" + pairReport());
    pairFresh();
    type(ic.get(), "(1<bs>");
    check(ic->passed == "1" && ic->forwarded == "Left ", "里面有字时退格照常交给应用：" + pairReport());
    // 应用因为发的左键重置了输入法（GTK 挪光标时会）：不算点了别处，) 照样跳过
    pairFresh();
    type(ic.get(), "(1");
    ic->reset();
    type(ic.get(), ")");
    check(ic->forwarded == "Left Right ", "自己发的左键引起的重置不打断配对：" + pairReport());
    // 方向键、失去焦点以后不跳了
    pairFresh();
    type(ic.get(), "(<left>)");
    check(ic->committed == "（））" && ic->forwarded == "Left ", "按了方向键以后 ) 照常上屏：" + pairReport());
    pairFresh();
    type(ic.get(), "(1");
    ic->focusOut();
    ic->focusIn();
    type(ic.get(), ")");
    check(ic->committed == "（））" && ic->passed == "1" && ic->forwarded == "Left ",
          "失去焦点以后 ) 照常上屏：" + pairReport());
    // 读得到周围文字：光标后面不是补好的右括号（点到了别处）就不跳
    ic->setCapabilityFlags(CapabilityFlag::SurroundingText);
    pairFresh();
    ic->surroundingText().setText("", 0, 0);
    type(ic.get(), "(1");
    ic->surroundingText().setText("（1）", 2, 2);
    type(ic.get(), ")");
    check(ic->forwarded == "Left Right ", "光标后面是补好的右括号：跳过：" + pairReport());
    pairFresh();
    ic->surroundingText().setText("", 0, 0);
    type(ic.get(), "(1");
    ic->surroundingText().setText("别的字", 1, 1);
    type(ic.get(), ")");
    check(ic->committed == "（））" && ic->passed == "1" && ic->forwarded == "Left ",
          "光标后面不是补好的右括号：不跳：" + pairReport());
    ic->surroundingText().invalidate();
    ic->setCapabilityFlags(CapabilityFlags{});
    std::filesystem::remove(configDir + "/wowtype.conf");
    addon->reloadConfig();
    pairFresh();
    type(ic.get(), "(");
    check(ic->committed == "（" && ic->forwarded.empty(), "默认不配对：" + pairReport());
    pairFresh();

    // 打字统计（TypingStats）：默认关，打了字、失焦也不建 stats.json；打开以后只记计数（不记打的字），
    // 密码框里的上屏不算；写文件在核心的后台线程，这里等一会儿再看
    {
        const std::string statsDir = std::string(std::getenv("XDG_DATA_HOME")) + "/wowtype";
        const std::string statsFile = statsDir + "/stats.json";
        const auto readStats = [&]() {
            std::ifstream in(statsFile);
            return std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
        };
        const auto waitFor = [&](const std::function<bool()> &done) {
            for (int i = 0; i < 60 && !done(); ++i) {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
            }
            return done();
        };
        std::filesystem::remove(statsFile);
        type(ic.get(), "nihao<sp>");
        check(ic->committed == "你好", "统计关着时照常打字：[" + ic->committed + "]");
        ic->focusOut();
        ic->focusIn();
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        check(!std::filesystem::exists(statsFile) && !std::filesystem::exists(statsDir + "/stats.clear"),
              "统计默认关：不建 stats.json");
        {
            std::ofstream(configDir + "/wowtype.conf") << "TypingStats=True\n";
        }
        addon->reloadConfig();
        fresh(ic.get());
        type(ic.get(), "nihao<sp>");
        check(ic->committed == "你好", "统计开着时照常打字：[" + ic->committed + "]");
        fresh(ic.get());
        for (const auto flag : {CapabilityFlag::Password, CapabilityFlag::Sensitive}) {
            ic->setCapabilityFlags(CapabilityFlags{flag});
            type(ic.get(), "mima<sp>");
            // Password 框里字母原样交给应用，Sensitive 框里照常打中文；两种都不算进统计
            check(!ic->committed.empty() || !ic->passed.empty(),
                  "密码框里照常打字：上屏[" + ic->committed + "] 交给应用[" + ic->passed + "]");
            fresh(ic.get());
        }
        ic->setCapabilityFlags(CapabilityFlags{});
        ic->focusOut();
        ic->focusIn();
        const bool written = waitFor([&] { return readStats().find("\"chars\": 2") != std::string::npos; });
        const std::string stats = readStats();
        check(written, "统计打开后失焦写进 stats.json，密码框里打的不算：" + stats.substr(0, 200));
        check(stats.find("你好") == std::string::npos && stats.find("ni") == std::string::npos &&
                  stats.find("mima") == std::string::npos && stats.find("密码") == std::string::npos &&
                  stats.find("lastCommitMs") == std::string::npos,
              "stats.json 里没有打的字、拼音和时刻");
        // 关掉以后打的不再记
        std::filesystem::remove(configDir + "/wowtype.conf");
        addon->reloadConfig();
        fresh(ic.get());
        type(ic.get(), "shijie<sp>");
        ic->focusOut();
        ic->focusIn();
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        check(readStats() == stats, "统计关掉以后不再写");
        std::filesystem::remove(statsFile);
        fresh(ic.get());
    }

    // 换词库（设置里切到万象就是写 Lexicon=）：reloadConfig 后在后台换，换好前按键照常进编辑区
    {
        const std::string dictFile =
            std::string(std::getenv("XDG_DATA_HOME")) + "/wowtype/dicts/harness/lexicon.tsv";
        std::filesystem::create_directories(std::filesystem::path(dictFile).parent_path());
        std::ofstream(dictFile) << "ping guo\t平锅\t1000000\nce shi ci ku\t测试词库\t100\n";
        // 环境变量 WOWTYPE_LEXICON 优先于配置，测配置时先拿掉
        const char *envLexicon = std::getenv("WOWTYPE_LEXICON");
        const std::string savedLexicon = envLexicon ? envLexicon : "";
        unsetenv("WOWTYPE_LEXICON");
        std::ofstream(configDir + "/wowtype.conf") << "Lexicon=" << dictFile << "\nEmojiSuggest=False\n";
        addon->reloadConfig();
        // 等到候选里出现 word（换词库在后台，最多 30 秒）
        const auto waitFor = [&ic](const std::string &keys, const std::string &word) {
            for (int i = 0; i < 300; ++i) {
                fresh(ic.get());
                type(ic.get(), keys);
                const auto shown = page(ic.get());
                if (std::find(shown.begin(), shown.end(), word) != shown.end()) {
                    return true;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }
            return false;
        };
        // 先等再拼说明：参数的求值顺序不定，写在一行里 join 可能先于等待执行
        const bool switched = waitFor("ceshiciku", "测试词库");
        check(switched, "配置换了词库后用上新词库：" + join(page(ic.get())));
        fresh(ic.get());
        // 默认词库里的「苹果」不在了（用户学过的词会跟过来，这里挑一个前面没打过的）
        type(ic.get(), "pingguo<sp>");
        check(ic->committed == "平锅", "新词库里 pingguo -> 平锅，实际 " + ic->committed);
        // 改别的设置不重新载入词库
        std::ofstream(configDir + "/wowtype.conf")
            << "Lexicon=" << dictFile << "\nEmojiSuggest=False\nPageSize=6\n";
        addon->reloadConfig();
        fresh(ic.get());
        type(ic.get(), "ceshiciku<sp>");
        check(ic->committed == "测试词库", "只改别的设置时词库不动，实际 " + ic->committed);
        // 用户词库、输入习惯的文件在、却读不出来：下面重新载入以后，第一次存之前先把原来的改名留成
        // <原名>.bad-<时间戳>，不拿只有这次运行里学到的内容把它盖掉。
        // 夹着坏字节的文件核心现在只跳过坏行、照常读得出来（核心有测试），这里用同名的目录造一个
        // 真读不出来的（root 跑也读不出来，不靠权限位），目录里放个文件，留底以后核对它还在
        const std::filesystem::path userDict = std::getenv("WOWTYPE_USER_DICT");
        const std::filesystem::path historyFile = userDict.parent_path() / "history.tsv";
        const std::string garbage = "ni hao\t你好\t1\n";
        const auto slurp = [](const std::filesystem::path &file) {
            std::ifstream in(file, std::ios::binary);
            return std::string((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        };
        const auto unreadable = [&](const std::filesystem::path &path) {
            // 存盘在后台线程上：上面失去焦点时排的那次可能正好在这时写完，又把文件放回来了。
            // 不抛异常，没换成目录就等一下再来（以前偶尔 create_directories 抛「Not a directory」，整个测试中止）
            for (int i = 0; i < 300; ++i) {
                std::error_code ec;
                std::filesystem::remove_all(path, ec);
                std::filesystem::create_directories(path, ec);
                if (std::filesystem::is_directory(path, ec)) {
                    break;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
            }
            std::ofstream(path / "kept", std::ios::binary) << garbage;
        };
        const auto keptInside = [&](const std::filesystem::path &dir) {
            return std::filesystem::is_directory(dir) && slurp(dir / "kept") == garbage;
        };
        const auto backups = [](const std::filesystem::path &file) {
            std::vector<std::filesystem::path> found;
            const std::string prefix = file.filename().string() + ".bad-";
            std::error_code ec;
            for (const auto &entry : std::filesystem::directory_iterator(file.parent_path(), ec)) {
                if (entry.path().filename().string().rfind(prefix, 0) == 0) {
                    found.push_back(entry.path());
                }
            }
            return found;
        };
        // 攒着的先存掉（失去焦点就存）：重新载入之前就不会再存一次、把下面写的坏文件换掉
        ic->focusOut();
        ic->focusIn();
        unreadable(userDict);
        unreadable(historyFile);
        // 词库文件被换掉（更新了词库包），路径没变：reloadConfig 时也重新载入
        std::ofstream(dictFile) << "ping guo\t平锅\t1000000\nce shi ci ku\t测试词库\t100\n"
                                   "geng xin le\t更新了\t100\n";
        addon->reloadConfig();
        const bool reloaded = waitFor("gengxinle", "更新了");
        check(reloaded, "词库文件更新后重新载入：" + join(page(ic.get())));
        check(keptInside(userDict) && keptInside(historyFile) && backups(userDict).empty() &&
                  backups(historyFile).empty(),
              "读不出来的用户词库、输入习惯：还没到存的时候原样留着");
        for (int round = 1; round <= 2; ++round) {
            // 学到一个词，失去焦点时存。第一次存之前改名留底，第二次不再留
            fresh(ic.get());
            type(ic.get(), "gengxinle<sp>");
            ic->focusOut();
            ic->focusIn();
            const auto dictKept = backups(userDict);
            const auto historyKept = backups(historyFile);
            // 存盘在核心的后台线程上：等新文件写出来，最多 3 秒
            for (int i = 0; i < 300 && !(std::filesystem::is_regular_file(userDict) &&
                                         std::filesystem::is_regular_file(historyFile) &&
                                         slurp(historyFile).find("更新了") != std::string::npos);
                 ++i) {
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
            }
            const std::string dictNow = slurp(userDict);
            const std::string historyNow = slurp(historyFile);
            check(dictKept.size() == 1 && keptInside(dictKept[0]) && historyKept.size() == 1 &&
                      keptInside(historyKept[0]),
                  "读不出来的用户词库、输入习惯存之前改名留成 .bad-<时间戳>，只留一次（第 " +
                      std::to_string(round) + " 次存）：" + std::to_string(dictKept.size()) + " / " +
                      std::to_string(historyKept.size()) + " 份");
            check(!dictNow.empty() && std::filesystem::is_regular_file(userDict) &&
                      historyNow.find("更新了") != std::string::npos &&
                      std::filesystem::is_regular_file(historyFile),
                  "新学到的另存成好的文件（第 " + std::to_string(round) + " 次存）");
        }
        fresh(ic.get());
        // 换回来
        std::filesystem::remove(configDir + "/wowtype.conf");
        if (!savedLexicon.empty()) {
            setenv("WOWTYPE_LEXICON", savedLexicon.c_str(), 1);
        }
        addon->reloadConfig();
        // 刚学过「平锅」，它可能还排在前面；只看默认词库里的「苹果」回来了没有
        const bool restored = waitFor("pingguo", "苹果");
        check(restored, "去掉 Lexicon 后换回默认词库：" + join(page(ic.get())));
        fresh(ic.get());
        std::filesystem::remove_all(std::filesystem::path(dictFile).parent_path());
    }

    ic.reset();
}

/// 互译：Shift 切到「译」，打的中文攒成原文，停一下就发给假的 OpenAI 服务（mock_openai.py），
/// 回车上屏译文。异步：每 50ms 推进一步，每步做完动作后等条件成立（最多 5 秒）。
struct TranslateStep {
    std::string name;
    std::function<void(HarnessInputContext *)> act;
    std::function<bool(HarnessInputContext *)> until;
};

struct TranslateCase {
    Instance &instance;
    std::unique_ptr<HarnessInputContext> ic;
    std::unique_ptr<EventSourceTime> timer;
    std::vector<TranslateStep> steps;
    std::size_t current = 0;
    bool acted = false;
    int waited = 0;
    std::string configFile;
};


std::string aux(HarnessInputContext *ic) { return ic->inputPanel().auxUp().toString(); }
std::string auxDown(HarnessInputContext *ic) { return ic->inputPanel().auxDown().toString(); }
/// 应用输入框里的编辑区（互译时是译文）；候选框里的原文框用 preedit()。
std::string inlineText(HarnessInputContext *ic) { return ic->inputPanel().clientPreedit().toString(); }

void runTranslateCase(Instance &instance, std::function<void()> done) {
    const char *url = std::getenv("WOWTYPE_HARNESS_TRANSLATE_URL");
    if (!url || !*url) {
        std::printf("skip 互译（没有 python3 或 curl）\n");
        done();
        return;
    }
    auto *c = new TranslateCase{instance, std::make_unique<HarnessInputContext>(instance.inputContextManager()),
                                {}, {}};
    const std::string configDir = std::string(std::getenv("XDG_CONFIG_HOME")) + "/fcitx5/conf";
    std::filesystem::create_directories(configDir);
    c->configFile = configDir + "/wowtype.conf";
    std::ofstream(c->configFile) << "Translate=True\nTranslateBaseUrl=" << url
                                 << "\nTranslateModel=mock\nTranslateTarget=en\n";
    auto *addon = instance.addonManager().addon("wowtype");
    addon->reloadConfig();
    // 像大多数应用一样，编辑区画在应用自己的输入框里
    c->ic->setCapabilityFlags(CapabilityFlag::Preedit);
    c->ic->focusIn();
    instance.setCurrentInputMethod(c->ic.get(), "wowtype", true);

    auto expectCommit = [](const std::string &text) {
        return [text](HarnessInputContext *ic) { return ic->committed == text; };
    };
    auto reset = [](HarnessInputContext *ic) {
        type(ic, "<esc>");
        ic->committed.clear();
        ic->passed.clear();
    };
    // 测试不依赖词库给的首选是什么：原文以原文框里显示的为准
    auto source = std::make_shared<std::string>();
    auto &s = c->steps;
    s.push_back({"右 Shift 两下切到「译」，nihao 空格不上屏、攒在原文框里",
                 [](HarnessInputContext *ic) {
                     tapKey(ic, FcitxKey_Shift_R);
                     tapKey(ic, FcitxKey_Shift_R);
                     type(ic, "nihao<sp>");
                 },
                 [](HarnessInputContext *ic) {
                     return ic->committed.empty() && preedit(ic) == "你好" &&
                            aux(ic).find("中→英") != std::string::npos;
                 }});
    s.push_back({"停一下译文就写在输入框里（只有一种，没有候选）", nullptr,
                 [](HarnessInputContext *ic) {
                     return inlineText(ic) == "EN:你好" && page(ic).empty() &&
                            auxDown(ic).find("回车上屏") != std::string::npos;
                 }});
    s.push_back({"回车上屏译文", [](HarnessInputContext *ic) { type(ic, "<cr>"); },
                 [](HarnessInputContext *ic) {
                     return ic->committed == "EN:你好" && preedit(ic).empty() && inlineText(ic).empty();
                 }});
    s.push_back({"互译模式下 v + 空格不开工具栏",
                 [reset](HarnessInputContext *ic) {
                     reset(ic);
                     type(ic, "v<sp>");
                 },
                 [](HarnessInputContext *ic) {
                     return aux(ic).find("工具栏") == std::string::npos &&
                            join(page(ic)).find("剪贴板") == std::string::npos;
                 }});
    s.push_back({"同一句话再打一遍：记住了，马上就有译文",
                 [reset](HarnessInputContext *ic) {
                     reset(ic);
                     type(ic, "nihao<sp>");
                 },
                 [](HarnessInputContext *ic) { return inlineText(ic) == "EN:你好"; }});
    s.push_back({"接着打拼音：原文框里是原文 + 拼音，候选照常，输入框里还是译文",
                 [](HarnessInputContext *ic) { type(ic, "shi"); },
                 [](HarnessInputContext *ic) {
                     return preedit(ic).rfind("你好", 0) == 0 && preedit(ic).find("shi") != std::string::npos &&
                            !page(ic).empty() && inlineText(ic) == "EN:你好" && ic->committed.empty();
                 }});
    s.push_back({"选了词：新译文出来前先留着上一句，不闪",
                 [source](HarnessInputContext *ic) {
                     type(ic, "<sp>");
                     *source = preedit(ic);
                     check(inlineText(ic) == "EN:你好", "互译：选词后输入框里先留着上一句，实际「" +
                                                           inlineText(ic) + "」");
                 },
                 [source](HarnessInputContext *ic) {
                     return source->size() > std::string("你好").size() && inlineText(ic) == "EN:" + *source;
                 }});
    s.push_back({"没译好就按回车：等译好了自动上屏",
                 [reset, source](HarnessInputContext *ic) {
                     reset(ic);
                     type(ic, "zhongguo<sp>");
                     *source = preedit(ic);
                     type(ic, "<cr>");
                     check(ic->committed.empty() && auxDown(ic).find("好了就上屏") != std::string::npos,
                           "互译：先提示「好了就上屏」，实际 " + auxDown(ic));
                 },
                 [source](HarnessInputContext *ic) { return ic->committed == "EN:" + *source; }});
    s.push_back({"Shift+回车上屏原文",
                 [reset](HarnessInputContext *ic) {
                     reset(ic);
                     type(ic, "nihao<sp>");
                     send(ic, Key(FcitxKey_Return, KeyState::Shift));
                 },
                 expectCommit("你好")});
    s.push_back({"Esc 清空原文，不上屏",
                 [reset](HarnessInputContext *ic) {
                     reset(ic);
                     type(ic, "nihao<sp><esc>");
                 },
                 [](HarnessInputContext *ic) {
                     return ic->committed.empty() && preedit(ic).empty() && inlineText(ic).empty() &&
                            page(ic).empty();
                 }});
    // 「译」里选的词进了原文、没有上屏，引擎也学到了：失去焦点时照样存用户词库和输入习惯
    // （以前只在上屏时数，只在「译」里打字的话一条都不存）
    s.push_back({"只在「译」里选了词：失去焦点时也存用户词库",
                 [reset](HarnessInputContext *ic) {
                     reset(ic);
                     // 前面上屏攒着的先存掉（失去焦点就存），再把文件删了：下面只在「译」里选一次词
                     ic->focusOut();
                     ic->focusIn();
                     const std::filesystem::path dict = std::getenv("WOWTYPE_USER_DICT");
                     std::error_code ec;
                     std::filesystem::remove(dict, ec);
                     std::filesystem::remove(dict.parent_path() / "history.tsv", ec);
                     type(ic, "nihao<sp>");
                     check(ic->committed.empty() && preedit(ic) == "你好", "互译：选的词进了原文，没上屏");
                     ic->focusOut();
                     ic->focusIn();
                 },
                 [](HarnessInputContext *ic) {
                     const std::filesystem::path dict = std::getenv("WOWTYPE_USER_DICT");
                     std::ifstream in(dict.parent_path() / "history.tsv");
                     const std::string history((std::istreambuf_iterator<char>(in)),
                                               std::istreambuf_iterator<char>());
                     return ic->committed.empty() && std::filesystem::exists(dict) &&
                            history.find("你好") != std::string::npos;
                 }});
    s.push_back({"数字进原文；打拼音时原文框里带着前面的原文",
                 [reset](HarnessInputContext *ic) {
                     reset(ic);
                     type(ic, "3dian");
                 },
                 [](HarnessInputContext *ic) {
                     return ic->committed.empty() && ic->passed.empty() && preedit(ic).rfind("3", 0) == 0 &&
                            preedit(ic).find("dian") != std::string::npos;
                 }});
    s.push_back({"退格删原文最后一个字", [](HarnessInputContext *ic) { type(ic, "<sp><bs>"); },
                 [](HarnessInputContext *ic) { return preedit(ic) == "3" && ic->committed.empty(); }});
    s.push_back({"服务报错：显示原因，不上屏",
                 [reset](HarnessInputContext *ic) {
                     reset(ic);
                     type(ic, "cuowu<sp>");
                 },
                 [](HarnessInputContext *ic) {
                     return auxDown(ic).find("401") != std::string::npos && ic->committed.empty() &&
                            inlineText(ic).empty();
                 }});
    s.push_back({"出错后回车是重试，还是不上屏", [](HarnessInputContext *ic) { type(ic, "<cr>"); },
                 [](HarnessInputContext *ic) {
                     return auxDown(ic).find("401") != std::string::npos && ic->committed.empty() &&
                            preedit(ic) == "错误";
                 }});
    s.push_back({"应用不让在输入框里画编辑区：译文写在候选框底下",
                 [reset](HarnessInputContext *ic) {
                     reset(ic);
                     ic->setCapabilityFlags(CapabilityFlags{});
                     type(ic, "nihao<sp>");
                 },
                 [](HarnessInputContext *ic) {
                     return preedit(ic) == "你好" && auxDown(ic) == "EN:你好" && inlineText(ic).empty();
                 }});
    s.push_back({"上面那种情况回车也上屏译文", [](HarnessInputContext *ic) { type(ic, "<cr>"); },
                 expectCommit("EN:你好")});
#ifdef WOWTYPE_HAVE_PASSWORD_IM_OPTION
    s.push_back({"密码框里照常打中文，不翻译",
                 [reset, &instance](HarnessInputContext *ic) {
                     reset(ic);
                     // fcitx5 默认在密码框里换成键盘布局，根本轮不到输入法；打开「密码框也用输入法」才测得到
                     RawConfig raw;
                     raw.setValueByPath("Behavior/AllowInputMethodForPassword", "True");
                     instance.globalConfig().load(raw, true);
                     ic->setCapabilityFlags(CapabilityFlags{CapabilityFlag::Password, CapabilityFlag::Preedit});
                     type(ic, "nihao<sp>");
                 },
                 expectCommit("你好")});
#else
    // fcitx5 5.0 没有「密码框也用输入法」：密码框里换成键盘布局，WowType 收不到按键，更不会翻译
    s.push_back({"密码框里不用输入法（fcitx5 没有「密码框也用输入法」）：按键原样交给应用",
                 [reset](HarnessInputContext *ic) {
                     reset(ic);
                     ic->setCapabilityFlags(CapabilityFlags{CapabilityFlag::Password, CapabilityFlag::Preedit});
                     type(ic, "nihao<sp>");
                 },
                 [](HarnessInputContext *ic) {
                     return ic->committed.empty() && ic->passed == "nihao " && preedit(ic).empty();
                 }});
#endif
    s.push_back({"有原文时 Shift 切回中文：原文原样上屏",
                 [reset, &instance](HarnessInputContext *ic) {
                     reset(ic);
                     ic->setCapabilityFlags(CapabilityFlag::Preedit);
                     RawConfig raw;
                     raw.setValueByPath("Behavior/AllowInputMethodForPassword", "False");
                     instance.globalConfig().load(raw, true);
                     type(ic, "nihao<sp>");
                     tapKey(ic, FcitxKey_Shift_R);
                     type(ic, "shijie<sp>");
                 },
                 [](HarnessInputContext *ic) {
                     return ic->committed.rfind("你好", 0) == 0 && ic->committed.size() > std::string("你好").size() &&
                            ic->committed.find("EN:") == std::string::npos;
                 }});
    s.push_back({"打着拼音 Shift 切回中文：原文原样上屏，拼音留着接着打",
                 [reset](HarnessInputContext *ic) {
                     reset(ic);
                     ic->setCapabilityFlags(CapabilityFlag::Preedit);
                     tapKey(ic, FcitxKey_Shift_R); // 中 → 英 → 译
                     tapKey(ic, FcitxKey_Shift_R);
                     type(ic, "nihao<sp>shi");
                     tapKey(ic, FcitxKey_Shift_R);
                 },
                 [](HarnessInputContext *ic) {
                     // 编辑区画在输入框里还是候选框里看 fcitx5 的设置，两处都算
                     return ic->committed == "你好" && (inlineText(ic) + preedit(ic)) == "shi" && !page(ic).empty();
                 }});
    // 另设的切换键（#143）
    auto press = [](HarnessInputContext *ic, Key key) {
        KeyEvent e(ic, key, false);
        const bool handled = ic->keyEvent(e);
        KeyEvent up(ic, key, true);
        ic->keyEvent(up);
        return handled;
    };
    const Key toggleKey(FcitxKey_space, KeyStates{KeyState::Ctrl, KeyState::Shift});
    auto handledFlag = std::make_shared<bool>(false);
    s.push_back({"设了切换键，单按 Shift 照常切到「译」",
                 [c, addon, reset, url](HarnessInputContext *ic) {
                     std::ofstream(c->configFile)
                         << "Translate=True\nTranslateBaseUrl=" << url
                         << "\nTranslateModel=mock\nTranslateTarget=en\nToggleKey=Control+Shift+space\n";
                     addon->reloadConfig();
                     reset(ic);
                     tapKey(ic, FcitxKey_Shift_R);
                     tapKey(ic, FcitxKey_Shift_R);
                     type(ic, "nihao<sp>");
                 },
                 [](HarnessInputContext *ic) { return ic->committed.empty() && preedit(ic) == "你好"; }});
    s.push_back({"在「译」里按切换键：原文原样上屏，回到中文",
                 [press, toggleKey](HarnessInputContext *ic) {
                     check(press(ic, toggleKey), "切换键被接住");
                     type(ic, "nihao<sp>");
                 },
                 expectCommit("你好你好")});
    s.push_back({"切换键：中 → 英，再按回中文",
                 [reset, press, toggleKey](HarnessInputContext *ic) {
                     reset(ic);
                     press(ic, toggleKey);
                     type(ic, "abc");
                     press(ic, toggleKey);
                     type(ic, "nihao<sp>");
                 },
                 [](HarnessInputContext *ic) { return ic->passed == "abc" && ic->committed == "你好"; }});
    s.push_back({"关了 Shift、靠切换键：切到英文，重新读设置也不拉回中文",
                 [c, addon, reset, url, press, toggleKey](HarnessInputContext *ic) {
                     std::ofstream(c->configFile)
                         << "Translate=True\nTranslateBaseUrl=" << url
                         << "\nTranslateModel=mock\nTranslateTarget=en\nShiftToggle=Off\n"
                            "ToggleKey=Control+Shift+space\n";
                     addon->reloadConfig();
                     reset(ic);
                     press(ic, toggleKey);
                     type(ic, "ab");
                     addon->reloadConfig();
                     type(ic, "c");
                     press(ic, toggleKey);
                     type(ic, "nihao<sp>");
                 },
                 [](HarnessInputContext *ic) { return ic->passed == "abc" && ic->committed == "你好"; }});
    s.push_back({"没设切换键：这个键交给应用，还在中文",
                 [c, addon, reset, press, toggleKey, handledFlag](HarnessInputContext *ic) {
                     std::filesystem::remove(c->configFile);
                     addon->reloadConfig();
                     reset(ic);
                     *handledFlag = press(ic, toggleKey);
                     type(ic, "nihao<sp>");
                 },
                 [handledFlag](HarnessInputContext *ic) { return !*handledFlag && ic->committed == "你好"; }});
    // 进出「译」的快捷键（#87）
    const Key translateKey(FcitxKey_Y, KeyStates{KeyState::Ctrl, KeyState::Shift});
    s.push_back({"设了互译键：单按 Shift 只在中英之间切",
                 [c, addon, reset, url](HarnessInputContext *ic) {
                     std::ofstream(c->configFile)
                         << "Translate=True\nTranslateBaseUrl=" << url
                         << "\nTranslateModel=mock\nTranslateTarget=en\nTranslateModeKey=Control+Shift+Y\n";
                     addon->reloadConfig();
                     reset(ic);
                     ic->setCapabilityFlags(CapabilityFlag::Preedit);
                     tapKey(ic, FcitxKey_Shift_R); // 中 → 英
                     tapKey(ic, FcitxKey_Shift_R); // 英 → 中，不进「译」
                     type(ic, "nihao<sp>");
                 },
                 expectCommit("你好")});
    s.push_back({"互译键进「译」：打到一半的拼音带进去接着打",
                 [reset, press, translateKey](HarnessInputContext *ic) {
                     reset(ic);
                     type(ic, "ni");
                     check(press(ic, translateKey), "互译键被接住");
                     type(ic, "hao<sp>");
                 },
                 [](HarnessInputContext *ic) {
                     return ic->committed.empty() && preedit(ic) == "你好" && aux(ic).find("中→英") != std::string::npos;
                 }});
    s.push_back({"在「译」里再按互译键：原文原样上屏，回到中文",
                 [press, translateKey](HarnessInputContext *ic) {
                     press(ic, translateKey);
                     type(ic, "nihao<sp>");
                 },
                 expectCommit("你好你好")});
    s.push_back({"英文里按互译键进「译」，再按回到英文",
                 [reset, press, translateKey](HarnessInputContext *ic) {
                     reset(ic);
                     tapKey(ic, FcitxKey_Shift_R);
                     press(ic, translateKey);
                     press(ic, translateKey);
                     type(ic, "abc");
                 },
                 [](HarnessInputContext *ic) { return ic->passed == "abc" && ic->committed.empty(); }});
    s.push_back({"关了 Shift、只设了互译键：重新读设置时从英文回中文（互译键回不到英文以外），互译键在中和译之间",
                 [c, addon, reset, url, press, translateKey](HarnessInputContext *ic) {
                     // 上一步还在英文
                     std::ofstream(c->configFile)
                         << "Translate=True\nTranslateBaseUrl=" << url
                         << "\nTranslateModel=mock\nTranslateTarget=en\nShiftToggle=Off\nTranslateModeKey=Control+Shift+Y\n";
                     addon->reloadConfig();
                     reset(ic);
                     type(ic, "ni");
                     press(ic, translateKey);
                     type(ic, "hao<sp>");
                     press(ic, translateKey);
                     type(ic, "nihao<sp>");
                 },
                 [](HarnessInputContext *ic) { return ic->passed.empty() && ic->committed == "你好你好"; }});
    s.push_back({"没开互译：互译键交给应用，还在中文",
                 [c, addon, reset, press, translateKey, handledFlag](HarnessInputContext *ic) {
                     std::ofstream(c->configFile) << "TranslateModeKey=Control+Shift+Y\n";
                     addon->reloadConfig();
                     reset(ic);
                     *handledFlag = press(ic, translateKey);
                     type(ic, "nihao<sp>");
                 },
                 [handledFlag](HarnessInputContext *ic) { return !*handledFlag && ic->committed == "你好"; }});
    s.push_back({"关掉互译后 Shift 只在中英之间切",
                 [c, addon, reset](HarnessInputContext *ic) {
                     std::filesystem::remove(c->configFile);
                     addon->reloadConfig();
                     reset(ic);
                     tapKey(ic, FcitxKey_Shift_R);
                     tapKey(ic, FcitxKey_Shift_R);
                     type(ic, "nihao<sp>");
                 },
                 expectCommit("你好")});
    // #253：单按 Shift 等双击，没有第二下、也没再按键时，到时间在插件的定时器里切（事件循环走着才测得到）
    auto label = [c](HarnessInputContext *ic) { return c->instance.inputMethodLabel(ic); };
    auto waitedFrom = std::make_shared<uint64_t>(0);
    auto tappedLabel = std::make_shared<std::string>();
    s.push_back({"#253：单按 Shift 先不切，0.35 秒后定时器里切英文",
                 [addon, reset, label, tappedLabel](HarnessInputContext *ic) {
                     ::unsetenv("WOWTYPE_SHIFT_DOUBLE_TAP");
                     addon->reloadConfig();
                     reset(ic);
                     tapKey(ic, FcitxKey_Shift_R);
                     *tappedLabel = label(ic);
                 },
                 [label, tappedLabel](HarnessInputContext *ic) {
                     return *tappedLabel == "中" && label(ic) == "英";
                 }});
    s.push_back({"#253：双击 Shift 过了间隔也不切",
                 [waitedFrom](HarnessInputContext *ic) {
                     tapKey(ic, FcitxKey_Shift_R);
                     tapKey(ic, FcitxKey_Shift_R);
                     *waitedFrom = now(CLOCK_MONOTONIC);
                 },
                 [label, waitedFrom](HarnessInputContext *ic) {
                     return now(CLOCK_MONOTONIC) - *waitedFrom > 700000 && label(ic) == "英";
                 }});
    s.push_back({"#253：再单按一下，定时器里切回中文",
                 [](HarnessInputContext *ic) { tapKey(ic, FcitxKey_Shift_R); },
                 [label](HarnessInputContext *ic) { return label(ic) == "中"; }});
    // #191：互译只翻一句（TranslateOneShot）。双击判断开着（上面 #253 的几步打开的），单按要等定时器切
    auto oneShotConfig = [c, addon, url](bool on) {
        std::ofstream(c->configFile) << "Translate=True\nTranslateBaseUrl=" << url
                                     << "\nTranslateModel=mock\nTranslateTarget=en\nTranslateOneShot="
                                     << (on ? "True" : "False") << "\n";
        addon->reloadConfig();
    };
    s.push_back({"#191：开着单次互译，双击 Shift 进「译」，打的字攒在原文框里",
                 [reset, oneShotConfig, label, tappedLabel](HarnessInputContext *ic) {
                     oneShotConfig(true);
                     reset(ic);
                     tapKey(ic, FcitxKey_Shift_R);
                     *tappedLabel = label(ic);
                     tapKey(ic, FcitxKey_Shift_R);
                     check(*tappedLabel == "中" && label(ic) == "译",
                           "#191：第一下先等着，第二下进「译」：" + *tappedLabel + " " + label(ic));
                     type(ic, "zhongguo<sp>");
                 },
                 [label](HarnessInputContext *ic) {
                     return ic->committed.empty() && !preedit(ic).empty() && label(ic) == "译" &&
                            aux(ic).find("中→英") != std::string::npos;
                 }});
    s.push_back({"#191：没译好就按回车：译好了自动上屏，定时器里回到中文",
                 [source](HarnessInputContext *ic) {
                     *source = preedit(ic);
                     type(ic, "<cr>");
                 },
                 [source, label](HarnessInputContext *ic) {
                     return ic->committed == "EN:" + *source && label(ic) == "中" && preedit(ic).empty() &&
                            inlineText(ic).empty();
                 }});
    s.push_back({"#191：单次互译开着，单按 Shift 只切中英（先到英文）",
                 [reset](HarnessInputContext *ic) {
                     reset(ic);
                     tapKey(ic, FcitxKey_Shift_R);
                 },
                 [label](HarnessInputContext *ic) { return label(ic) == "英"; }});
    s.push_back({"#191：英文里双击进「译」，等译文出来",
                 [label](HarnessInputContext *ic) {
                     tapKey(ic, FcitxKey_Shift_R);
                     tapKey(ic, FcitxKey_Shift_R);
                     check(label(ic) == "译", "#191：英文里双击进「译」：" + label(ic));
                     type(ic, "nihao<sp>");
                 },
                 [label](HarnessInputContext *ic) { return inlineText(ic) == "EN:你好" && label(ic) == "译"; }});
    s.push_back({"#191：回车上屏译文，回到英文",
                 [](HarnessInputContext *ic) { type(ic, "<cr>"); },
                 [label](HarnessInputContext *ic) {
                     return ic->committed == "EN:你好" && label(ic) == "英" && preedit(ic).empty() &&
                            inlineText(ic).empty();
                 }});
    s.push_back({"#191：Esc 放弃：不上屏，回到英文",
                 [reset, label](HarnessInputContext *ic) {
                     reset(ic);
                     tapKey(ic, FcitxKey_Shift_R);
                     tapKey(ic, FcitxKey_Shift_R);
                     type(ic, "nihao<sp>");
                     check(label(ic) == "译", "#191：又双击进「译」：" + label(ic));
                     type(ic, "<esc>");
                 },
                 [label](HarnessInputContext *ic) {
                     return ic->committed.empty() && label(ic) == "英" && preedit(ic).empty() &&
                            inlineText(ic).empty() && page(ic).empty();
                 }});
    s.push_back({"#191：再单按一下回中文",
                 [](HarnessInputContext *ic) { tapKey(ic, FcitxKey_Shift_R); },
                 [label](HarnessInputContext *ic) { return label(ic) == "中"; }});
    s.push_back({"#191：拼音打到一半双击：拼音带进「译」接着打，什么都不上屏",
                 [label](HarnessInputContext *ic) {
                     type(ic, "ni");
                     tapKey(ic, FcitxKey_Shift_R);
                     tapKey(ic, FcitxKey_Shift_R);
                     check(label(ic) == "译" && ic->committed.empty(), "#191：打到一半双击进「译」：" + label(ic));
                     type(ic, "hao<sp>");
                 },
                 [label](HarnessInputContext *ic) {
                     return ic->committed.empty() && preedit(ic) == "你好" && label(ic) == "译";
                 }});
    s.push_back({"#191：「译」里单按 Shift 放弃：原文原样上屏，回到中文",
                 [](HarnessInputContext *ic) { tapKey(ic, FcitxKey_Shift_R); },
                 [label](HarnessInputContext *ic) { return ic->committed == "你好" && label(ic) == "中"; }});
    s.push_back({"#191：关着单次互译：双击 Shift 照旧不切，过了间隔也不切",
                 [reset, oneShotConfig, waitedFrom](HarnessInputContext *ic) {
                     oneShotConfig(false);
                     reset(ic);
                     tapKey(ic, FcitxKey_Shift_R);
                     tapKey(ic, FcitxKey_Shift_R);
                     *waitedFrom = now(CLOCK_MONOTONIC);
                 },
                 [label, waitedFrom](HarnessInputContext *ic) {
                     return now(CLOCK_MONOTONIC) - *waitedFrom > 700000 && label(ic) == "中";
                 }});
    s.push_back({"#253：测完关掉双击判断（别的用例连按不等）",
                 [addon, reset](HarnessInputContext *ic) {
                     ::setenv("WOWTYPE_SHIFT_DOUBLE_TAP", "0", 1);
                     addon->reloadConfig();
                     reset(ic);
                     type(ic, "nihao<sp>");
                 },
                 expectCommit("你好")});

    c->timer = instance.eventLoop().addTimeEvent(
        CLOCK_MONOTONIC, now(CLOCK_MONOTONIC) + 50000, 1000, [c, done](EventSourceTime *source, uint64_t) {
            auto *ic = c->ic.get();
            if (c->current < c->steps.size()) {
                auto &step = c->steps[c->current];
                if (!c->acted) {
                    c->acted = true;
                    c->waited = 0;
                    if (step.act) {
                        step.act(ic);
                    }
                }
                const bool ok = step.until(ic);
                if (ok || ++c->waited > 100) {
                    check(ok, "互译：" + step.name +
                                  (ok ? ""
                                      : "（上屏「" + ic->committed + "」原文框「" + preedit(ic) + "」输入框「" +
                                            inlineText(ic) + "」提示「" + aux(ic) + "｜" + auxDown(ic) +
                                            "」候选 " + join(page(ic)) + "）"));
                    ++c->current;
                    c->acted = false;
                }
                source->setNextInterval(50000);
                source->setOneShot();
                return true;
            }
            c->ic.reset();
            done();
            dispatcher->schedule([c]() { delete c; });
            return true;
        });
}

/// 外部命令切模式（#98）：经会话总线调 org.wowtype.Input1。addon-test.sh 起了私有总线才跑。
/// 插件的总线和这里的总线挂在同一个事件循环上，所以只能异步调。
struct ModeCall {
    std::string arg; // SetMode 的参数；空表示调 Mode（或下面的 method）
    std::function<void(HarnessInputContext *)> before;
    std::function<void(HarnessInputContext *, const std::string &reply, bool error)> after;
    std::string method = {}; // 不带参数的别的方法（Version）
};

struct ModeCase {
    std::unique_ptr<HarnessInputContext> ic;
    std::unique_ptr<dbus::Bus> bus;
    std::unique_ptr<dbus::Slot> pending;
    std::vector<ModeCall> calls;
    size_t current = 0;
    std::function<void()> done;
};

void nextModeCall(ModeCase *c) {
    if (c->current >= c->calls.size()) {
        c->ic.reset();
        auto done = c->done;
        dispatcher->schedule([c]() { delete c; });
        done();
        return;
    }
    auto &call = c->calls[c->current];
    if (call.before) {
        call.before(c->ic.get());
    }
    const std::string method = !call.method.empty() ? call.method : call.arg.empty() ? "Mode" : "SetMode";
    auto msg = c->bus->createMethodCall("org.wowtype.Input", "/org/wowtype/Input", "org.wowtype.Input1",
                                        method.c_str());
    if (!call.arg.empty()) {
        msg << call.arg;
    }
    c->pending = msg.callAsync(3000000, [c](dbus::Message &reply) {
        std::string text;
        const bool error = reply.isError();
        if (error) {
            text = reply.errorName();
        } else {
            reply >> text;
        }
        c->calls[c->current].after(c->ic.get(), text, error);
        ++c->current;
        dispatcher->schedule([c]() { nextModeCall(c); });
        return true;
    });
}

void runModeCase(Instance &instance, std::function<void()> done) {
    const char *address = std::getenv("DBUS_SESSION_BUS_ADDRESS");
    if (!address || !*address) {
        std::printf("skip 外部命令切模式（没有会话总线）\n");
        done();
        return;
    }
    auto *c = new ModeCase{std::make_unique<HarnessInputContext>(instance.inputContextManager()),
                           std::make_unique<dbus::Bus>(dbus::BusType::Session), {}, {}, 0, done};
    c->bus->attachEventLoop(&instance.eventLoop());
    c->ic->focusIn();
    instance.setCurrentInputMethod(c->ic.get(), "wowtype", true);
    auto expect = [](const std::string &name, const std::string &want) {
        return [name, want](HarnessInputContext *, const std::string &reply, bool error) {
            check(!error && reply == want, "外部命令：" + name + "，回复「" + reply + "」");
        };
    };
    auto &calls = c->calls;
    calls.push_back({"", nullptr, expect("Mode 一开始是 zh", "zh")});
    calls.push_back({"en", [](HarnessInputContext *ic) { fresh(ic); type(ic, "nih"); },
                     [](HarnessInputContext *ic, const std::string &reply, bool error) {
                         check(!error && reply == "en", "外部命令：SetMode en 回复 en：" + reply);
                         check(ic->committed == "nih" && preedit(ic).empty(),
                               "外部命令切英文：打到一半的字母原样上屏：" + ic->committed);
                     }});
    calls.push_back({"", nullptr, [](HarnessInputContext *ic, const std::string &reply, bool error) {
                         check(!error && reply == "en", "外部命令：Mode 是 en：" + reply);
                         fresh(ic);
                         type(ic, "nihao");
                         check(ic->committed.empty() && ic->passed == "nihao",
                               "外部命令切到英文后字母交给应用：" + ic->passed);
                     }});
    calls.push_back({"toggle", nullptr, [](HarnessInputContext *ic, const std::string &reply, bool error) {
                         check(!error && reply == "zh", "外部命令：toggle 从英文切回 zh：" + reply);
                         fresh(ic);
                         type(ic, "nihao<sp>");
                         check(ic->committed == "你好", "外部命令切回中文照常打字：" + ic->committed);
                     }});
    calls.push_back({"toggle", nullptr, expect("toggle 从中文切到 en", "en")});
    calls.push_back({"zh", nullptr, expect("SetMode zh", "zh")});
    calls.push_back({"zh", nullptr, expect("已经是中文再切 zh 不变", "zh")});
    calls.push_back({"bogus", nullptr, [](HarnessInputContext *, const std::string &reply, bool error) {
                         check(error && reply == "org.freedesktop.DBus.Error.InvalidArgs",
                               "外部命令：不认识的模式报错：" + reply);
                     }});
    calls.push_back({"translate", nullptr, [](HarnessInputContext *, const std::string &reply, bool error) {
                         check(error, "外部命令：没配翻译服务时切不到 translate：" + reply);
                     }});
    calls.push_back({"", [](HarnessInputContext *ic) { fresh(ic); }, expect("报错以后模式不变", "zh")});
    // 设置界面拿它和装好的版本比，判断升级后要不要重启输入法
    calls.push_back({"", nullptr, expect("Version 是插件的版本", WOWTYPE_ADDON_VERSION), "Version"});
    nextModeCall(c);
}

/// 语音：按住右 Alt 说话（WOWTYPE_VOICE_WAV 代替麦克风），松开后等识别结果上屏。
/// 要真模型，所以只在 addon-test.sh 带了 WOWTYPE_VOICE_WAV 时跑。异步：靠事件循环里的定时器推进。
struct VoiceCase {
    Instance &instance;
    std::unique_ptr<HarnessInputContext> ic;
    std::unique_ptr<EventSourceTime> timer;
    std::string expect;
    int ticks = 0;
    bool released = false;
};

void runVoiceCase(Instance &instance, std::function<void()> done) {
    const char *wav = std::getenv("WOWTYPE_VOICE_WAV");
    if (!wav || !*wav) {
        std::printf("skip 语音（没给 WOWTYPE_VOICE_WAV）\n");
        done();
        return;
    }
    auto *c = new VoiceCase{instance, std::make_unique<HarnessInputContext>(instance.inputContextManager()), {}, {}};
    if (const char *expect = std::getenv("WOWTYPE_VOICE_EXPECT")) {
        c->expect = expect;
    }
    c->ic->focusIn();
    instance.setCurrentInputMethod(c->ic.get(), "wowtype", true);
    KeyEvent press(c->ic.get(), Key(FcitxKey_Alt_R), false);
    check(c->ic->keyEvent(press), "语音：按下右 Alt 被输入法接住");
    check(c->ic->inputPanel().auxUp().toString().find("🎙") != std::string::npos,
          "语音：显示麦克风图标，实际 " + c->ic->inputPanel().auxUp().toString());
    c->timer = instance.eventLoop().addTimeEvent(
        CLOCK_MONOTONIC, now(CLOCK_MONOTONIC) + 100000, 0,
        [c, done](EventSourceTime *source, uint64_t) {
            ++c->ticks;
            // 按住 1 秒后松开（长按：松开即结束）
            if (!c->released && c->ticks >= 10) {
                c->released = true;
                KeyEvent release(c->ic.get(), Key(FcitxKey_Alt_R, KeyState::Alt), true);
                check(c->ic->keyEvent(release), "语音：松开右 Alt 也被接住");
            }
            const bool finished = !c->ic->committed.empty() || c->ticks > 600;
            if (!finished) {
                source->setNextInterval(100000);
                source->setOneShot();
                return true;
            }
            std::printf("语音上屏：%s（%.1f 秒）\n", c->ic->committed.c_str(), c->ticks / 10.0);
            check(!c->ic->committed.empty(), "语音：识别结果上屏");
            if (!c->expect.empty()) {
                check(c->ic->committed.find(c->expect) != std::string::npos,
                      "语音：结果里有「" + c->expect + "」");
            }
            check(c->ic->inputPanel().auxUp().empty(), "语音：上屏后提示消失");
            c->ic.reset();
            done();
            // 定时器自己的回调里不能删定时器，交给下一轮事件循环
            dispatcher->schedule([c]() { delete c; });
            return true;
        });
}

/// 语音取消：按时间表（每格 0.1 秒）发按键、失焦，最后检查没有东西上屏。
/// 识别是异步的，取消之后还要再等几秒，确认迟到的结果被丢掉、不会上屏。
struct VoiceScript {
    Instance &instance;
    std::string name;
    std::unique_ptr<HarnessInputContext> ic;
    std::unique_ptr<EventSourceTime> timer;
    std::vector<std::pair<int, std::function<void(VoiceScript &)>>> steps;
    size_t next = 0;
    int ticks = 0;
};

void runVoiceScript(Instance &instance, std::string name,
                    std::vector<std::pair<int, std::function<void(VoiceScript &)>>> steps,
                    std::function<void()> done) {
    auto *s = new VoiceScript{instance, std::move(name),
                              std::make_unique<HarnessInputContext>(instance.inputContextManager()),
                              {}, std::move(steps)};
    s->ic->focusIn();
    instance.setCurrentInputMethod(s->ic.get(), "wowtype", true);
    s->timer = instance.eventLoop().addTimeEvent(
        CLOCK_MONOTONIC, now(CLOCK_MONOTONIC) + 100000, 0,
        [s, done](EventSourceTime *source, uint64_t) {
            ++s->ticks;
            while (s->next < s->steps.size() && s->steps[s->next].first <= s->ticks) {
                s->steps[s->next].second(*s);
                ++s->next;
            }
            if (s->next < s->steps.size()) {
                source->setNextInterval(100000);
                source->setOneShot();
                return true;
            }
            s->ic.reset();
            done();
            dispatcher->schedule([s]() { delete s; });
            return true;
        });
}

/// 没下载语音模型时按语音键：只提示去设置里下载，不录音、不下载，松开后提示一会儿自己消失。
/// 给了 WOWTYPE_VOICE_WAV 时有模型，跳过。
void runVoiceNoModelCase(Instance &instance, std::function<void()> done) {
    const char *wav = std::getenv("WOWTYPE_VOICE_WAV");
    const char *dirEnv = std::getenv("WOWTYPE_VOICE_MODEL_DIR");
    if ((wav && *wav) || !dirEnv || !*dirEnv) {
        std::printf("skip 语音·没有模型（给了 WOWTYPE_VOICE_WAV，或没指定模型目录）\n");
        done();
        return;
    }
    const std::filesystem::path dir = dirEnv;
    const auto parent = dir.parent_path();
    // 模型目录旁边有没有下载留下的东西（wtlocal、wtlocal.apk、wtlocal.apk.part、wtlocal.part、wtlocal.tmp）
    auto listing = [parent]() {
        std::string names;
        std::error_code ec;
        for (const auto &entry : std::filesystem::directory_iterator(parent, ec)) {
            const std::string name = entry.path().filename().string();
            if (name.rfind("wtlocal", 0) == 0) {
                names += name + " ";
            }
        }
        return names;
    };
    const std::string before = listing();
    using Steps = std::vector<std::pair<int, std::function<void(VoiceScript &)>>>;
    Steps steps{
        {1,
         [](VoiceScript &s) {
             KeyEvent e(s.ic.get(), Key(FcitxKey_Alt_R), false);
             check(s.ic->keyEvent(e), s.name + "：按下右 Alt 被输入法接住");
             const std::string aux = s.ic->inputPanel().auxUp().toString();
             check(aux.find("设置") != std::string::npos && aux.find("下载") != std::string::npos,
                   s.name + "：提示去设置里下载模型，实际 " + aux);
         }},
        {5,
         [](VoiceScript &s) {
             KeyEvent e(s.ic.get(), Key(FcitxKey_Alt_R, KeyState::Alt), true);
             check(s.ic->keyEvent(e), s.name + "：松开右 Alt 也被接住");
         }},
        {10,
         [](VoiceScript &s) {
             check(s.ic->inputPanel().auxUp().toString().find("设置") != std::string::npos,
                   s.name + "：松开后提示还留着，实际 " + s.ic->inputPanel().auxUp().toString());
         }},
        {50,
         [dir, before, listing](VoiceScript &s) {
             check(s.ic->inputPanel().auxUp().empty(),
                   s.name + "：几秒后提示消失，实际 " + s.ic->inputPanel().auxUp().toString());
             check(s.ic->committed.empty(), s.name + "：什么也不上屏，实际 " + s.ic->committed);
             check(!std::filesystem::exists(dir) && before.empty() && listing().empty(),
                   s.name + "：没有开始下载，实际有 " + listing());
             // 提示之后照常打字
             type(s.ic.get(), "nihao<sp>");
             check(!s.ic->committed.empty(), s.name + "：之后照常打字，实际 " + s.ic->committed);
         }},
        {52,
         [](VoiceScript &s) {
             // 提示中途按别的键：提示收起，键照常处理
             KeyEvent e(s.ic.get(), Key(FcitxKey_Alt_R), false);
             s.ic->keyEvent(e);
             KeyEvent up(s.ic.get(), Key(FcitxKey_Alt_R, KeyState::Alt), true);
             s.ic->keyEvent(up);
             s.ic->committed.clear();
             type(s.ic.get(), "ni");
             check(s.ic->inputPanel().auxUp().toString().find("设置") == std::string::npos,
                   s.name + "：打字时提示收起，实际 " + s.ic->inputPanel().auxUp().toString());
             type(s.ic.get(), "<esc>");
             std::printf("语音·没有模型：只提示去设置里下载，没有下载\n");
         }},
        {54,
         [](VoiceScript &s) {
             // 按住语音键时焦点切走：松开的那一下到不了输入法。回来后第一次按语音键照样有反应
             // （以前被当成还按着时的自动重复吃掉）
             KeyEvent down(s.ic.get(), Key(FcitxKey_Alt_R), false);
             s.ic->keyEvent(down);
             s.ic->focusOut();
             s.ic->focusIn();
             check(s.ic->inputPanel().auxUp().empty(),
                   s.name + "：按住语音键时失去焦点，提示收起，实际 " + s.ic->inputPanel().auxUp().toString());
             KeyEvent again(s.ic.get(), Key(FcitxKey_Alt_R), false);
             const bool took = s.ic->keyEvent(again);
             const std::string aux = s.ic->inputPanel().auxUp().toString();
             check(took && aux.find("设置") != std::string::npos,
                   s.name + "：按住语音键时切走焦点，回来后第一次按照样有反应，实际 " + aux);
             KeyEvent up(s.ic.get(), Key(FcitxKey_Alt_R, KeyState::Alt), true);
             check(s.ic->keyEvent(up), s.name + "：这次松开也被接住");
             type(s.ic.get(), "ni<esc>");
         }},
    };
    runVoiceScript(instance, "语音·没有模型", steps, done);
}

/// 语音浮条的回执（#170）：在会话总线上假装是 GNOME 扩展，收插件发的 State。
/// 先每个都回 Ack：提示交给浮条，候选框里没有字；再不回了：等 0.8 秒后插件改在候选框里提示。
/// 走「没有模型」那条路（按语音键只提示去下载），不用真的录音。
struct FakeOverlay {
    std::unique_ptr<dbus::Bus> bus;
    std::unique_ptr<dbus::Slot> match;
    bool ack = true;
    int states = 0;
};

void runVoiceOverlayCase(Instance &instance, std::function<void()> done) {
    const char *address = std::getenv("DBUS_SESSION_BUS_ADDRESS");
    const char *wav = std::getenv("WOWTYPE_VOICE_WAV");
    const char *dirEnv = std::getenv("WOWTYPE_VOICE_MODEL_DIR");
    if (!address || !*address || (wav && *wav) || !dirEnv || !*dirEnv) {
        std::printf("skip 语音浮条回执（没有会话总线，或有语音模型）\n");
        done();
        return;
    }
    static constexpr char kService[] = "io.github.gloridust.WowType.VoiceOverlay";
    static constexpr char kPath[] = "/io/github/gloridust/WowType";
    static constexpr char kInterface[] = "io.github.gloridust.WowType.Voice1";
    auto overlay = std::make_shared<FakeOverlay>();
    overlay->bus = std::make_unique<dbus::Bus>(dbus::BusType::Session);
    overlay->bus->attachEventLoop(&instance.eventLoop());
    FakeOverlay *o = overlay.get();
    overlay->match = overlay->bus->addMatch(
        dbus::MatchRule("", kPath, kInterface, "State"), [o](dbus::Message &msg) {
            uint32_t state = 0;
            msg >> state;
            ++o->states;
            if (o->ack) {
                auto reply = o->bus->createSignal(kPath, kInterface, "Ack");
                reply.setDestination(msg.sender());
                reply << state;
                reply.send();
            }
            return true;
        });
    check(overlay->bus->requestName(kService, Flags<dbus::RequestNameFlag>{}), "语音浮条：假扩展占上名字");

    auto aux = [](VoiceScript &s) { return s.ic->inputPanel().auxUp().toString(); };
    auto press = [](VoiceScript &s) {
        KeyEvent e(s.ic.get(), Key(FcitxKey_Alt_R), false);
        check(s.ic->keyEvent(e), s.name + "：按下右 Alt 被输入法接住");
    };
    auto release = [](VoiceScript &s) {
        KeyEvent e(s.ic.get(), Key(FcitxKey_Alt_R, KeyState::Alt), true);
        s.ic->keyEvent(e);
    };
    using Steps = std::vector<std::pair<int, std::function<void(VoiceScript &)>>>;
    Steps steps{
        // 等插件看到扩展上线
        {3, press},
        {4, [aux](VoiceScript &s) {
             check(aux(s).empty(), s.name + "：有浮条时候选框里不写提示，实际 " + aux(s));
         }},
        {5, release},
        {15, [aux, overlay](VoiceScript &s) {
             check(overlay->states > 0, s.name + "：浮条收到了状态");
             check(aux(s).empty(), s.name + "：浮条回了执，1 秒后候选框里还是没字，实际 " + aux(s));
         }},
        // 提示 4 秒后收起；扩展「坏了」：不再回执
        {60, [overlay](VoiceScript &) { overlay->ack = false; }},
        {62, press},
        {63, [aux](VoiceScript &s) {
             check(aux(s).empty(), s.name + "：刚按下时还在等浮条，实际 " + aux(s));
         }},
        {64, release},
        {75, [aux](VoiceScript &s) {
             check(aux(s).find("设置") != std::string::npos,
                   s.name + "：等不到回执，改在候选框里提示，实际 " + aux(s));
         }},
        // 提示收起后扩展下线，后面的用例照常用候选框
        {120, [overlay](VoiceScript &) {
             overlay->match.reset();
             overlay->bus.reset();
         }},
        {125, [](VoiceScript &s) {
             check(s.ic->committed.empty(), s.name + "：什么也不上屏，实际 " + s.ic->committed);
             std::printf("语音浮条：回执了就交给浮条，等不到回执就退回候选框\n");
         }},
    };
    runVoiceScript(instance, "语音浮条回执", steps, done);
}

void runVoiceCancelCases(Instance &instance, std::function<void()> done) {
    const char *wav = std::getenv("WOWTYPE_VOICE_WAV");
    if (!wav || !*wav) {
        std::printf("skip 语音取消（没给 WOWTYPE_VOICE_WAV）\n");
        done();
        return;
    }
    using Steps = std::vector<std::pair<int, std::function<void(VoiceScript &)>>>;
    auto press = [](VoiceScript &s) {
        KeyEvent e(s.ic.get(), Key(FcitxKey_Alt_R), false);
        check(s.ic->keyEvent(e), s.name + "：按下右 Alt 开始录音");
    };
    auto release = [](VoiceScript &s) {
        KeyEvent e(s.ic.get(), Key(FcitxKey_Alt_R, KeyState::Alt), true);
        s.ic->keyEvent(e);
    };
    auto esc = [](VoiceScript &s) {
        KeyEvent e(s.ic.get(), Key(FcitxKey_Escape), false);
        check(s.ic->keyEvent(e), s.name + "：Esc 被输入法接住，不交给应用");
        check(s.ic->inputPanel().auxUp().empty(),
              s.name + "：Esc 后麦克风提示消失，实际 " + s.ic->inputPanel().auxUp().toString());
    };
    // 取消后等 6 秒：比正常识别出结果的时间长，结果要是没丢就会在这期间上屏
    auto nothingCommitted = [](VoiceScript &s) {
        check(s.ic->committed.empty(), s.name + "：取消后迟到的识别结果不上屏，实际 " + s.ic->committed);
        check(s.ic->inputPanel().auxUp().empty(), s.name + "：提示没有残留");
    };

    // 1. 按住说话时按 Esc：放弃录音；之后松开热键也不再开始识别
    Steps escWhileRecording{{1, press}, {8, esc}, {10, release}, {70, nothingCommitted}};
    // 2. 松开热键（开始识别）后、结果出来前按 Esc
    Steps escWhileRecognizing{{1, press}, {10, release}, {11, esc}, {71, nothingCommitted}};
    // 3. 识别中输入框失去焦点：取消；焦点回来也不补上屏
    Steps focusOut{{1, press},
                   {10, release},
                   {11, [](VoiceScript &s) { s.ic->focusOut(); }},
                   {70, [](VoiceScript &s) { s.ic->focusIn(); }},
                   {72, nothingCommitted}};
    // 4. 打完一句后能正常再开始：取消不会把语音卡在「忙」的状态
    Steps afterCancel{{1, press},
                      {3, [](VoiceScript &s) {
                           check(s.ic->inputPanel().auxUp().toString().find("🎙") != std::string::npos,
                                 s.name + "：取消过之后还能再开始录音");
                       }},
                      {4, [](VoiceScript &s) {
                           KeyEvent e(s.ic.get(), Key(FcitxKey_Escape), false);
                           s.ic->keyEvent(e);
                       }},
                      {5, release}};

    runVoiceScript(instance, "语音取消·录音中 Esc", escWhileRecording, [&instance, done, escWhileRecognizing,
                                                                         focusOut, afterCancel]() {
        runVoiceScript(instance, "语音取消·识别中 Esc", escWhileRecognizing, [&instance, done, focusOut,
                                                                              afterCancel]() {
            runVoiceScript(instance, "语音取消·识别中失焦", focusOut, [&instance, done, afterCancel]() {
                runVoiceScript(instance, "语音取消·之后再开始", afterCancel, done);
            });
        });
    });
}

/// 语音结果复制到剪贴板：用假的 wl-copy（把标准输入写进文件）代替真的剪贴板。
/// 用户目录里老版本拷进来的自带词库让给安装包带的新版；用户自己的照旧优先。
void runDataFileCase() {
    namespace fs = std::filesystem;
    const fs::path root = fs::temp_directory_path() / ("wowtype-data-" + std::to_string(::getpid()));
    fs::remove_all(root);
    fs::create_directories(root / "user");
    fs::create_directories(root / "system");
    const auto write = [](const fs::path &path, const std::string &text, int daysAgo) {
        std::ofstream(path, std::ios::binary) << text;
        fs::last_write_time(path, fs::file_time_type::clock::now() - std::chrono::hours(24 * daysAgo));
    };
    const std::string stock = "# 由 tools/rime2tsv.py 生成，来源：rime_ice.dict.yaml\nni hao\t你好\t1\n";
    const fs::path user = root / "user" / "lexicon.tsv";
    const fs::path system = root / "system" / "lexicon.tsv";
    write(system, stock, 2);
    write(user, stock, 7);
    check(wowtype::isStaleBundledCopy(user, system, "lexicon.tsv"),
          "用户目录里比安装包旧的自带词库是旧副本，让给安装包的");
    write(user, stock, 0);
    check(!wowtype::isStaleBundledCopy(user, system, "lexicon.tsv"),
          "自己重新生成、比安装包新的自带词库照旧优先");
    write(user, "ni hao\t你好\t1\n", 7);
    check(!wowtype::isStaleBundledCopy(user, system, "lexicon.tsv"), "自己做的词库（没有生成标记）照旧优先");
    write(user, stock, 7);
    fs::remove(system);
    check(!wowtype::isStaleBundledCopy(user, system, "lexicon.tsv"), "系统目录没有时用用户目录的");
    write(system, stock, 2);
    // 可复现构建把系统目录的时间戳设成 1970 年：看不出新旧，也让给安装包
    write(user, stock, 0);
    fs::last_write_time(system, fs::file_time_type::clock::now() - std::chrono::hours(24 * 365 * 40));
    check(wowtype::isStaleBundledCopy(user, system, "lexicon.tsv"), "系统目录时间戳是 1970 年时也算旧副本");
    write(root / "user" / "english.txt", "# Rime dictionary\nhello\n", 7);
    write(root / "system" / "english.txt", "# Rime dictionary\nhello\nworld\n", 2);
    check(wowtype::isStaleBundledCopy(root / "user" / "english.txt", root / "system" / "english.txt",
                                      "english.txt"),
          "英文词表同样处理");
    write(root / "user" / "words.lm", "lm", 7);
    write(root / "system" / "words.lm", "lm2", 2);
    check(!wowtype::isStaleBundledCopy(root / "user" / "words.lm", root / "system" / "words.lm", "words.lm"),
          "words.lm 可能是自己训的，不动");
    // 字节数和官方发布的一样的 words.lm 是拷进来的官方模型（稀疏文件，不占盘）
    std::filesystem::resize_file(root / "user" / "words.lm", wowtype::kOfficialLmSizes[0]);
    check(wowtype::isStaleBundledCopy(root / "user" / "words.lm", root / "system" / "words.lm", "words.lm"),
          "拷进来的官方 words.lm 让给安装包的");
    write(root / "user" / "wubi86.tsv", "a\t工\t99454797\naa\t式\t1\n", 7);
    write(root / "system" / "wubi86.tsv", "a\t工\t99454797\naa\t式\t2\n", 2);
    check(wowtype::isStaleBundledCopy(root / "user" / "wubi86.tsv", root / "system" / "wubi86.tsv",
                                      "wubi86.tsv"),
          "拷进来的五笔码表同样处理");
    write(root / "user" / "wubi86.tsv", "a\t工\t5\n", 7);
    check(!wowtype::isStaleBundledCopy(root / "user" / "wubi86.tsv", root / "system" / "wubi86.tsv",
                                       "wubi86.tsv"),
          "自己做的五笔码表照旧优先");

    // 版本标记（docs/DATA.md「数据版本标记」）
    check(wowtype::compareDataVersions("2026.11.9", "2026.11.10") < 0 &&
              wowtype::compareDataVersions("2026.11.14", "2026.11.14.0") == 0 &&
              wowtype::compareDataVersions("2026.11.09", "2026.11.9") == 0 &&
              wowtype::compareDataVersions("2026.11.14.1", "2026.11.14") > 0,
          "数据版本逐段按数字比，缺的段算 0");
    {
        const auto m = wowtype::parseDataMarker("# wowtype-data: lexicon.tsv 2026.11.14.5 rime-ice abc (2026-11-14)\n");
        check(m && m->name == "lexicon.tsv" && m->version == "2026.11.14.5" &&
                  m->source == "rime-ice abc (2026-11-14)",
              "读出标记的名字、版本、来源");
        check(!wowtype::parseDataMarker("# wowtype-data: lexicon.tsv 2026-11-14.5") &&
                  !wowtype::parseDataMarker("# wowtype-data: lexicon.tsv") &&
                  !wowtype::parseDataMarker("# wowtype-data:lexicon.tsv 1"),
              "版本不是点分隔的数字、缺版本的标记不算");
        std::string far(wowtype::kDataMarkerScanBytes, 'x');
        far += "\n# wowtype-data: lexicon.tsv 1\n";
        check(!wowtype::scanDataMarker(far), "4096 字节以后的标记不算");
    }
    const auto marked = [](const std::string &name, const std::string &version, const std::string &rest) {
        return "# 由 tools/rime2tsv.py 生成，来源：rime_ice.dict.yaml\n# wowtype-data: " + name + " " + version +
               " rime-ice\n" + rest;
    };
    const auto stale = [&root](const char *name) {
        return wowtype::isStaleBundledCopy(root / "user" / name, root / "system" / name, name);
    };
    write(system, marked("lexicon.tsv", "2026.11.20.0", "ni hao\t你好\t2\n"), 2);
    write(user, marked("lexicon.tsv", "2026.11.14.5", "ni hao\t你好\t1\n"), 0);
    check(stale("lexicon.tsv"), "带标记、版本比安装包旧的是旧副本（不看修改时间）");
    write(user, marked("lexicon.tsv", "2026.11.20.0", "ni hao\t你好\t1\n"), 0);
    check(stale("lexicon.tsv"), "带标记、版本和安装包一样的也是旧副本");
    write(user, marked("lexicon.tsv", "2026.11.20.1", "ni hao\t你好\t1\n"), 30);
    check(!stale("lexicon.tsv"), "带标记、版本比安装包新的是自己更新的，照旧优先（不看修改时间）");
    write(user, marked("lexicon-wanxiang", "2026.12.01.0", "ni hao\t你好\t1\n"), 30);
    check(!stale("lexicon.tsv"), "标记名字和文件名不一样（别的词库）照旧优先");
    write(user, stock, 7);
    check(stale("lexicon.tsv"), "没有标记的老自带词库，安装包带标记时照老办法认出旧副本");
    write(system, stock, 2);
    write(user, marked("lexicon.tsv", "2026.11.14.5", "ni hao\t你好\t1\n"), 7);
    check(!stale("lexicon.tsv"), "带标记、安装包那份没有标记（老安装包）时用用户目录的");
    check(wowtype::dataFileVersion(user, "lexicon.tsv") == "2026.11.14.5" &&
              wowtype::dataFileVersion(system, "lexicon.tsv").empty(),
          "数据文件的版本：带标记的读标记，没有的是空");
    write(root / "system" / "wubi86.tsv", "# wowtype-data: wubi86.tsv 2023.10.25.1 rime-wubi\na\t工\t99454797\n", 2);
    write(root / "user" / "wubi86.tsv", "# wowtype-data: wubi86.tsv 2023.10.25.0 rime-wubi\na\t工\t99454797\n", 0);
    check(stale("wubi86.tsv"), "五笔码表按版本认旧副本");
    write(root / "system" / "english.txt", "# Rime dictionary\n# wowtype-data: english.txt 2026.11.20.0 x\nhello\n", 2);
    write(root / "user" / "english.txt", "# Rime dictionary\nhello\n", 0);
    check(!stale("english.txt"), "没有标记的英文词表比安装包新：照老办法，用户目录的优先");

    // words.lm：词表 1 号词是标记（WTLM 版本 1，<s> 和标记两个词，没有搭配）
    const auto wtlm = [](const std::string &marker) {
        std::string out = "WTLM";
        const auto u32 = [&out](std::uint32_t v) {
            for (int i = 0; i < 4; ++i) {
                out.push_back(static_cast<char>((v >> (8 * i)) & 0xff));
            }
        };
        u32(1);
        u32(2);
        u32(0);
        out += "\x03<s>";
        out.push_back(static_cast<char>(marker.size()));
        out += marker;
        for (int i = 0; i < 2 + 3; ++i) {
            u32(0); // 两个回退分 + 三个起点
        }
        return out;
    };
    write(root / "system" / "words.lm", wtlm("wowtype-data: words.lm 2026.11.20.0 lm-2026.11.20"), 2);
    write(root / "user" / "words.lm", wtlm("wowtype-data: words.lm 2026.11.20.0 lm-2026.11.20"), 0);
    check(wowtype::dataFileVersion(root / "user" / "words.lm", "words.lm") == "2026.11.20.0",
          "words.lm 词表里的标记读得出来");
    check(stale("words.lm"), "和安装包同一版的 words.lm 是旧副本");
    write(root / "user" / "words.lm", wtlm("wowtype-data: words.lm 2026.12.01.0 自己训的"), 7);
    check(!stale("words.lm"), "版本比安装包新的 words.lm 照旧优先");
    write(root / "user" / "words.lm", "lm", 7);
    std::filesystem::resize_file(root / "user" / "words.lm", wowtype::kOfficialLmSizes[0]);
    check(wowtype::dataFileVersion(root / "user" / "words.lm", "words.lm") == "2026.11.09",
          "没有标记的 lm-2026.11.09 按字节数认出版本");
    check(stale("words.lm"), "拷进来的老官方 words.lm 让给带标记的新版");
    write(root / "system" / "words.lm", "lm2", 2);
    std::filesystem::resize_file(root / "system" / "words.lm", wowtype::kOfficialLmSizes[0]);
    write(root / "user" / "words.lm", wtlm("wowtype-data: words.lm 2026.11.20.0 lm-2026.11.20"), 7);
    check(!stale("words.lm"), "自己下的新版 words.lm 比安装包带的 lm-2026.11.09 新，照旧优先");
    write(root / "user" / "words.lm", wtlm("wowtype-data: words.lm 2026.11.01.0 更早的"), 7);
    check(stale("words.lm"), "带标记但比安装包的 lm-2026.11.09 旧的 words.lm 是旧副本");

    // nnlm.bin（WowType 自己的字级神经语言模型，WTNN）：前 4096 字节里一串以 \0 结束的标记
    const auto wtnn = [](const std::string &marker) {
        return std::string("WTNN\x01\0\0\0", 8) + marker + std::string(1, '\0') + std::string(64, '\xff');
    };
    write(root / "system" / "nnlm.bin", wtnn("wowtype-data: nnlm.bin 2026.11.20.0 nnlm-2026.11.20"), 2);
    write(root / "user" / "nnlm.bin", wtnn("wowtype-data: nnlm.bin 2026.11.19.0 nnlm-2026.11.19"), 0);
    check(stale("nnlm.bin"), "nnlm.bin 同样按版本认旧副本");
    write(root / "user" / "nnlm.bin", std::string("WTNN\x01\0\0\0", 8) + std::string(64, '\xff'), 7);
    check(!stale("nnlm.bin"), "没有标记的 nnlm.bin（自己训的）照旧优先");
    fs::remove_all(root);
}

void runClipboardCase() {
    const auto dir = std::filesystem::temp_directory_path() /
                     ("wowtype-clip-" + std::to_string(::getpid()));
    std::filesystem::create_directories(dir);
    const auto out = dir / "copied.txt";
    {
        std::ofstream script(dir / "wl-copy");
        script << "#!/bin/sh\ncat > \"" << out.string() << ".tmp\" && mv \"" << out.string()
               << ".tmp\" \"" << out.string() << "\"\n";
    }
    std::filesystem::permissions(dir / "wl-copy", std::filesystem::perms::owner_all);
    const std::string oldPath = std::getenv("PATH") ? std::getenv("PATH") : "";
    const char *oldWayland = std::getenv("WAYLAND_DISPLAY");
    const std::string savedWayland = oldWayland ? oldWayland : "";
    ::setenv("PATH", (dir.string() + ":" + oldPath).c_str(), 1);
    ::setenv("WAYLAND_DISPLAY", "wayland-test", 1);

    const std::string text = "语音结果 \"$HOME\" `id`\n第二行";
    const bool started = wowtype::copyToClipboard(text);
    std::string copied;
    for (int i = 0; i < 100 && copied.empty(); ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        std::ifstream in(out);
        copied.assign(std::istreambuf_iterator<char>(in), {});
    }
    check(started && copied == text, "语音结果复制到剪贴板（原样，不经 shell 展开）：" + copied);
    check(!wowtype::copyToClipboard(""), "空的不复制");
    check(!wowtype::copyToClipboard(std::string(40 * 1024, 'a')), "太长的不复制");

    ::setenv("PATH", oldPath.c_str(), 1);
    if (oldWayland) {
        ::setenv("WAYLAND_DISPLAY", savedWayland.c_str(), 1);
    } else {
        ::unsetenv("WAYLAND_DISPLAY");
    }
    std::filesystem::remove_all(dir);
}

} // namespace

int main(int argc, char **argv) {
    (void)argc;
    (void)argv;
    char arg0[] = "wowtype-key-harness";
    char arg1[] = "--disable=all";
    char arg2[] = "--enable=wowtype,testim,clipboard";
    char *args[] = {arg0, arg1, arg2};
    // 双击 Shift 不切换（#253）要等 0.35 秒才切：大多数用例连按 Shift、按完马上看模式，关着测；
    // runCases 和互译用例里各有一段开着测
    ::setenv("WOWTYPE_SHIFT_DOUBLE_TAP", "0", 1);
    Instance instance(3, args);
    FakeClipboardFactory clipboardFactory;
    StaticAddonRegistry registry{{"clipboard", &clipboardFactory}};
    instance.addonManager().registerDefaultLoader(
        std::getenv("WOWTYPE_HARNESS_REAL_CLIPBOARD") ? nullptr : &registry);
    EventDispatcher mainDispatcher;
    mainDispatcher.attach(&instance.eventLoop());
    dispatcher = &mainDispatcher;
    mainDispatcher.schedule([&instance]() {
        runCases(instance);
        runDataFileCase();
        runClipboardCase();
        runModeCase(instance, [&instance]() {
        runTranslateCase(instance, [&instance]() {
            runVoiceNoModelCase(instance, [&instance]() {
            runVoiceOverlayCase(instance, [&instance]() {
                runVoiceCase(instance, [&instance]() {
                    runVoiceCancelCases(instance, [&instance]() {
                        std::printf(failures ? "KEY HARNESS FAILED (%d)\n" : "KEY HARNESS OK\n", failures);
                        instance.exit();
                    });
                });
            });
            });
        });
        });
    });
    instance.exec();
    return failures ? 1 : 0;
}
