#!/usr/bin/env python3
"""设置契约：拿 spec/config.json、spec/lexicon-pack.json 对照 Linux 的设置界面和 fcitx5 插件。

  python3 scripts/test-config-contract.py                                   # 规格自检 + 设置界面
  python3 scripts/test-config-contract.py --fcitx5 <wowtype-config-dump>    # 再对照 fcitx5 插件

wowtype-config-dump 是 scripts/addon-test.sh 编出来的（fcitx5-addon/test/config_dump.cpp），导出插件里
WowtypeConfig 的键、类型、默认值、范围、可选值。macOS 那端在 macos/test.sh 里对照同一份规格。

设置界面（settings/wowtype-config）没有 .py 后缀，用 importlib 按路径导入。不用装 GTK：导入前塞一个假的 gi，
它在模块顶层只用到 gi.require_version、几个当基类的控件和 GObject.Property。XDG 目录都指到临时目录，不碰自己的配置。
"""

import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
import types

ROOT = Path(__file__).resolve().parents[1]
SPEC_DIR = ROOT / "spec"
SETTINGS = ROOT / "settings" / "wowtype-config"
ENDS = ("fcitx5", "settings", "macos")
TYPES = ("bool", "int", "enum", "string", "key")
# fcitx5 配置说明里的类型名
FCITX_TYPES = {"Boolean": "bool", "Integer": "int", "Enum": "enum", "String": "string", "Key": "key"}

failures = []
checked = 0


def check(ok, what, detail=""):
    global checked
    checked += 1
    if ok:
        return True
    failures.append(f"{what}" + (f"\n    {detail}" if detail else ""))
    return False


def same(actual, expected, what):
    return check(actual == expected, what, f"规格：{expected!r}\n    实际：{actual!r}")


def same_set(actual, expected, what):
    actual, expected = set(actual), set(expected)
    return check(actual == expected, what,
                 f"规格里有、这边没有：{sorted(expected - actual)}\n    这边有、规格里没有：{sorted(actual - expected)}")


# ---------------------------------------------------------------- 规格


def load_spec(name):
    with open(SPEC_DIR / name, encoding="utf-8") as f:
        return json.load(f)


def file_text(value):
    """规格里的值写进 wowtype.conf 的样子。"""
    if isinstance(value, bool):
        return "True" if value else "False"
    return str(value)


def default_for(setting, end):
    return file_text(setting.get("platformDefault", {}).get(end, setting["default"]))


def enum_values(setting):
    return [v if isinstance(v, str) else v["value"] for v in setting["values"]]


def settings_for(spec, end):
    return [s for s in spec["settings"] if end in s["platforms"]]


def out_of_range_cases(setting, policy, end):
    """数字项：(写进文件的值, 读出来应该是什么)。"""
    low, high = setting["min"], setting["max"]
    default = default_for(setting, end)
    cases = [(str(low), str(low)), (str(high), str(high))]
    for raw, edge in ((low - 1, low), (high + 1, high)):
        expect = {"default": default, "keep": str(raw), "clamp": str(edge)}[policy]
        cases.append((str(raw), expect))
    return cases


