#!/usr/bin/env python3
"""设置界面的无头冒烟测试：打开每一页、动一下各种控件、点开每个对话框再关掉，有报错就失败。

    dbus-run-session -- xvfb-run -a python3 scripts/test-settings-gui.py [wowtype-config 的路径]

主要防的是老系统：Ubuntu 22.04 是 GTK 4.6、libadwaita 1.1，好些控件要用 wowtype-config 里的替身；
新系统用原生控件。两边都要能把每一页、每个对话框走一遍。对话框里的回答只在替身（真窗口）上点得到，
原生的 Adw 对话框画在设置窗口里面，这里只检查打得开。
"""

import os
import runpy
import sys
import tempfile
import time
import traceback

sys.stdout.reconfigure(line_buffering=True)
errors = []
sys.excepthook = lambda t, v, tb: errors.append("".join(traceback.format_exception(t, v, tb)))

# 会改设置、加自定义词：放到临时目录里，不动本机的
home = tempfile.mkdtemp(prefix="wowtype-gui-test-")
os.environ.update(HOME=home, XDG_CONFIG_HOME=f"{home}/.config", XDG_DATA_HOME=f"{home}/.local/share",
                  XDG_CACHE_HOME=f"{home}/.cache", XDG_STATE_HOME=f"{home}/.local/state")

# 五笔码表放进数据目录：「五笔输入」能选（没有码表时灰掉，下面也试）
wubi_table = f"{home}/.local/share/wowtype/wubi86.tsv"
os.makedirs(os.path.dirname(wubi_table))
with open(wubi_table, "w", encoding="utf-8") as f:
    f.write("g\t一\t1\n")

path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "settings", "wowtype-config")
ns = runpy.run_path(path, run_name="wowtype_settings_test")
from gi.repository import Adw, Gio, GLib, Gtk  # noqa: E402

print(f"GTK 4.{Gtk.get_minor_version()}，libadwaita 1.{Adw.get_minor_version()}")
if not ns["gui_supported"]():
    print("这个系统上设置界面不支持，跳过")
    sys.exit(0)


def pump(seconds=0.2):
    end = time.time() + seconds
    context = GLib.MainContext.default()
    while time.time() < end:
        while context.pending():
            context.iteration(False)
        time.sleep(0.01)


def pump_until(done, timeout=15):
    """转主循环直到 done() 为真；慢机器上（CI 的 arm64）固定等一秒不够。"""
    end = time.time() + timeout
    while not done() and time.time() < end:
        pump(0.1)
    return done()


def step(name, action):
    try:
        action()
        pump()
        print("ok  ", name)
    except Exception:
        errors.append(f"[{name}]\n{traceback.format_exc()}")
        print("FAIL", name)


def new_windows(window, action):
    """做 action，返回它新打开的顶层窗口（替身对话框、文件对话框）。"""
    before = {id(w) for w in Gtk.Window.list_toplevels()}
    action()
    pump(0.5)
    return [w for w in Gtk.Window.list_toplevels()
            if id(w) not in before and w is not window and w.get_visible()]


def check(condition, message):
    if not condition:
        raise AssertionError(message)


ran = []


