"""wetype-assets 各脚本共用的小工具：读文件、边界检查、安全写出。

这些脚本只读本机已安装的微信输入法，不联网；唯一会写文件的是用户用参数指定的输出路径，
而且拒绝写进 WowType 仓库目录（防止把提取出的东西误提交）。
"""

import json
import os
import struct
import sys

APP = "/Library/Input Methods/WeType.app"
RESOURCES = os.path.join(APP, "Contents", "Resources")
IME_DATA = os.path.join(RESOURCES, "imeData.bundle")
VAD_DIR = os.path.join(RESOURCES, "vad")
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


class FormatError(Exception):
    """文件格式和预期不符（版本不同、文件损坏、选错了文件）。"""


def read_bytes(path, limit=None):
    """读文件（limit 给了就只读前 limit 字节）；文件不在、读不了时报错退出。"""
    if not os.path.isfile(path):
        sys.exit(f"不是文件：{path}")
    try:
        with open(path, "rb") as f:
            return f.read() if limit is None else f.read(limit)
    except OSError as e:
        sys.exit(f"读不了 {path}：{e}")


def need_dir(path):
    if not os.path.isdir(path):
        sys.exit(f"不是目录：{path}（微信输入法装在 {APP} 吗？）")
    return path


def need(data, offset, size, what):
    """确认 data[offset:offset+size] 在范围内。"""
    if offset < 0 or size < 0 or offset + size > len(data):
        raise FormatError(f"{what}：偏移 0x{offset:x} + {size} 超出文件（{len(data)} 字节）")


def unpack(fmt, data, offset, what):
    need(data, offset, struct.calcsize(fmt), what)
    return struct.unpack_from(fmt, data, offset)


def uvarint(buf, i, what="varint"):
    """protobuf 风格的无符号变长整数，返回 (值, 下一个位置)。"""
    value = 0
    for shift in range(0, 64, 7):
        need(buf, i, 1, what)
        byte = buf[i]
        i += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, i
    raise FormatError(f"{what}：变长整数超过 10 字节")


def open_output(path):
    """打开用户指定的输出文件。拒绝写进 WowType 仓库，避免提取出的数据被误提交。"""
    real = os.path.realpath(path)
    if os.path.commonpath([real, os.path.realpath(REPO)]) == os.path.realpath(REPO):
        sys.exit(f"不写进 WowType 仓库（{REPO}）：提取出的数据不能入库，换个目录，比如 ~/wetype-dump/")
    parent = os.path.dirname(real)
    if not os.path.isdir(parent):
        sys.exit(f"输出目录不存在：{parent}")
    return open(real, "w", encoding="utf-8", newline="\n")


def print_json(obj):
    print(json.dumps(obj, ensure_ascii=False, indent=2))


def run(main):
    """跑 main()，格式不符时给一句话的错误而不是 traceback。"""
    try:
        main()
    except FormatError as e:
        sys.exit(f"格式不符（版本不同或选错了文件？）：{e}")
    except BrokenPipeError:
        pass