def check_spec(spec, pack):
    """规格本身说得通：键不重复、默认值合类型、在范围和可选值里，例子用到的键都有。"""
    keys = [s["key"] for s in spec["settings"]]
    check(len(keys) == len(set(keys)), "规格：键重复", sorted(k for k in keys if keys.count(k) > 1))
    by_key = {s["key"]: s for s in spec["settings"]}
    for s in spec["settings"]:
        key, kind, default = s["key"], s["type"], s["default"]
        if not check(kind in TYPES, f"规格：{key} 的类型 {kind!r} 不认识"):
            continue
        check(s["platforms"] and set(s["platforms"]) <= set(ENDS), f"规格：{key} 的 platforms 不对", s["platforms"])
        for end, value in s.get("platformDefault", {}).items():
            check(end in s["platforms"], f"规格：{key} 的 platformDefault 写了没有这一项的 {end}")
            check(type(value) is type(default), f"规格：{key} 在 {end} 的默认值类型不对", value)
            check(bool(s.get("why")), f"规格：{key} 两端默认值不一样，要写 why")
        expected_type = {"bool": bool, "int": int, "enum": str, "string": str, "key": str}[kind]
        check(type(default) is expected_type, f"规格：{key} 的默认值不是 {kind}", default)
        if kind == "int":
            check(s["min"] <= default <= s["max"], f"规格：{key} 的默认值不在 {s['min']}–{s['max']} 里", default)
        if kind == "enum":
            values = enum_values(s)
            check(len(values) == len(set(values)), f"规格：{key} 的可选值重复", values)
            check(default in values, f"规格：{key} 的默认值不在可选值里", default)
        for end, presets in s.get("presets", {}).items():
            check(end in s["platforms"], f"规格：{key} 的 presets 写了没有这一项的 {end}")
            check(default_for(s, end) in presets, f"规格：{key} 在 {end} 的默认值不在 presets 里", presets)
        missing = s.get("whenMissing")
        if missing:
            check(missing["ifNonEmpty"] in by_key, f"规格：{key} 的 whenMissing 用了没有的键 {missing['ifNonEmpty']}")
            for case in missing["cases"]:
                check(set(case["file"]) <= set(by_key), f"规格：{key} 的例子用了没有的键", case["file"])
    for case in spec["readRules"]["cases"]["items"]:
        for key in case["expect"]:
            check(key in by_key and set(by_key[key]["platforms"]) == set(ENDS),
                  f"规格：readRules.cases 用的 {key} 不是三端都有的键")
    policy = spec["readRules"]["outOfRange"]
    for end in ENDS:
        check(policy.get(end) in ("default", "keep", "clamp"), f"规格：readRules.outOfRange 没写 {end} 或写错了",
              policy.get(end))

    pattern = re.compile(re.escape(pack["assetPrefix"]) + "(" + pack["versionPattern"] + ")"
                         + re.escape(pack["assetSuffix"]))
    for case in pack["cases"]["assetVersion"]:
        match = pattern.fullmatch(case["name"])
        same(match.group(1) if match else None, case["version"], f"规格：词库包文件名的例子 {case['name']}")
    check(len(pack["files"]) == len(set(pack["files"])), "规格：词库包的 files 重复")


# ---------------------------------------------------------------- 设置界面（Python）


def fake_gi():
    """够设置界面在顶层用的假 gi：require_version 什么都不做，gi.repository 里随便取的名字都是空类，
    调用它（比如类体里的 GObject.Property(...)）也只得到一个空类。"""

    class Stub(type):
        def __getattr__(cls, name):
            return Stub(name, (), {})

        def __call__(cls, *_args, **_kwargs):
            return Stub(cls.__name__, (), {})

    gi = types.ModuleType("gi")
    gi.require_version = lambda *_args: None
    repository = types.ModuleType("gi.repository")
    repository.__getattr__ = lambda name: Stub(name, (), {})
    gi.repository = repository
    return {"gi": gi, "gi.repository": repository}


def import_settings(home):
    for name in ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"):
        os.environ[name] = os.path.join(home, name.lower())
    for name in ("WOWTYPE_CUSTOM", "WOWTYPE_LOG", "WOWTYPE_TRANSLATE_KEY_FILE", "WOWTYPE_VOICE_MODEL_DIR"):
        os.environ.pop(name, None)
    saved = {name: sys.modules.get(name) for name in ("gi", "gi.repository")}
    sys.modules.update(fake_gi())
    try:
        loader = importlib.machinery.SourceFileLoader("wowtype_config", str(SETTINGS))
        module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
        loader.exec_module(module)
    finally:
        for name, value in saved.items():
            if value is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = value
    return module


def read_settings_config(wc, home, entries):
    """把 entries 写成 wowtype.conf，用设置界面的 read_config 读回来。"""
    path = os.path.join(home, "wowtype.conf")
    with open(path, "w", encoding="utf-8") as f:
        f.write("".join(f"{key}={value}\n" for key, value in entries.items()))
    saved, wc.CONFIG_FILE = wc.CONFIG_FILE, path
    try:
        return wc.read_config()[0]
    finally:
        wc.CONFIG_FILE = saved


