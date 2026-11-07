// 插件按键行为测试：起一个无界面、无 D-Bus 的私有 fcitx5 实例，只加载 wowtype，
// 用一个假的输入上下文按键，检查上屏结果。不会碰到正在运行的 fcitx5。
//
// 由 scripts/addon-test.sh 设置好隔离的 XDG 目录和词库后运行。

#include <chrono>
#include <cstdio>
#include <functional>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include <fcitx/addonmanager.h>
#include <fcitx/candidatelist.h>
#include <fcitx/inputmethodentry.h>
#include <fcitx/inputmethodmanager.h>
#include <fcitx/event.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputcontextmanager.h>
#include <fcitx/inputpanel.h>
#include <fcitx/instance.h>
#include <fcitx-utils/eventdispatcher.h>
#include <fcitx-utils/key.h>
#include <fcitx-utils/keysym.h>

using namespace fcitx;

namespace {

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
    void forwardKeyImpl(const ForwardKeyEvent &) override {}
    void updatePreeditImpl() override {}

    std::string committed;
    /// 输入法没接的键（直接交给应用的）
    std::string passed;
};

int failures = 0;

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
            else if (name == "pgdn") sym = FcitxKey_Page_Down;
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
void fresh(HarnessInputContext *ic) {
    type(ic, "<esc>");
    ic->committed.clear();
    ic->passed.clear();
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
        check(preedit(ic.get()) == "你好zhongguo", "编辑区 = 已选 + 剩余拼音，实际 " + preedit(ic.get()));
        // 删掉剩余拼音，再退格撤销选词
        type(ic.get(), "<bs><bs><bs><bs><bs><bs><bs><bs>");
        check(preedit(ic.get()) == "你好", "删完剩余拼音，实际 " + preedit(ic.get()));
        type(ic.get(), "<bs>");
        check(preedit(ic.get()) == "nihao", "再退格撤销选词，实际 " + preedit(ic.get()));
        type(ic.get(), "zhongguo");
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

    // 候选横排（和微信输入法一样）：下键翻页，右键移动光标
    fresh(ic.get());
    type(ic.get(), "shi");
    {
        auto list = ic->inputPanel().candidateList();
        auto *common = list ? dynamic_cast<CommonCandidateList *>(list.get()) : nullptr;
        check(common && common->layoutHint() == CandidateLayoutHint::Horizontal, "候选横排");
    }
    const auto firstPage = page(ic.get());
    type(ic.get(), "<down>");
    check(page(ic.get()) != firstPage, "横排时下键翻页：" + join(page(ic.get())));

    // 空格选光标所在的候选
    fresh(ic.get());
    type(ic.get(), "shi<right>");
    const auto list = page(ic.get());
    type(ic.get(), "<sp>");
    check(list.size() > 1 && ic->committed == list[1], "右移光标后空格选第二个，实际 " + ic->committed);

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

    // 连续上屏很多字，上下文按 UTF-8 截断不出错
    fresh(ic.get());
    for (int i = 0; i < 30; ++i) {
        type(ic.get(), "zhongguo<sp>");
    }
    type(ic.get(), "renmin<sp>");
    check(ic->committed.size() > 30 * 6, "连续上屏 31 次没出错");

    ic.reset();
}

} // namespace

int main(int argc, char **argv) {
    (void)argc;
    (void)argv;
    char arg0[] = "wowtype-key-harness";
    char arg1[] = "--disable=all";
    char arg2[] = "--enable=wowtype,testim";
    char *args[] = {arg0, arg1, arg2};
    Instance instance(3, args);
    instance.addonManager().registerDefaultLoader(nullptr);
    EventDispatcher dispatcher;
    dispatcher.attach(&instance.eventLoop());
    dispatcher.schedule([&instance]() {
        runCases(instance);
        std::printf(failures ? "KEY HARNESS FAILED (%d)\n" : "KEY HARNESS OK\n", failures);
        instance.exit();
    });
    instance.exec();
    return failures ? 1 : 0;
}
