// 插件按键行为测试：起一个无界面、无 D-Bus 的私有 fcitx5 实例，只加载 wowtype，
// 用一个假的输入上下文按键，检查上屏结果。不会碰到正在运行的 fcitx5。
//
// 由 scripts/addon-test.sh 设置好隔离的 XDG 目录和词库后运行。

#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <functional>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include <fcitx/addoninstance.h>
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
#include <fcitx-utils/event.h>
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
        // 删掉剩余拼音，再退格撤销选词
        type(ic.get(), "<bs><bs><bs><bs><bs><bs><bs><bs>");
        check(preedit(ic.get()) == "你好", "删完剩余拼音，实际 " + preedit(ic.get()));
        type(ic.get(), "<bs>");
        check(preedit(ic.get()) == "ni'hao", "再退格撤销选词，实际 " + preedit(ic.get()));
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
              grid[0].rfind("\uFF11\u3014" + firstPage[0] + "\u3015", 0) == 0 &&
              grid[0].find(firstPage[5]) != std::string::npos &&
              grid[0].find(firstPage[6]) == std::string::npos,
          "下键展开：第一行 6 个、光标框住第一个：" + join(grid));
    type(ic.get(), "<right><right><sp>");
    check(firstPage.size() > 2 && ic->committed == firstPage[2],
          "展开后右移两格空格选第三个，实际 " + ic->committed);
    // 选过词后排序会变（学习、上文），每次按之前重新取当前这一页
    fresh(ic.get());
    type(ic.get(), "shi");
    auto now = page(ic.get());
    type(ic.get(), "<down><down><sp>");
    check(now.size() > 6 && ic->committed == now[6],
          "展开后下移一行空格选第七个，实际 " + ic->committed);
    fresh(ic.get());
    type(ic.get(), "shi");
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
        check(!emoji, "单字不推荐 emoji：" + join(page(ic.get())));
    }

    // 表情面板：Super+. 打开，空搜索列全部，空格选第一个，Esc 关闭
    const Key emojiKey(FcitxKey_period, KeyState::Super);
    fresh(ic.get());
    check(send(ic.get(), emojiKey), "Super+. 被输入法接住");
    check(ic->inputPanel().auxUp().toString().find("表情") != std::string::npos &&
              !page(ic.get()).empty(),
          "打开表情面板：" + ic->inputPanel().auxUp().toString());
    // 上面刚选过 😊：最近用过的排最前，后面是全部 emoji（😀 开头）
    check(!page(ic.get()).empty() && page(ic.get())[0].find("〔😊〕２　😀") != std::string::npos,
          "最近用过的排最前：" + (page(ic.get()).empty() ? std::string() : page(ic.get())[0]));
    type(ic.get(), "<right><sp>");
    check(ic->committed == "😀", "右键移到第二个再选 😀，实际 " + ic->committed);
    fresh(ic.get());
    send(ic.get(), emojiKey);
    type(ic.get(), "<sp>");
    check(ic->committed == "😀", "空格选第一个（刚用过的 😀），实际 " + ic->committed);
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
            << "CandidateLayout=Vertical\nPageSize=5\nVoice=False\nEmojiSuggest=False\n";
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
    check(!send(ic.get(), Key(FcitxKey_Alt_R)), "关掉语音后右 Alt 交给应用");
    type(ic.get(), "wdyx<sp>");
    check(ic->committed == "我的邮箱", "自定义词也能简拼：wdyx -> " + ic->committed);
    fresh(ic.get());
    type(ic.get(), "kaixin");
    check(join(page(ic.get())).find("😊") == std::string::npos, "关掉 emoji 推荐后没有 😊：" + join(page(ic.get())));

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

    // 单按 Shift 切英文（#28）：右 Shift 不是 fcitx 默认的临时切换键，走的是 WowType 自己的英文模式
    const auto tapShift = [&](KeySym sym) {
        KeyEvent press(ic.get(), Key(sym), false);
        ic->keyEvent(press);
        KeyEvent release(ic.get(), Key(sym, KeyState::Shift), true);
        return ic->keyEvent(release);
    };
    check(tapShift(FcitxKey_Shift_R), "单按右 Shift 被接住");
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
        KeyEvent press(ic.get(), Key(FcitxKey_Shift_R), false);
        ic->keyEvent(press);
        send(ic.get(), Key(FcitxKey_A, KeyState::Shift));
        KeyEvent release(ic.get(), Key(FcitxKey_Shift_R, KeyState::Shift), true);
        check(!ic->keyEvent(release), "Shift+字母后松开 Shift 不切换");
        type(ic.get(), "<esc>nihao<sp>");
        check(ic->committed == "你好", "仍是中文：" + ic->committed);
    }
    fresh(ic.get());

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
    check(join(page(ic.get())).find(':') == std::string::npos, "简拼 sj 不出时间：" + join(page(ic.get())));
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
    std::filesystem::remove(configDir + "/wowtype.conf");
    addon->reloadConfig();
    fresh(ic.get());

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

void tapKey(HarnessInputContext *ic, KeySym sym) {
    KeyEvent press(ic, Key(sym), false);
    ic->keyEvent(press);
    KeyEvent release(ic, Key(sym, KeyState::Shift), true);
    ic->keyEvent(release);
}

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
    EventDispatcher mainDispatcher;
    mainDispatcher.attach(&instance.eventLoop());
    dispatcher = &mainDispatcher;
    mainDispatcher.schedule([&instance]() {
        runCases(instance);
        runTranslateCase(instance, [&instance]() {
            runVoiceCase(instance, [&instance]() {
                std::printf(failures ? "KEY HARNESS FAILED (%d)\n" : "KEY HARNESS OK\n", failures);
                instance.exit();
            });
        });
    });
    instance.exec();
    return failures ? 1 : 0;
}