def read_settings_text(wc, home, text):
    """把 text 原样写成 wowtype.conf，用设置界面的 read_config 读回来。"""
    path = os.path.join(home, "wowtype.conf")
    with open(path, "w", encoding="utf-8") as f:
        f.write(text + "\n")
    saved, wc.CONFIG_FILE = wc.CONFIG_FILE, path
    try:
        return wc.read_config()[0]
    finally:
        wc.CONFIG_FILE = saved


def check_settings(spec, wc, home):
    mine = settings_for(spec, "settings")
    same_set(wc.DEFAULTS, [s["key"] for s in mine], "设置界面：DEFAULTS 的键")
    for s in mine:
        if s["key"] in wc.DEFAULTS:
            same(wc.DEFAULTS[s["key"]], default_for(s, "settings"), f"设置界面：{s['key']} 的默认值")
    by_key = {s["key"]: s for s in spec["settings"]}

    same(wc.RANGES, {s["key"]: (s["min"], s["max"]) for s in mine if s["type"] == "int"}, "设置界面：RANGES")
    same({k: list(v) for k, v in wc.ENUMS.items()},
         {s["key"]: enum_values(s) for s in mine if s["type"] == "enum"}, "设置界面：ENUMS（读文件时认的枚举值）")

    # 选项列表：(界面上的名字, 存盘名)
    lists = {"ShuangpinScheme": wc.SHUANGPIN_SCHEMES, "ShiftToggle": wc.SHIFT_TOGGLES,
             "InitialMode": wc.INITIAL_MODES, "ArrowKeys": wc.ARROW_KEYS,
             "SelectKeys": wc.SELECT_KEYS, "PunctuationStyle": wc.PUNCT_STYLES}
    for key, items in lists.items():
        same([value for _label, value in items], enum_values(by_key[key]), f"设置界面：{key} 的选项")
    same([(label, value) for label, value in wc.SHUANGPIN_SCHEMES],
         [(v["name"], v["value"]) for v in by_key["ShuangpinScheme"]["values"]], "设置界面：双拼方案的名字")
    same([tuple(item) for item in wc.TRANSLATE_LANGUAGES],
         [(v["name"], v["value"], v["english"]) for v in by_key["TranslateTarget"]["values"]],
         "设置界面：TRANSLATE_LANGUAGES")
    same([tuple(item) for item in wc.TRANSLATE_PROVIDERS],
         [(p["name"], p["url"], p["model"]) for p in spec["translateProviders"]["items"]],
         "设置界面：TRANSLATE_PROVIDERS")
    same([value for _label, value in wc.EMOJI_KEYS], by_key["EmojiKey"]["presets"]["settings"],
         "设置界面：EMOJI_KEYS")
    same([value for _label, value in wc.VOICE_KEYS], by_key["VoiceKey"]["presets"]["settings"],
         "设置界面：VOICE_KEYS")
    same_set([key for key, _label in wc.FUZZY_GROUPS], [s["key"] for s in mine if s.get("group") == "fuzzy"],
             "设置界面：FUZZY_GROUPS 的键")

    # 读文件的规矩
    for s in mine:
        missing = s.get("whenMissing")
        for case in missing["cases"] if missing else ():
            same(read_settings_config(wc, home, case["file"])[s["key"]], file_text(case["expect"]),
                 f"设置界面：文件是 {case['file']} 时 {s['key']}")
    policy = spec["readRules"]["outOfRange"]["settings"]
    for s in mine:
        if s["type"] == "int":
            for raw, expect in out_of_range_cases(s, policy, "settings"):
                same(read_settings_config(wc, home, {s["key"]: raw})[s["key"]], expect,
                     f"设置界面：{s['key']}={raw} 读出来")
    for case in spec["readRules"]["cases"]["items"]:
        values = read_settings_text(wc, home, case["file"])
        for key, expect in case["expect"].items():
            same(values[key], expect, f"设置界面：文件是 {case['file']!r} 时 {key}")


def make_tar(path, members):
    """members：[(名字, 内容)]，内容是 None 的是目录。"""
    with tarfile.open(path, "w:gz") as tar:
        for name, text in members:
            info = tarfile.TarInfo(name)
            if text is None:
                info.type = tarfile.DIRTYPE
                tar.addfile(info)
            else:
                data = text.encode("utf-8")
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))