def run(app):
    ran.append(True)
    win = app.props.active_window
    if win is None:
        errors.append("设置窗口没打开")
        app.quit()
        return GLib.SOURCE_REMOVE
    for page in ("general", "input", "emoji", "voice", "translate", "words", "update"):
        step(f"打开「{page}」页", lambda p=page: win.show_page(p))

    def spin():
        win.page_row.set_value(7)
        check(win.page_row.get_value() == 7, "每页个数没变")
        win.font_row.set_value(14)
    step("数字框", spin)

    def arrow_keys():
        # 「方向键」的副标题跟着用法和候选排列走
        win.layout_row.set_selected(1)
        check(win.arrow_row.get_subtitle() == "↑ ↓ 选词，← → 翻页", "竖排的副标题不对")
        win.arrow_row.set_selected(1)
        check(win.values["ArrowKeys"] == "Caret", "方向键没存成 Caret")
        check(win.arrow_row.get_subtitle() == "↑ ↓ 选词，← → 在拼音里移动光标", "移光标的副标题不对")
        win.arrow_row.set_selected(0)
        win.layout_row.set_selected(0)
        check(win.arrow_row.get_subtitle() == "← → 选词，↑ 上一页，↓ 展开更多候选", "横排的副标题不对")
    step("方向键", arrow_keys)

    def input_scheme():
        # 「输入方案」单选：双拼才出方案和显示打的键，五笔才出它的两个开关；双拼、五笔时计算器换大写 V、工具栏灰掉
        def visible(rows):
            return [row.get_visible() for row in rows]
        win.scheme_checks["Wubi86"].set_active(True)
        pump(0.4)
        check(win.values["InputScheme"] == "Wubi86", "没存成五笔")
        check(visible(win.scheme_rows["Wubi86"]) == [True, True] and visible(win.scheme_rows["Shuangpin"]) == [False, False],
              "五笔时该只出五笔的两个开关")
        check(win.calc_row.get_subtitle().startswith("五笔时打大写 V") and not win.toolbar_row.get_sensitive(),
              "五笔时计算器、工具栏的说明不对")
        text = open(ns["CONFIG_FILE"], encoding="utf-8").read()
        check("InputScheme=Wubi86" in text and "\nShuangpin=" not in text, "五笔写进文件不对")
        win.scheme_rows["Wubi86"][0].set_active(False)
        check(win.values["WubiAutoCommit"] == "False", "四码唯一自动上屏没存上")
        win.scheme_rows["Wubi86"][0].set_active(True)
        win.scheme_checks["Shuangpin"].set_active(True)
        pump(0.4)
        check(visible(win.scheme_rows["Wubi86"]) == [False, False] and visible(win.scheme_rows["Shuangpin"]) == [True, True],
              "双拼时该只出双拼的两项")
        text = open(ns["CONFIG_FILE"], encoding="utf-8").read()
        check("InputScheme=Shuangpin" in text and "\nShuangpin=" not in text, "双拼写进文件不对")
        win.scheme_checks["Quanpin"].set_active(True)
        pump(0.4)
        check(not any(visible(win.scheme_rows["Wubi86"] + win.scheme_rows["Shuangpin"])), "全拼时不该出双拼、五笔的设置")
        check(win.toolbar_row.get_sensitive() and win.calc_row.get_subtitle() == "v1+2*3 → 7", "全拼时计算器、工具栏不对")
        # 没有码表：「五笔输入」灰掉（另建一页看，看完换回来）。装了安装包时系统目录里也有码表，
        # 所以把设置界面找码表的地方换成空的，不删文件
        found = type(win).build_input.__globals__
        saved = found["WUBI_CANDIDATES"]
        found["WUBI_CANDIDATES"] = []
        try:
            win.build_input()
            check(not win.scheme_checks["Wubi86"].is_sensitive(), "没有码表时五笔该灰掉")
        finally:
            found["WUBI_CANDIDATES"] = saved
            win.build_input()
        check(win.scheme_checks["Wubi86"].is_sensitive(), "有码表时五笔该能选")
    step("输入方案", input_scheme)

    def switches():
        win.theme_row.set_active(True)
        win.theme_row.set_active(False)
        for row in win.switches.values():
            row.set_active(not row.get_active())
        win.shift_free_row.set_active(True)
    step("开关", switches)

    def toggle_key():
        # 另设的切换键选 Ctrl+空格：fcitx5 默认拿它切换输入法，提示 WowType 收不到。
        # fcitx5 的快捷键直接给定，不看这台机器（/etc/xdg 里可能改过）
        win.fcitx_hotkey = {"TriggerKeys": {"0": "Control+space"}}
        win.toggle_key_row.set_selected(1)
        check(win.values["ToggleKey"] == "Control+space", "切换键没存上")
        check("Ctrl+空格 切换输入法" in win.toggle_key_row.get_subtitle(), "没提示 Ctrl+空格被 fcitx5 占着")
        win.toggle_key_row.set_selected(0)
        check(win.toggle_key_row.get_subtitle() == "", "不用切换键时还有提示")
    step("切换键", toggle_key)

    def entries():
        win.url_row.set_text("http://127.0.0.1:9/v1")
        win.key_entry.set_text("sk-test")
        win.tmodel_row.set_text("m")
        check(win.url_row.get_text() == "http://127.0.0.1:9/v1", "接口地址没写进去")
        win.word_entry.set_text("测试")
        win.pinyin_entry.set_text("a-b")  # 编码不对，标红
        win.pinyin_entry.set_text("ce shi")
        win.pinyin_entry.emit("entry-activated")
        check(("ce shi", "测试") in win.words, "回车没加上自定义词")
    step("输入框", entries)

    def dialog(name, action, answer=None):
        def go():
            for w in new_windows(win, action):
                if isinstance(w, Gtk.MessageDialog) and answer is not None:
                    w.response(answer)
                elif isinstance(w, Gtk.Dialog):
                    w.response(Gtk.ResponseType.CANCEL)
                else:
                    w.close()
        step(name, go)
    dialog("关于", win.on_about)
    dialog("删语音模型（取消）", lambda: win.on_voice_delete(None))
    dialog("下载离线翻译模型（取消）", lambda: win.on_local_download(None))
    dialog("恢复默认设置（确定）", win.on_reset, answer=1)
    dialog("导出日志（取消）", win.on_export_log)
    dialog("导入自定义词（取消）", win.on_import_words)
    dialog("从文件装词库（取消）", lambda: win.on_lexicon_from_file(None))

    def export_words():
        # 替身（GTK 4.10 以前）的文件对话框：选好文件点「保存」以后，自定义词写到那个文件里。
        # GTK 自己的选文件窗口换目录、回应「保存」都是异步的，在 CI 上时灵时不灵；这里要测的是
        # 替身和导出本身，所以把选文件窗口换成一个马上「保存」到指定文件的假窗口
        if ns["FileDialog"] is not ns["_FileDialog"]:
            return
        target = os.path.join(tempfile.mkdtemp(), "words.tsv")
        asked = {}

        class Chooser:
            def __init__(self, **_properties):
                pass

            def add_filter(self, _filter):
                pass

            def set_current_name(self, name):
                asked["name"] = name

            def set_current_folder(self, _folder):
                pass

            def connect(self, _signal, callback):
                self.respond = callback

            def show(self):
                GLib.idle_add(lambda: self.respond(self, Gtk.ResponseType.ACCEPT) and False)

            def get_file(self):
                return Gio.File.new_for_path(target)

            def destroy(self):
                pass

        real, Gtk.FileChooserNative = Gtk.FileChooserNative, Chooser
        try:
            win.on_export_words()
            check(pump_until(lambda: os.path.exists(target)), "导出自定义词没写出文件")
        finally:
            Gtk.FileChooserNative = real
        check(asked.get("name") == "wowtype-custom-words.tsv", "保存窗口里没填默认文件名")
        with open(target, encoding="utf-8") as f:
            check("测试" in f.read(), "导出的文件里没有刚加的自定义词")
    step("导出自定义词（保存）", export_words)
    step("打开网址", lambda: win.open_url("https://example.invalid/"))
    step("用编辑器打开自定义词", win.on_open_custom)
    pump(1)
    app.quit()
    return GLib.SOURCE_REMOVE


app = ns["SettingsApp"]()
app.connect("activate", lambda a: GLib.timeout_add(800, run, a))
app.run(["wowtype-config"])
if not ran:
    errors.append("设置窗口没打开就退出了")
print(f"\n{len(errors)} 个报错")
for error in errors:
    print(error)
sys.stdout.flush()
# 窗口没建好时退出过程中 GTK 可能崩，结果已经打出来了，直接退
os._exit(1 if errors else 0)
