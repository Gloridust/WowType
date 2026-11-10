#!/usr/bin/env python3
"""更新器回归测试：只加载实际脚本中的纯函数，不依赖 GTK 或显示服务器。"""

import ast
import hashlib
import io
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import urllib.request


SCRIPT = Path(__file__).resolve().parents[1] / "settings" / "wowtype-config"
source = SCRIPT.read_text(encoding="utf-8")
compile(source, str(SCRIPT), "exec")
tree = ast.parse(source, filename=str(SCRIPT))
functions = {
    "current_version", "dpkg_version", "read_os_release", "update_platform",
    "package_version", "install_commands", "plan_update", "download_updates", "http_open",
}
constants = {"VERSION", "HOMEPAGE", "INSTALL_GUIDE", "REPO", "ENGINE_PKG"}
nodes = [node for node in tree.body if
         isinstance(node, ast.FunctionDef) and node.name in functions or
         isinstance(node, ast.Assign) and any(
             isinstance(target, ast.Name) and target.id in constants for target in node.targets)]
window = next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == "SettingsWindow")
nodes.append(next(node for node in window.body if isinstance(node, ast.FunctionDef) and node.name == "run_installer"))
updater = dict(hashlib=hashlib, os=os, re=re, shlex=shlex, subprocess=subprocess, urllib=urllib)
exec(compile(ast.Module(body=nodes, type_ignores=[]), str(SCRIPT), "exec"), updater)


