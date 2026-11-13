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

errors = []
sys.excepthook = lambda t, v, tb: errors.append("".join(traceback.format_exception(t, v, tb)))

# 会改设置、加自定义词：放到临时目录里，不动本机的
home = tempfile.mkdtemp(prefix="wowtype-gui-test-")
os.environ.update(HOME=home, XDG_CONFIG_HOME=f"{home}/.config", XDG_DATA_HOME=f"{home}/.local/share",
                  XDG_CACHE_HOME=f"{home}/.cache", XDG_STATE_HOME=f"{home}/.local/state")

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


def run(app):
    win = app.props.active_window
    for page in ("general", "input", "emoji", "voice", "translate", "words", "update"):
        step(f"打开「{page}」页", lambda p=page: win.show_page(p))

    def spin():
        win.page_row.set_value(7)
        check(win.page_row.get_value() == 7, "每页个数没变")
        win.font_row.set_value(14)
    step("数字框", spin)

    def switches():
        win.theme_row.set_active(True)
        win.theme_row.set_active(False)
        for row in win.switches.values():
            row.set_active(not row.get_active())
        win.shift_free_row.set_active(True)
    step("开关", switches)

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
        # 只有替身（GTK 4.10 以前）的文件对话框是普通窗口，能在这里点「保存」
        if ns["FileDialog"] is not ns["_FileDialog"]:
            return
        folder = tempfile.mkdtemp()
        target = os.path.join(folder, "words.tsv")
        for w in new_windows(win, win.on_export_words):
            w.set_current_folder(Gio.File.new_for_path(folder))
            w.set_current_name("words.tsv")
            pump(1)
            w.response(Gtk.ResponseType.ACCEPT)
        pump(1)
        check(os.path.exists(target), "导出自定义词没写出文件")
    step("导出自定义词（保存）", export_words)
    step("打开网址", lambda: win.open_url("https://example.invalid/"))
    step("用编辑器打开自定义词", win.on_open_custom)
    pump(1)
    app.quit()
    return GLib.SOURCE_REMOVE


app = ns["SettingsApp"]()
app.connect("activate", lambda a: GLib.timeout_add(800, run, a))
app.run(["wowtype-config"])
print(f"\n{len(errors)} 个报错")
for error in errors:
    print(error)
sys.exit(1 if errors else 0)