def try_install(wc, tmp, members, minimum):
    """装一个词库包，装上了返回 True，被拒（ValueError）返回 False。"""
    pack = os.path.join(tmp, "pack.tar.gz")
    folder = os.path.join(tmp, "dicts", "wanxiang")
    make_tar(pack, members)
    saved, wc.LEXICON_PACK_MIN = wc.LEXICON_PACK_MIN, minimum
    try:
        wc.install_lexicon_pack(pack, folder)
        return True
    except ValueError:
        return False
    finally:
        wc.LEXICON_PACK_MIN = saved
        wc.remove_lexicon_pack(folder)


class FakeResponse(io.BytesIO):
    def __init__(self, data):
        super().__init__(data)
        self.headers = {"Content-Length": str(len(data))}


def check_settings_lexicon(pack, wc, home):
    same(sorted(wc.LEXICON_PACK_FILES), sorted(pack["files"]), "设置界面：LEXICON_PACK_FILES")
    same(wc.LEXICON_PACK_MIN, pack["minEntries"], "设置界面：LEXICON_PACK_MIN")
    same(os.path.relpath(wc.WANXIANG_DIR, wc.DATA_DIR), pack["folder"], "设置界面：WANXIANG_DIR（在数据目录下）")
    same(os.path.relpath(wc.WANXIANG_LEXICON, wc.WANXIANG_DIR), "lexicon.tsv", "设置界面：WANXIANG_LEXICON")
    cases = pack["cases"]
    for case in cases["assetVersion"]:
        match = wc.WANXIANG_ASSET.fullmatch(case["name"])
        same(match.group(1) if match else None, case["version"], f"设置界面：词库包文件名 {case['name']}")
    for case in cases["pickAsset"]:
        found = wc.find_lexicon_asset({"assets": {name: f"u{i}" for i, name in enumerate(case["names"])}})
        same(found[0] if found else None, case["pick"], f"设置界面：从 {case['names']} 里挑词库包")

    # SHA256SUMS：download_updates 从假的发布页下（要的文件内容是空的）
    wanted = cases["checksums"]["wanted"]
    served = {}

    def fake_open(url, timeout=30):
        return FakeResponse(served[url])
    saved = wc.http_open, wc.UPDATE_DIR
    wc.http_open, wc.UPDATE_DIR = fake_open, os.path.join(home, "updates")
    try:
        for case in cases["checksums"]["cases"]:
            served.clear()
            served.update({"sums": case["text"].encode("utf-8"), "pack": b""})
            release = {"tag": "v9.9.9", "assets": {pack["checksumFile"]: "sums", wanted: "pack"}}
            try:
                wc.download_updates(release, [(wanted, "pack")], lambda *_a: None)
                ok = True
            except RuntimeError:
                ok = False
            same(ok, case["digest"] is not None, f"设置界面：{pack['checksumFile']} 是 {case['text']!r} 时装不装")
        # 能装的例子取到的校验值都得是空文件的（下载下来的内容是空的）
        for case in cases["checksums"]["cases"]:
            check(case["digest"] in (None, hashlib.sha256(b"").hexdigest()),
                  "规格：checksums 能装的例子的 digest 要是空文件的 SHA256", case["digest"])
    finally:
        wc.http_open, wc.UPDATE_DIR = saved

    with tempfile.TemporaryDirectory(dir=home) as tmp:
        lexicon = "ni\t你\n"
        for case in cases["entryName"]:
            raw, name = case["raw"], case["name"]
            members = [] if name == "lexicon.tsv" else [("lexicon.tsv", lexicon)]
            members.append((raw, None if name == "" else lexicon))
            same(try_install(wc, tmp, members, 1), name is not None, f"设置界面：包里有 {raw!r} 时装不装")
        for case in cases["lexicon"]["cases"]:
            members = [("lexicon.tsv", case["text"]), ("VERSION", "1\n")]
            count = case["count"]
            if count is None:
                same(try_install(wc, tmp, members, 0), False, f"设置界面：lexicon.tsv 是 {case['text']!r} 时不装")
            else:
                same(try_install(wc, tmp, members, count), True,
                     f"设置界面：lexicon.tsv 是 {case['text']!r} 时有 {count} 条（最少 {count} 条能装）")
                same(try_install(wc, tmp, members, count + 1), False,
                     f"设置界面：lexicon.tsv 是 {case['text']!r} 时有 {count} 条（最少 {count + 1} 条不装）")
        for i, case in enumerate(cases["installedVersion"]):
            folder = os.path.join(tmp, f"installed{i}")
            os.makedirs(folder)
            for name, text in case["files"].items():
                with open(os.path.join(folder, name), "w", encoding="utf-8") as f:
                    f.write(text)
            same(wc.lexicon_pack_version(folder), case["version"], f"设置界面：装好的词库包 {case['files']} 的版本")


