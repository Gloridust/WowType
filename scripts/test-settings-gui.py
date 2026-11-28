#!/usr/bin/env python3
"""设置界面的无头冒烟测试：打开每一页、动一下各种控件、点开每个对话框再关掉，有报错就失败。

    dbus-run-session -- xvfb-run -a python3 scripts/test-settings-gui.py [wowtype-config 的路径]

主要防的是老系统：Ubuntu 22.04 是 GTK 4.6、libadwaita 1.1，好些控件要用 wowtype-config 里的替身；
新系统用原生控件。两边都要能把每一页、每个对话框走一遍。对话框里的回答只在替身（真窗口）上点得到，
原生的 Adw 对话框画在设置窗口里面，这里只检查打得开。
"""

import json
import os
import runpy
import sys
import tempfile
import time
import traceback

sys.stdout.reconfigure(line_buffering=True)
errors = []
sys.excepthook = lambda t, v, tb: errors.append("".join(traceback.format_exception(t, v, tb)))

# 会切主题、改字号、开关 GNOME 扩展、调 fcitx5 的 SetConfig：只许在私有的会话总线上跑
# （CI：dbus-run-session -- xvfb-run -a python3 scripts/test-settings-gui.py）。在桌面上直接跑会改掉
# 正在用的 fcitx5 主题和字号；gsettings 读的是临时 HOME 里的空库、写的却是本机的 dconf，
# GNOME 已启用的扩展会被清空。所以 gsettings 一律放内存里，总线上有 fcitx5 就不跑。
os.environ["GSETTINGS_BACKEND"] = "memory"


def _fcitx5_on_bus():
    from gi.repository import Gio
    try:
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        reply = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                              "NameHasOwner", __import__("gi").repository.GLib.Variant("(s)", ("org.fcitx.Fcitx5",)),
                              None, Gio.DBusCallFlags.NONE, 3000, None)
        return reply.unpack()[0]
    except Exception:  # noqa: BLE001  连不上总线：反正碰不到正在用的 fcitx5
        return False


