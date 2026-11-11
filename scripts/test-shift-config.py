#!/usr/bin/env python3
"""「Shift 只给 WowType 用」回归测试：只加载设置脚本里的纯函数，不依赖 GTK 或 fcitx5。"""

import ast
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "settings" / "wowtype-config"
source = SCRIPT.read_text(encoding="utf-8")
tree = ast.parse(source, filename=str(SCRIPT))
functions = {
    "_xdg", "key_list", "bare_shift", "shift_conflicts", "without_shift", "with_keys",
    "shift_side_names", "fcitx_config_files", "parse_fcitx_hotkey", "saved_fcitx_hotkey",
    "fcitx_config_hint",
}
constants = {"FCITX_OPTION_NAMES", "FCITX_SHIFT_OPTIONS", "FCITX_HOTKEY_DEFAULTS",
             "SHIFT_SIDES", "SHIFT_NAMES"}
nodes = [node for node in tree.body if
         isinstance(node, ast.FunctionDef) and node.name in functions or
         isinstance(node, ast.Assign) and any(
             isinstance(target, ast.Name) and target.id in constants for target in node.targets)]
tool = dict(os=os)
exec(compile(ast.Module(body=nodes, type_ignores=[]), str(SCRIPT), "exec"), tool)


class ShiftConflictTests(unittest.TestCase):
    def test_default_alt_trigger(self):
        hotkey = tool["parse_fcitx_hotkey"]("")
        self.assertEqual(tool["shift_conflicts"](hotkey, "Both"), [("AltTriggerKeys", "Shift_L")])
        self.assertEqual(tool["shift_conflicts"](hotkey, "Right"), [])

    def test_every_hotkey_list(self):
        # fcitx5 的每一项全局快捷键用了单按 Shift 都会先吃掉它
        for option in tool["FCITX_SHIFT_OPTIONS"]:
            with self.subTest(option=option):
                hotkey = {option: {"0": "Shift_R"}}
                self.assertEqual(tool["shift_conflicts"](hotkey, "Both"), [(option, "Shift_R")])
                lists, taken = tool["without_shift"](hotkey, "Both")
                self.assertEqual(lists, {option: []})
                self.assertEqual(taken, [(option, "Shift_R")])
                self.assertEqual(tool["with_keys"]({option: ""}, taken), {option: ["Shift_R"]})
        self.assertEqual(len(tool["FCITX_SHIFT_OPTIONS"]), 8)

    def test_combos_are_not_bare_shift(self):
        hotkey = {"TriggerKeys": {"0": "Control+Shift_L"},
                  "EnumerateGroupBackwardKeys": {"0": "Super+Shift+space"},
                  "EnumerateForwardKeys": {"0": "Shift+Shift_R"}}
        self.assertEqual(tool["shift_conflicts"](hotkey, "Both"),
                         [("EnumerateForwardKeys", "Shift+Shift_R")])


class SavedConfigTests(unittest.TestCase):
    def test_parse_lists(self):
        text = (
            "[Hotkey]\n"
            "AltTriggerKeys=\n"
            "EnumerateWithTriggerKeys=True\n"
            "\n"
            "[Hotkey/TriggerKeys]\n"
            "0=Control+space\n"
            "1=\"Shift_R\"\n"
            "\n"
            "[Behavior]\n"
            "ShareInputState=No\n"
        )
        hotkey = tool["parse_fcitx_hotkey"](text)
        self.assertEqual(tool["key_list"](hotkey["AltTriggerKeys"]), [])
        self.assertEqual(tool["key_list"](hotkey["TriggerKeys"]), ["Control+space", "Shift_R"])
        self.assertEqual(tool["key_list"](hotkey["EnumerateGroupForwardKeys"]), ["Super+space"])
        self.assertEqual(tool["shift_conflicts"](hotkey, "Both"), [("TriggerKeys", "Shift_R")])

    def test_file_lookup_order(self):
        with tempfile.TemporaryDirectory() as root:
            home, system = os.path.join(root, "home"), os.path.join(root, "etc")
            os.makedirs(os.path.join(system, "fcitx5"))
            with open(os.path.join(system, "fcitx5", "config"), "w") as f:
                f.write("[Hotkey]\nAltTriggerKeys=\n")
            env = {"XDG_CONFIG_HOME": home, "XDG_CONFIG_DIRS": system}
            with patch.dict(os.environ, env, clear=False):
                os.environ.pop("SKIP_FCITX_USER_PATH", None)
                # 没有用户配置：读 /etc/xdg 那份（NixOS 的 settings.globalOptions 写在这里）
                hotkey, path = tool["saved_fcitx_hotkey"]()
                self.assertEqual(path, os.path.join(system, "fcitx5", "config"))
                self.assertEqual(tool["shift_conflicts"](hotkey, "Both"), [])
                # 有用户配置时只看它（没写 AltTriggerKeys 就是默认的左 Shift）
                os.makedirs(os.path.join(home, "fcitx5"))
                with open(os.path.join(home, "fcitx5", "config"), "w") as f:
                    f.write("[Behavior]\nShareInputState=No\n")
                hotkey, path = tool["saved_fcitx_hotkey"]()
                self.assertEqual(path, os.path.join(home, "fcitx5", "config"))
                self.assertEqual(tool["shift_conflicts"](hotkey, "Both"),
                                 [("AltTriggerKeys", "Shift_L")])
                # SKIP_FCITX_USER_PATH（NixOS ignoreUserConfig）：用户配置不算
                os.environ["SKIP_FCITX_USER_PATH"] = "1"
                hotkey, path = tool["saved_fcitx_hotkey"]()
                self.assertEqual(path, os.path.join(system, "fcitx5", "config"))
                self.assertIn("SKIP_FCITX_USER_PATH", tool["fcitx_config_hint"]())
                os.environ.pop("SKIP_FCITX_USER_PATH")

    def test_no_file_means_defaults(self):
        with tempfile.TemporaryDirectory() as root:
            env = {"XDG_CONFIG_HOME": os.path.join(root, "home"),
                   "XDG_CONFIG_DIRS": os.path.join(root, "etc")}
            with patch.dict(os.environ, env, clear=False):
                os.environ.pop("SKIP_FCITX_USER_PATH", None)
                hotkey, path = tool["saved_fcitx_hotkey"]()
                self.assertIsNone(path)
                self.assertEqual(tool["shift_conflicts"](hotkey, "Left"),
                                 [("AltTriggerKeys", "Shift_L")])


if __name__ == "__main__":
    unittest.main()