# ---------------------------------------------------------------- fcitx5 插件（C++）


def run_dump(exe, *args):
    result = subprocess.run([exe, *args], capture_output=True, text=True, timeout=30)
    if result.returncode != 0:
        raise SystemExit(f"{exe} {' '.join(args)} 失败：{result.stderr}")
    return json.loads(result.stdout)


def check_fcitx5(spec, exe):
    options = run_dump(exe)["options"]
    external = [o["key"] for o in options if o["type"] == "External"]
    same(external, spec["fcitx5External"]["keys"], "fcitx5：ExternalOption")
    options = {o["key"]: o for o in options if o["type"] != "External"}
    mine = settings_for(spec, "fcitx5")
    same_set(options, [s["key"] for s in mine], "fcitx5：WowtypeConfig 的键")
    for s in mine:
        key = s["key"]
        option = options.get(key)
        if option is None:
            continue
        same(FCITX_TYPES.get(option["type"], option["type"]), s["type"], f"fcitx5：{key} 的类型")
        same(option["default"], default_for(s, "fcitx5"), f"fcitx5：{key} 的默认值")
        if s["type"] == "int":
            same((option["min"], option["max"]), (str(s["min"]), str(s["max"])), f"fcitx5：{key} 的范围")
        if s["type"] == "enum":
            same(option["values"], enum_values(s), f"fcitx5：{key} 的可选值")
            names = [v["name"] for v in s["values"] if isinstance(v, dict) and "name" in v]
            if names:
                same(option["names"], names, f"fcitx5：{key} 的可选值的名字（EnumI18n）")

    for s in mine:
        missing = s.get("whenMissing")
        for case in missing["cases"] if missing else ():
            values = run_dump(exe, "--load", *(f"{k}={v}" for k, v in case["file"].items()))["values"]
            same(values.get(s["key"]), file_text(case["expect"]), f"fcitx5：文件是 {case['file']} 时 {s['key']}")
    policy = spec["readRules"]["outOfRange"]["fcitx5"]
    for s in mine:
        if s["type"] == "int":
            for raw, expect in out_of_range_cases(s, policy, "fcitx5"):
                values = run_dump(exe, "--load", f"{s['key']}={raw}")["values"]
                same(values.get(s["key"]), expect, f"fcitx5：{s['key']}={raw} 读出来")
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "wowtype.conf")
        for case in spec["readRules"]["cases"]["items"]:
            with open(path, "w", encoding="utf-8") as f:
                f.write(case["file"] + "\n")
            values = run_dump(exe, "--load-file", path)["values"]
            for key, expect in case["expect"].items():
                same(values.get(key), expect, f"fcitx5：文件是 {case['file']!r} 时 {key}")


def main(argv):
    fcitx5 = None
    if argv[:1] == ["--fcitx5"] and len(argv) == 2:
        fcitx5 = argv[1]
    elif argv:
        print(__doc__)
        return 2
    spec, pack = load_spec("config.json"), load_spec("lexicon-pack.json")
    check_spec(spec, pack)
    with tempfile.TemporaryDirectory() as home:
        wc = import_settings(home)
        check_settings(spec, wc, home)
        check_settings_lexicon(pack, wc, home)
    ends = "规格、设置界面"
    if fcitx5:
        check_fcitx5(spec, fcitx5)
        ends += "、fcitx5 插件"
    if failures:
        print(f"设置契约对不上（{len(failures)} 处）。改的是设置项就先改 spec/，再让各端跟上：\n")
        for failure in failures:
            print(f"FAIL {failure}")
        return 1
    print(f"config contract ok（{ends}，{checked} 项）")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