if _fcitx5_on_bus():
    print("会话总线上有正在跑的 fcitx5：这个测试会改它的设置。请在私有总线上跑：\n"
          "  dbus-run-session -- xvfb-run -a python3 scripts/test-settings-gui.py")
    sys.exit(2)

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
    for page in ("general", "input", "emoji", "voice", "translate", "words", "stats", "update"):
        step(f"打开「{page}」页", lambda p=page: win.show_page(p))

    def spin():
        win.page_row.set_value(7)
        check(win.page_row.get_value() == 7, "每页个数没变")
        win.font_row.set_value(14)
    step("数字框", spin)

    def voice_silence():
        # 语音页的「停顿多久自动结束」：默认 1.5 秒，选「不自动结束」存成 0，再选回来
        row = win.silence_row
        check(row.get_title() == "停顿多久自动结束", "停顿的名字不对")
        check(win.voice_silence_values[row.get_selected()] == "1500", "停顿默认不是 1.5 秒")
        row.set_selected(win.voice_silence_values.index("0"))
        check(win.values["VoiceSilenceTimeout"] == "0", "不自动结束没存成 0")
        row.set_selected(win.voice_silence_values.index("10000"))
        check(win.values["VoiceSilenceTimeout"] == "10000", "10 秒没存成 10000")
        row.set_selected(0)
        check(win.values["VoiceSilenceTimeout"] == "1500", "没改回 1.5 秒")
    step("停顿多久自动结束", voice_silence)

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

    def window_look():
        # 「设置窗口」的主题、强调色：存进 wowtype.conf，马上换上（主题固定时盖过系统主题的颜色）
        manager = Adw.StyleManager.get_default()
        check(win.values["SettingsTheme"] == "System" and win.values["SettingsAccent"] == "Green", "默认该是跟随系统、绿色")
        check(manager.get_color_scheme() == Adw.ColorScheme.DEFAULT, "跟随系统时不该固定浅色 / 深色")
        win.settings_theme_row.set_selected(win.settings_theme_names.index("Dark"))
        win.settings_accent_row.set_selected(win.settings_accent_names.index("Blue"))
        check(app.look == ("Dark", "Blue"), f"没换上：{app.look}")
        check(manager.get_color_scheme() == Adw.ColorScheme.FORCE_DARK and manager.get_dark(), "固定深色没生效")
        css = ns["theme_css"](True, "Blue")
        check("#2D70C2" in css and "#0A8358" not in css, "蓝色的样式里还是绿色")
        check("#222226" in ns["forced_css"](True) and "#fafafb" in ns["forced_css"](False), "固定主题的颜色不对")
        pump(0.4)
        text = open(ns["CONFIG_FILE"], encoding="utf-8").read()
        check("SettingsTheme=Dark" in text and "SettingsAccent=Blue" in text, f"没写进文件：{text}")
        win.settings_theme_row.set_selected(win.settings_theme_names.index("Light"))
        check(manager.get_color_scheme() == Adw.ColorScheme.FORCE_LIGHT and not manager.get_dark(), "固定浅色没生效")
        win.settings_theme_row.set_selected(0)
        win.settings_accent_row.set_selected(0)
        check(app.look == ("System", "Green") and manager.get_color_scheme() == Adw.ColorScheme.DEFAULT,
              "换回跟随系统、绿色没生效")
        pump(0.4)
        text = open(ns["CONFIG_FILE"], encoding="utf-8").read()
        check("SettingsTheme" not in text and "SettingsAccent" not in text, "默认值不该写进文件")
    step("设置窗口的主题和强调色", window_look)

    def input_scheme():
        # 「输入方案」单选：双拼才出方案、显示打的键和简拼，五笔才出它的两个开关；双拼、五笔时计算器换大写 V、工具栏灰掉
        def visible(rows):
            return [row.get_visible() for row in rows]
        win.scheme_checks["Wubi86"].set_active(True)
        pump(0.4)
        check(win.values["InputScheme"] == "Wubi86", "没存成五笔")
        check(visible(win.scheme_rows["Wubi86"]) == [True, True] and visible(win.scheme_rows["Shuangpin"]) == [False, False, False],
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
        check(visible(win.scheme_rows["Wubi86"]) == [False, False] and visible(win.scheme_rows["Shuangpin"]) == [True, True, True],
              "双拼时该只出双拼的三项")
        win.scheme_rows["Shuangpin"][2].set_active(False)
        check(win.values["ShuangpinAbbrev"] == "False", "双拼简拼没存上")
        win.scheme_rows["Shuangpin"][2].set_active(True)
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

    def stats_page():
        # 打字统计默认关：只有开关、清除和说明；打开后画概览和各标签；清除删掉文件、计数加一
        stats_file, clear_file = ns["STATS_FILE"], ns["STATS_CLEAR_FILE"]
        check(win.values["TypingStats"] == "False", "打字统计该默认关")
        win.show_page("stats")
        pump()
        check(win.stats_box.get_first_child() is not None, "关着时没有说明")
        os.makedirs(os.path.dirname(stats_file), exist_ok=True)
        day = {"chars": 5, "kinds": {"han": 5}, "activeMs": 60000, "keys": {"KeyA": 3, "F13": 1},
               "sources": {"quanpin": 5}, "schemes": {"xiaohe": 5},
               "selections": [1, 2, 0, 0, 0, 0, 0, 0, 0], "beyond": 1}
        with open(stats_file, "w", encoding="utf-8") as f:
            json.dump({"version": 2, "cleared": 0, "days": {time.strftime("%Y-%m-%d"): day}}, f)
        win.stats_row.set_active(True)
        check(pump_until(lambda: win.values["TypingStats"] == "True"), "打开统计没存上")
        check(pump_until(lambda: win.stats_box.get_first_child() is not win.stats_box.get_last_child()), "打开统计后没画概览")
        for tab in ("keys", "trend", "kind", "mode", "scheme", "ranks"):
            win.stats_stack.set_visible_child_name(tab)
            pump(0.05)
        check(win.stats_clear_row.get_sensitive(), "有记录时清除该能点")
        win.on_stats_clear(None, "clear")
        check(not os.path.exists(stats_file), "清除没删掉 stats.json")
        with open(clear_file, encoding="utf-8") as f:
            check(f.read().strip() == "1", "清除计数没加一")
        win.stats_row.set_active(False)
        check(pump_until(lambda: win.values["TypingStats"] == "False"), "关掉统计没存上")
    step("打字统计", stats_page)

    def switches():
        win.theme_row.set_active(True)
        win.theme_row.set_active(False)
        for row in win.switches.values():
            row.set_active(not row.get_active())
        win.shift_free_row.set_active(True)
    step("开关", switches)

    def toggle_key():
        # 设成 fcitx5 也在用的键：提示 WowType 收不到。fcitx5 的快捷键直接给定，不看这台机器
        # （/etc/xdg 里可能改过）；预设里没有 fcitx5 默认占着的键，这里假装用户在 fcitx5 里设了它
        win.fcitx_hotkey = {"TriggerKeys": {"0": "Control+Shift+space"}}
        toggle = win.key_rows["ToggleKey"]
        toggle.set_selected(1)
        check(win.values["ToggleKey"] == "Control+Shift+space", "切换键没存上")
        check("Ctrl+Shift+空格 切换输入法" in toggle.get_subtitle(), f"没提示被 fcitx5 占着：{toggle.get_subtitle()}")
        toggle.set_selected(0)
        check(toggle.get_subtitle() == "", "不用切换键时还有提示")
        # 互译键：互译没开时提示先去打开；也被 fcitx5 占着时提示占着
        translate = win.key_rows["TranslateModeKey"]
        translate.set_selected(1)
        check(win.values["TranslateModeKey"] == "Control+Shift+Y", "互译键没存上")
        check(translate.get_subtitle() == "先在「翻译」页打开互译", f"没提示先打开互译：{translate.get_subtitle()}")
        win.fcitx_hotkey = {"TriggerKeys": {"0": "Control+Shift+Y"}}
        win.refresh_translate_status()
        check("fcitx5 也用 Ctrl+Shift+Y" in translate.get_subtitle(), f"互译键被占着没提示：{translate.get_subtitle()}")
        win.fcitx_hotkey = {}
        translate.set_selected(0)
        check(translate.get_subtitle() == "", "不用互译键时还有提示")
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

    def translate_engine():
        # 翻译引擎三选一：本地 / 哔哩哔哩 / 自定义。选哪个写哪个的键，下面只出现它的设置
        engine = win.engine_row
        check(engine.get_selected() == 0, "默认不是本地翻译")
        check(win.local_group.get_visible() and not win.bili_group.get_visible()
              and not win.service_group.get_visible(), "本地翻译时出现了别的设置")
        engine.set_selected(2)
        win.url_row.set_text("https://api.example.com/v1")
        win.tmodel_row.set_text("my-model")
        check(win.values["TranslateLocal"] == "False", "选自定义没写 TranslateLocal=False")
        check(win.values["TranslateBaseUrl"] == "https://api.example.com/v1", "自定义地址没存上")
        check(win.service_group.get_visible() and not win.bili_group.get_visible(), "自定义时没出现填接口的地方")
        check(pump_until(lambda: ns["read_translate_key"]() == "sk-test"), "Key 没存上")
        engine.set_selected(1)
        check(win.values["TranslateBaseUrl"] == ns["BILIBILI_URL"], "选哔哩哔哩没写它的地址")
        check(win.values["TranslateModel"] == ns["BILIBILI_DEFAULT_MODEL"], "哔哩哔哩的模型不是 2B")
        check(win.bili_group.get_visible() and not win.service_group.get_visible()
              and not win.local_group.get_visible(), "选哔哩哔哩时显示的设置不对")
        check(win.translate_ready(), "哔哩哔哩不用 Key 也该算配好了")
        check("哔哩哔哩的服务器" in (win.bili_group.get_description() or ""), "没写隐私说明")
        check(win.url_row.get_text() == "https://api.example.com/v1", "自定义框里的地址被改了")
        win.bili_model_row.set_selected(1)
        check(win.values["TranslateModel"] == "Index-Translate-9B", "哔哩哔哩的模型没存上")
        config = ns["CONFIG_FILE"]
        check(pump_until(lambda: os.path.exists(config) and "Index-Translate-9B" in open(config, encoding="utf-8").read()),
              "哔哩哔哩没存盘")
        check(ns["translate_engine"](ns["read_config"]()[0]) == 1, "读回来不是哔哩哔哩")
        check(ns["read_translate_key"]() == "sk-test", "选哔哩哔哩把 Key 删了")
        # 测试连接：不联网，换成假的 test_translate，看发给谁、带没带 Key
        calls = []
        scope = win.on_test_translate.__func__.__globals__
        real = scope["test_translate"]
        scope["test_translate"] = lambda base, key, model, target="en", text="你好", formal=False: (
            calls.append((base, key, model)) or ("Hello", 0.3))
        try:
            win.bili_test_button.emit("clicked")
            check(pump_until(lambda: "Hello" in (win.bili_test_row.get_subtitle() or "")),
                  f"测试连接没出结果：{win.bili_test_row.get_subtitle()}")
        finally:
            scope["test_translate"] = real
        check(calls == [(ns["BILIBILI_URL"], "", "Index-Translate-9B")], f"测试连接发的不对：{calls}")
        # 换回自定义：框里的地址、模型照原样写回
        engine.set_selected(2)
        check(win.values["TranslateBaseUrl"] == "https://api.example.com/v1"
              and win.values["TranslateModel"] == "my-model", "换回自定义没写回原来的地址和模型")
        engine.set_selected(0)
        check(win.values["TranslateLocal"] == "True", "换回本地没写 TranslateLocal=True")
    step("翻译引擎", translate_engine)

    def one_shot():
        # 双击 Shift 单次互译（#191）：打开以后「互译」那一行说双击 Shift 翻一句（上面「开关」一步翻过它，先关上）
        row = win.one_shot_row
        row.set_active(False)
        ready, conflicts = win.translate_ready, getattr(win, "shift_conflicts", [])
        win.translate_ready = lambda: True
        win.shift_conflicts = []
        try:
            row.set_active(True)
            check(win.values["TranslateOneShot"] == "True", "单次互译没存上")
            check(win.translate_row.get_subtitle() == "双击 Shift 翻一句，单按只切中英",
                  f"互译那一行没跟着变：{win.translate_row.get_subtitle()}")
            row.set_active(False)
            check(win.values["TranslateOneShot"] == "False", "关掉单次互译没存上")
            check(win.translate_row.get_subtitle() == "单按 Shift：中 → 英 → 译 → 中",
                  f"关掉后互译那一行没变回来：{win.translate_row.get_subtitle()}")
        finally:
            win.translate_ready = ready
            win.shift_conflicts = conflicts
            win.refresh_translate_status()
    step("双击 Shift 单次互译", one_shot)

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
    dialog("清除打字统计（取消）", lambda: win.stats_clear(None))
    dialog("删语音模型（取消）", lambda: win.on_voice_delete(None))
    dialog("下载离线翻译模型（取消）", lambda: win.on_local_download(None))

    def local_upgrade():
        # 升级前下载过上一代翻译模型：照旧算下载好了，按钮变成「升级」，确认框能取消
        models = ns["MODELS_DIR"]
        os.makedirs(models, exist_ok=True)
        legacy = os.path.join(models, ns["LEGACY_MODEL_FILE"])
        with open(legacy, "wb") as f:
            f.write(b"gguf")
        saved = win.values["TranslateLlamaServer"]
        win.values["TranslateLlamaServer"] = sys.executable  # 当成找到了 llama-server
        try:
            win.refresh_local_translate()
            check(win.local_ready(), "只有上一代模型时应该算下载好了")
            check(win.local_download.get_visible() and win.local_download.get_label() == "升级",
                  f"上一代模型没给「升级」：{win.local_download.get_label()}")
            check("上一代" in win.local_model_row.get_subtitle(), win.local_model_row.get_subtitle())
            for w in new_windows(win, lambda: win.on_local_download(None)):
                w.close()
            check(win.local_cancel is None and os.path.isfile(legacy), "取消升级不该动旧模型")
            # 真升级一遍（下载地址换成本机的假服务）：新模型下好、校验过了，旧模型和它的半截都删掉
            import hashlib
            import http.server
            import threading
            blob = os.urandom(200_000)

            class Handler(http.server.BaseHTTPRequestHandler):
                def log_message(self, *_a):
                    pass

                def do_GET(self):
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(blob)))
                    self.end_headers()
                    self.wfile.write(blob)
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            config = type(win).start_local_download.__globals__
            pinned = config["LOCAL_MODEL_URL"], config["LOCAL_MODEL_SHA256"]
            config["LOCAL_MODEL_URL"] = f"http://127.0.0.1:{server.server_address[1]}/m.gguf"
            config["LOCAL_MODEL_SHA256"] = hashlib.sha256(blob).hexdigest()
            new = os.path.join(models, ns["LOCAL_MODEL_FILE"])
            with open(legacy + ".part", "wb") as f:
                f.write(b"half")
            try:
                win.start_local_download(True)
                check(win.local_cancel is not None, "升级没开始下载")
                check(pump_until(lambda: win.local_cancel is None, 60), "升级没下完")
                check(os.path.isfile(new) and open(new, "rb").read() == blob, "新模型没下到 models/")
                check(not os.path.exists(legacy) and not os.path.exists(legacy + ".part"),
                      "新模型下好以后旧模型没删掉")
                check(os.listdir(models) == [ns["LOCAL_MODEL_FILE"]], f"models/ 里多了东西：{os.listdir(models)}")
                check(win.local_ready() and not win.local_download.get_visible()
                      and "已下载" in win.local_model_row.get_subtitle(),
                      f"升级完应该是已下载：{win.local_model_row.get_subtitle()}")
            finally:
                config["LOCAL_MODEL_URL"], config["LOCAL_MODEL_SHA256"] = pinned
                server.shutdown()
                if os.path.exists(new):
                    os.unlink(new)
        finally:
            win.values["TranslateLlamaServer"] = saved
            for path in (legacy, legacy + ".part"):
                if os.path.exists(path):
                    os.unlink(path)
            win.refresh_local_translate()
        check(win.local_download.get_label() == "下载", "没有模型时按钮应该是「下载」")
    step("上一代翻译模型给升级，升级完删掉旧的", local_upgrade)

    def clipboard_sync():
        # 跨设备复制粘贴：设置界面这台和命令行起的两台「设备」真配一次对（都在本机，直接连，不靠广播）
        import subprocess
        tool = ns["sync_tool"]()
        if not tool:
            print("skip 跨设备复制粘贴（没有 wowtype-sync）")
            return
        state_file = ns["SYNC_STATE_FILE"]
        check(state_file.startswith(home), f"配对文件不在临时目录里：{state_file}")
        check(ns["sync_devices"]() == (False, []), "一开始应该没配对")
        check("还没有配对" in win.sync_pair_row.get_subtitle(), win.sync_pair_row.get_subtitle())
        check(not win.sync_unpair_button.get_visible(), "没配对时不该有「取消配对」")

        # 前面的步骤把开关都拨过一遍：局域网关着、又没有中转服务时配不了对（会提示至少开一个）
        win.values["ClipboardSyncLan"] = "False"
        win.on_sync_host(None)
        check(pump_until(lambda: win.sync_host is None, 30), "两条路都没开时应该马上结束")
        check(win.sync_host_info is None and not os.path.exists(state_file), "两条路都没开不该出配对码")
        win.values["ClipboardSyncLan"] = "True"

        # 配对码不是 6 位数字：不去找设备
        win.sync_code_row.set_text("12 34")
        win.on_sync_join(win.sync_code_row)
        check(not win.sync_busy, "配对码不对不该开始配对")

        # 1. 另一台显示配对码，这边输入
        other = os.path.join(home, "other.json")
        host = subprocess.Popen([tool, "pair-host", "--state", other, "--name", "另一台"],
                                stdout=subprocess.PIPE, text=True, encoding="utf-8")
        _word, code, _ttl, address = host.stdout.readline().split()
        os.environ["WOWTYPE_SYNC_PAIR_HOST"] = "127.0.0.1:" + address.rsplit(":", 1)[1]
        try:
            win.sync_code_row.set_text(f"{code[:3]} {code[3:]}")
            win.on_sync_join(win.sync_code_row)
            check(win.sync_busy and not win.sync_code_row.get_sensitive(), "配对时输入框应该灰掉")
            check(pump_until(lambda: not win.sync_busy, 30), "输入配对码以后一直没结果")
        finally:
            del os.environ["WOWTYPE_SYNC_PAIR_HOST"]
        check(host.wait(timeout=10) == 0 and host.stdout.read().strip() == "paired " + os.uname().nodename,
              "另一台没配上")
        check(ns["sync_devices"]() == (True, ["另一台"]), f"配对文件不对：{ns['sync_devices']()}")
        check("已经和 另一台 配对" in win.sync_pair_row.get_subtitle(), win.sync_pair_row.get_subtitle())
        check(win.sync_unpair_button.get_visible() and win.sync_code_row.get_text() == "",
              "配上以后应该能取消配对、输入框清空")
        check(os.stat(state_file).st_mode & 0o777 == 0o600, "配对文件应该只有自己能读")

        # 2. 这边显示配对码，第三台输入；先试一次取消
        win.on_sync_host(None)
        check(pump_until(lambda: win.sync_host_info is not None, 30), "没显示出配对码")
        check("配对码" in win.sync_pair_row.get_subtitle() and win.sync_host_button.get_label() == "取消",
              win.sync_pair_row.get_subtitle())
        win.on_sync_host(None)
        check(pump_until(lambda: win.sync_host is None, 30), "取消以后进程没结束")
        check(ns["sync_devices"]() == (True, ["另一台"]), "取消配对码不该动配对文件")
        win.on_sync_host(None)
        check(pump_until(lambda: win.sync_host_info is not None, 30), "没显示出配对码")
        code, address = win.sync_host_info
        third = os.path.join(home, "third.json")
        joined = subprocess.run([tool, "pair-join", code, "--state", third, "--name", "第三台",
                                 "--host", "127.0.0.1:" + address.rsplit(":", 1)[1]],
                                capture_output=True, text=True, encoding="utf-8", timeout=60)
        check(joined.returncode == 0, joined.stdout)
        check(pump_until(lambda: win.sync_host is None, 30), "配上以后没收尾")
        check(ns["sync_devices"]() == (True, ["另一台", "第三台"]), f"{ns['sync_devices']()}")
        # 三台拿到的是同一把组密钥
        keys = {json.load(open(path, encoding="utf-8"))["group_key"] for path in (state_file, other, third)}
        check(len(keys) == 1 and None not in keys, "三台设备的组密钥不一样")

        # 3. 中转服务的访问口令单独存 0600 的文件；地址不对时测试说得出原因（不联网）
        win.sync_token_row.set_text("relay-token")
        pump(0.8)
        key_file = ns["SYNC_RELAY_KEY_FILE"]
        check(open(key_file).read() == "relay-token\n" and os.stat(key_file).st_mode & 0o777 == 0o600,
              "访问口令没存成只有自己能读的文件")
        win.on_sync_ping(None)
        check(not win.sync_busy, "没填地址不该去测")
        win.sync_relay_row.set_text("http://relay.example.com")
        win.on_sync_ping(None)
        check(pump_until(lambda: not win.sync_busy, 30), "测试中转服务一直没结果")
        check("https://" in win.sync_ping_row.get_subtitle(), win.sync_ping_row.get_subtitle())
        check(win.values["ClipboardSyncRelayUrl"] == "http://relay.example.com", "地址没记下来")
        win.sync_relay_row.set_text("")
        win.sync_token_row.set_text("")
        pump(0.8)
        check(not os.path.exists(key_file), "口令清空以后文件应该删掉")

        # 4. 取消配对：只动这台
        for w in new_windows(win, lambda: win.on_sync_unpair(None)):
            w.close()
        check(ns["sync_devices"]()[0], "关掉确认框不该取消配对")
        win.sync_run([tool, "unpair", "--state", state_file], lambda ok, text: check(ok, text))
        check(pump_until(lambda: not win.sync_busy, 30), "取消配对一直没结果")
        check(ns["sync_devices"]() == (False, []) and not win.sync_unpair_button.get_visible(),
              "取消配对以后应该回到没配对")
        check(json.load(open(other, encoding="utf-8"))["group_key"], "取消配对不该动别的设备")
    step("跨设备复制粘贴：配对、取消、中转服务的口令", clipboard_sync)

    def developer_mode():
        # 开发者模式：拨开关先问，确认了才写进设置；记录能看条数、导出、清空
        devlog = ns["DEVLOG_FILE"]
        check(devlog.startswith(home), f"打字记录不在临时目录里：{devlog}")
        conf = lambda: open(ns["CONFIG_FILE"], encoding="utf-8").read()  # noqa: E731
        check(win.values["DeveloperMode"] == "False" and not win.devmode_row.get_active(), "默认该关着")
        check("什么都不记" in win.devlog_row.get_subtitle(), win.devlog_row.get_subtitle())
        check(not win.devlog_export.get_sensitive() and not win.devlog_clear.get_sensitive(), "没有记录时点不了")
        win.devmode_row.set_active(True)
        pump(0.3)
        check(not win.devmode_row.get_active() and win.values["DeveloperMode"] == "False",
              "没确认之前不该打开")
        check("DeveloperMode=True" not in conf(), "没确认之前不该写进设置")
        check("明文" in ns["DEVLOG_WARNING"] and "密码" in ns["DEVLOG_WARNING"], "警告里要说清楚记的是明文")
        win.devmode_dialog.close()
        pump(0.3)
        check(win.values["DeveloperMode"] == "False", "关掉弹窗算取消")
        win.developer_mode_confirmed()
        pump(0.4)  # 设置隔 250 ms 才存盘
        check(win.devmode_row.get_active() and "DeveloperMode=True" in conf(), "确认以后该打开并写进设置")
        check("还没有记录" in win.devlog_row.get_subtitle(), win.devlog_row.get_subtitle())
        # 输入法记了两条（这里替它写）
        os.makedirs(os.path.dirname(devlog), exist_ok=True)
        with open(devlog, "w", encoding="utf-8") as f:
            f.write('{"e":"commit","input":"nihao","text":"你好"}\n{"e":"backspace","text":"你好"}\n')
        win.refresh_devlog()
        check("2 条" in win.devlog_row.get_subtitle(), win.devlog_row.get_subtitle())
        check(win.devlog_export.get_sensitive() and win.devlog_clear.get_sensitive(), "有记录时该能导出、清空")
        out = os.path.join(home, "devlog-export.jsonl")
        win.devlog_export_to(out)
        check(open(out, encoding="utf-8").read().count("\n") == 2, "导出的该是两条")
        check("devlog" not in ns["collect_diagnostics"]() and "nihao" not in ns["collect_diagnostics"](),
              "导出日志不该带打字记录")
        # 关掉以后记录还在，说清楚不再记新的；清空以后没有了
        win.devmode_row.set_active(False)
        pump(0.4)
        check("DeveloperMode=True" not in conf(), "关掉该写回设置")
        check("不再记新的" in win.devlog_row.get_subtitle(), win.devlog_row.get_subtitle())
        win.devlog_clear_now()
        check(not os.path.exists(devlog) and "什么都不记" in win.devlog_row.get_subtitle(), "清空以后该没有记录")
    step("开发者模式：确认才打开，记录能导出和清空", developer_mode)
    dialog("清空打字记录（取消）", lambda: win.on_devlog_clear(None))
    dialog("恢复默认设置（确定）", win.on_reset, answer=1)
    dialog("导出日志（取消）", win.on_export_log)
    dialog("导入自定义词（取消）", win.on_import_words)
    dialog("从文件装词库（取消）", lambda: win.on_lexicon_from_file(None))

    def setup_button():
        # 测试的会话总线上没有 fcitx5：第一页给「一键设置」；没有插件，也就不提示重启输入法
        check(pump_until(lambda: win.status_button.get_visible()), "第一页没出「一键设置」按钮")
        check(win.status_button.get_label() == "一键设置", f"按钮是「{win.status_button.get_label()}」")
        check(not win.restart_hint_row.get_visible(), "没有插件时不该提示重启输入法")
    step("第一页：fcitx5 没在跑时给「一键设置」", setup_button)
    # 要问一句的几步：只打开、点「取消」/「稍后」，不真的重启、不跑 im-config
    dialog("一键设置：重启并添加（取消）",
           lambda: (setattr(win, "setup_state", ("restart", None)), win.on_add_to_group(None)), answer=0)
    dialog("一键设置：切到 fcitx5（取消）",
           lambda: (setattr(win, "setup_state", ("im-config", "ibus")), win.on_add_to_group(None)), answer=0)
    dialog("提示重启输入法（取消）", lambda: win.on_restart_hint(None), answer=0)
    dialog("更新装好后问要不要重启（稍后）",
           lambda: (setattr(win, "release", {"version": "9.9.9"}), win.ask_restart_after_update()), answer=0)

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
