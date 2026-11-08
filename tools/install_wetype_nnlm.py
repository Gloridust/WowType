#!/usr/bin/env python3
"""把微信输入法自带的字级神经语言模型（nlrgpt2_nnlm.bin）放到 WowType 找得到的地方。

模型是腾讯的，WowType 不分发它。你本机有微信输入法的安装包或程序时，可以用这个脚本取出来：

    python3 tools/install_wetype_nnlm.py WeType-3.0.0.zip
    python3 tools/install_wetype_nnlm.py /Applications/WeType.app
    python3 tools/install_wetype_nnlm.py path/to/nlrgpt2_nnlm.bin

默认放到 ~/.local/share/wowtype/wetype/nlrgpt2_nnlm.bin（--dest 可改），会核对 MD5，
对不上就不装（别的版本的文件格式可能不同）。装完重启 fcitx5 生效。
"""

import argparse
import hashlib
import os
import sys
import zipfile

NAME = "nlrgpt2_nnlm.bin"
# 微信输入法 3.0.0（macOS）里的版本，WowType 按它写的读取代码
KNOWN_MD5 = {"edca685aba600497de298dd68a5d5e4d"}


def default_dest():
    base = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    return os.path.join(base, "wowtype", "wetype", NAME)


def read_model(src):
    if os.path.isdir(src):
        for root, _, files in os.walk(src):
            if NAME in files:
                with open(os.path.join(root, NAME), "rb") as f:
                    return f.read()
        sys.exit(f"{src} 里没有 {NAME}")
    if zipfile.is_zipfile(src):
        with zipfile.ZipFile(src) as z:
            hits = [n for n in z.namelist() if n.endswith("/" + NAME) or n == NAME]
            if not hits:
                sys.exit(f"{src} 里没有 {NAME}")
            return z.read(hits[0])
    with open(src, "rb") as f:
        return f.read()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source", help="微信输入法的安装包（.zip）、程序目录（.app）或模型文件本身")
    ap.add_argument("--dest", default=default_dest())
    ap.add_argument("--force", action="store_true", help="MD5 对不上也装（不保证能用）")
    args = ap.parse_args()
    data = read_model(args.source)
    md5 = hashlib.md5(data).hexdigest()
    if md5 not in KNOWN_MD5 and not args.force:
        sys.exit(f"MD5 是 {md5}，不是已知的版本；确定要装加 --force")
    os.makedirs(os.path.dirname(args.dest), exist_ok=True)
    tmp = args.dest + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, args.dest)
    print(f"已装到 {args.dest}（{len(data) / 1e6:.1f} MB，MD5 {md5}）。重启 fcitx5 生效。")


if __name__ == "__main__":
    main()