class UpdateTests(unittest.TestCase):
    def platform(self, info, machine="x86_64", immutable=False):
        return updater["update_platform"](info, machine, immutable)

    def test_supported_platforms(self):
        cases = [
            ({"ID": "ubuntu", "VERSION_ID": "24.04"}, "apt-get", "ubuntu24.04", "amd64"),
            ({"ID": "ubuntu", "VERSION_ID": "26.04"}, "apt-get", "ubuntu26.04", "amd64"),
            ({"ID": "debian", "VERSION_ID": "13"}, "apt-get", "debian13", "amd64"),
            ({"ID": "debian", "VERSION_ID": "13.1"}, "apt-get", "debian13", "amd64"),
            ({"ID": "linuxmint", "VERSION_ID": "22.2", "UBUNTU_CODENAME": "noble"}, "apt-get", "ubuntu24.04", "amd64"),
            ({"ID": "pop", "ID_LIKE": "ubuntu debian", "VERSION_CODENAME": "noble"}, "apt-get", "ubuntu24.04", "amd64"),
            ({"ID": "derivative", "UBUNTU_CODENAME": "resolute"}, "apt-get", "ubuntu26.04", "amd64"),
            ({"ID": "lmde", "DEBIAN_CODENAME": "trixie"}, "apt-get", "debian13", "amd64"),
            ({"ID": "derivative", "ID_LIKE": "debian", "VERSION_CODENAME": "trixie"}, "apt-get", "debian13", "amd64"),
            ({"ID": "arch"}, "pacman", "archlinux", "x86_64"),
            ({"ID": "endeavouros", "ID_LIKE": "arch"}, "pacman", "archlinux", "x86_64"),
            ({"ID": "garuda"}, "pacman", "archlinux", "x86_64"),
            ({"ID": "cachyos", "ID_LIKE": "arch"}, "pacman", "archlinux", "x86_64"),
            ({"ID": "fedora", "VERSION_ID": "44"}, "dnf", "fc44", "x86_64"),
        ]
        for info, manager, distro, arch in cases:
            with self.subTest(info=info):
                self.assertEqual(self.platform(info), (manager, distro, arch, ""))

    def test_unsupported_platforms_have_guidance(self):
        cases = [
            {"ID": "ubuntu", "VERSION_ID": "22.04"},
            {"ID": "debian", "VERSION_ID": "12"},
            {"ID": "debian", "VERSION_ID": "130.1"},
            {"ID": "linuxmint", "VERSION_ID": "22"},
            {"ID": "manjaro", "ID_LIKE": "arch"},
            {"ID": "derivative", "ID_LIKE": "arch manjaro"},
            {"ID": "rhel", "ID_LIKE": "fedora", "VERSION_ID": "10"},
            {"ID": "opensuse-tumbleweed", "ID_LIKE": "suse"},
            {"ID": "alpine", "VERSION_ID": "3.22"},
            {"ID": "nixos", "VERSION_ID": "26.05"},
            {"ID": "fedora", "VERSION_ID": "rawhide"},
            {},
        ]
        for info in cases:
            with self.subTest(info=info):
                manager, distro, arch, reason = self.platform(info)
                self.assertEqual((manager, distro, arch), ("", "", ""))
                self.assertIn(updater["INSTALL_GUIDE"], reason)
        self.assertIn("x86_64", self.platform({"ID": "arch"}, machine="aarch64")[3])

    def test_immutable_fedora_never_calls_dnf(self):
        for variant in ("silverblue", "kinoite", "sericea", "onyx", "coreos", "sway-atomic"):
            with self.subTest(variant=variant):
                info = {"ID": "fedora", "VERSION_ID": "44", "VARIANT_ID": variant}
                self.assertEqual(self.platform(info)[0], "")
                self.assertIn("rpm-ostree", self.platform(info)[3])
        self.assertEqual(self.platform({"ID": "fedora", "VERSION_ID": "44"}, immutable=True)[0], "")

    def test_os_release_is_data(self):
        data = "ID='linuxmint'\nID_LIKE=\"ubuntu debian\"\nUBUNTU_CODENAME=noble # base\nBAD='unterminated\n"
        with patch("builtins.open", return_value=io.StringIO(data)):
            info = updater["read_os_release"]()
        self.assertEqual(info, {"ID": "linuxmint", "ID_LIKE": "ubuntu debian", "UBUNTU_CODENAME": "noble"})

    def plan(self, info, assets, installed="0.3.8"):
        release = {"version": "0.3.9", "assets": assets}
        platform = self.platform(info)
        with patch.dict(updater, update_platform=lambda: platform, package_version=lambda _m: installed):
            return updater["plan_update"](release)

    def test_exact_assets_and_installed_package_required(self):
        cases = [
            ({"ID": "ubuntu", "VERSION_ID": "24.04"}, "wowtype_0.3.9_ubuntu24.04_amd64.deb"),
            ({"ID": "linuxmint", "UBUNTU_CODENAME": "noble"}, "wowtype_0.3.9_ubuntu24.04_amd64.deb"),
            ({"ID": "arch"}, "wowtype-0.3.9-1-x86_64.pkg.tar.zst"),
            ({"ID": "fedora", "VERSION_ID": "44"}, "wowtype-0.3.9-1.fc44.x86_64.rpm"),
        ]
        for info, name in cases:
            with self.subTest(info=info):
                assets = {name: "https://example.invalid/package", "SHA256SUMS": "https://example.invalid/sums"}
                self.assertEqual(self.plan(info, assets)[0], [(name, assets[name])])
                self.assertEqual(self.plan(info, assets, installed=None)[0], [])
                self.assertEqual(self.plan(info, {name: assets[name]})[0], [])
                self.assertEqual(self.plan(info, {"SHA256SUMS": assets["SHA256SUMS"]})[0], [])
        self.assertEqual(self.plan({"ID": "fedora", "VERSION_ID": "43"},
                                  {"wowtype-0.3.9-1.fc44.x86_64.rpm": "x", "SHA256SUMS": "s"})[0], [])

    def test_package_query_uses_native_manager(self):
        for manager, output, command, expected in [
            ("apt-get", "install ok installed\t0.3.8", "dpkg-query", "0.3.8"),
            ("pacman", "wowtype 0.3.8-1\n", "pacman", "0.3.8-1"),
            ("dnf", "0.3.8-1.fc44", "rpm", "0.3.8-1.fc44"),
        ]:
            with self.subTest(manager=manager), patch.object(subprocess, "run") as run:
                run.return_value = SimpleNamespace(returncode=0, stdout=output)
                self.assertEqual(updater["package_version"](manager), expected)
                self.assertEqual(run.call_args.args[0][0], command)
                run.return_value = SimpleNamespace(returncode=1, stdout="")
                self.assertIsNone(updater["package_version"](manager))

    def test_install_commands_use_argv_and_full_arch_upgrade(self):
        paths = ["/tmp/wow type; echo not-a-command.pkg.tar.zst"]
        self.assertEqual(updater["install_commands"]("pacman", paths), [
            ["pkexec", "pacman", "-Syu", "--noconfirm"],
            ["pkexec", "pacman", "-U", "--noconfirm", *paths],
        ])
        for manager in ("apt-get", "dnf"):
            self.assertEqual(updater["install_commands"](manager, paths), [["pkexec", manager, "install", "-y", *paths]])
        for manager, paths in (("dnf", []), ("pacman", ["relative.pkg"]), ("unknown", ["/tmp/package"])):
            with self.assertRaises(ValueError):
                updater["install_commands"](manager, paths)

    def test_checksum_enforcement(self):
        name, payload = "wowtype-0.3.9-1-x86_64.pkg.tar.zst", b"fixture package"
        digest = hashlib.sha256(payload).hexdigest()
        release = {"tag": "v0.3.9", "assets": {"SHA256SUMS": "sums"}}
        class Response(io.BytesIO):
            headers = {}
        for sums, ok in ((f"{digest}  {name}\n", True),
                         (f"{digest.upper()} *{name}\n", True),
                         (f"{'0' * 64}  {name}\n", False),
                         (f"{'0' * 64}  {name}\n{digest}  {name}\n", False),
                         (f"{digest}  {name}\n{digest}  {name}\n", False),
                         (f"invalid  {name}\n{digest}  {name}\n", False),
                         (f"{digest}  other-package\n", False),
                         (f"invalid  {name}\n", False)):
            with self.subTest(sums=sums), tempfile.TemporaryDirectory() as folder:
                def fetch(url, **_kwargs):
                    return Response(sums.encode() if url == "sums" else payload)
                with patch.dict(updater, UPDATE_DIR=folder, http_open=fetch):
                    if ok:
                        paths = updater["download_updates"](release, [(name, "package")], lambda *_: None)
                        self.assertEqual(Path(paths[0]).read_bytes(), payload)
                    else:
                        with self.assertRaises(RuntimeError):
                            updater["download_updates"](release, [(name, "package")], lambda *_: None)
                        self.assertFalse((Path(folder) / release["tag"] / name).exists())

    def test_download_rejects_path_traversal(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(updater, UPDATE_DIR=folder):
            with self.assertRaises(RuntimeError):
                updater["download_updates"]({"tag": "../elsewhere", "assets": {}}, [], lambda *_: None)
            with self.assertRaises(RuntimeError):
                updater["download_updates"]({"tag": "v0.3.9", "assets": {}}, [("../escape", "x")], lambda *_: None)

    def test_arch_installer_stops_after_failed_upgrade(self):
        for codes, expected_calls, updated in [([0, 0], 2, True), ([1], 1, False), ([0, 126], 2, False)]:
            with self.subTest(codes=codes):
                commands = []
                results = iter(codes)
                def start(command, _flags):
                    commands.append(command)
                    code = next(results)
                    proc = SimpleNamespace(
                        communicate_utf8_finish=lambda _r: (True, "package-manager output", None),
                        get_if_exited=lambda: True, get_exit_status=lambda: code)
                    proc.communicate_utf8_async = lambda _i, _c, cb: cb(proc, None)
                    return proc
                gui = SimpleNamespace(Subprocess=SimpleNamespace(new=start),
                                      SubprocessFlags=SimpleNamespace(STDOUT_PIPE=1, STDERR_MERGE=2))
                glib = SimpleNamespace(Error=RuntimeError, SOURCE_REMOVE=False)
                window = SimpleNamespace(progress=Mock(), install_row=Mock(), restart_row=Mock(),
                                         latest_row=Mock(), release={"version": "0.3.9"},
                                         install_failed=Mock(), toast=Mock(), updated=False)
                with patch.dict(updater, Gio=gui, GLib=glib, log=lambda _m: None,
                                update_platform=lambda: ("pacman", "archlinux", "x86_64", "")):
                    updater["run_installer"](window, ["/tmp/wowtype.pkg.tar.zst"])
                self.assertEqual(len(commands), expected_calls)
                self.assertEqual(window.updated, updated)
                self.assertEqual(window.install_failed.called, not updated)


if __name__ == "__main__":
    unittest.main(verbosity=2)
