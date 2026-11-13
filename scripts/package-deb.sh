#!/usr/bin/env bash
# 打 .deb 包（CI 发版用，本地也能跑）。
#
#   scripts/package-deb.sh engine <版本> [输出目录]   安装包：fcitx5 插件 + 设置界面 + 自检工具 + 词库
#   scripts/package-deb.sh data <数据目录> [输出目录]  不用 deb 的系统用的词库压缩包
#
# 词库（scripts/make-data.sh 的产物）直接打进安装包，用户只装一个文件。
# 数据目录默认 dist/data，WOWTYPE_DATA_DIR=<目录> 可以改。
# 以前词库是单独的 wowtype-data-rime-ice 包；新包 Conflicts/Replaces 它，apt 装新包时会顺手把它删掉。
#
# 安装包和当前系统的 fcitx5 版本绑定，要在目标发行版上（或同版本容器里）打。
# 包的版本号带发行版（0.1.0-1~ubuntu24.04）；文件名里不用 ~（GitHub Release 会把它改成 .）：
# wowtype_0.1.0_ubuntu24.04_amd64.deb。发行版默认取 os-release 的 $ID$VERSION_ID，
# WOWTYPE_DISTRO=<名字> 可以指定（CI 传矩阵里的名字，免得镜像的版本号变成 25.0.x 时和一键安装对不上）。
set -euo pipefail
cd "$(dirname "$0")/.."

MODE=${1:?用法: package-deb.sh engine <版本> | data <数据目录>}
ARG=${2:?缺少参数}
OUT=$(realpath -m "${3:-dist}")
mkdir -p "$OUT"
HOMEPAGE=https://github.com/Gloridust/WowType
MAINTAINER="Gloridust <gloridust@users.noreply.github.com>"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stage="$work/stage"

build_deb() { # <包名> <版本> <架构> <依赖> <简介> <详细说明>
  local name=$1 version=$2 arch=$3 depends=$4 summary=$5 body=$6
  mkdir -p "$stage/DEBIAN"
  {
    echo "Package: $name"
    echo "Version: $version"
    echo "Architecture: $arch"
    echo "Maintainer: $MAINTAINER"
    echo "Installed-Size: $(du -sk --exclude=DEBIAN "$stage" | cut -f1)"
    [[ -n "$depends" ]] && echo "Depends: $depends"
    [[ -n "${RECOMMENDS:-}" ]] && echo "Recommends: $RECOMMENDS"
    [[ -n "${REPLACES:-}" ]] && printf 'Conflicts: %s\nReplaces: %s\nProvides: %s\n' \
      "$REPLACES" "$REPLACES" "$REPLACES"
    echo "Section: utils"
    echo "Priority: optional"
    echo "Homepage: $HOMEPAGE"
    echo "Description: $summary"
    sed 's/^/ /' <<<"$body"
  } > "$stage/DEBIAN/control"
  local file="$OUT/${DEB_FILE:-${name}_${version}_${arch}.deb}"
  dpkg-deb --build --root-owner-group -Zxz "$stage" "$file" >/dev/null
  echo "$file"
}

data_copyright() { # <数据目录>：copyright 里词库那几段
  echo "Files: usr/share/wowtype/lexicon.tsv usr/share/wowtype/english.txt"
  echo "Comment: 转换自雾凇拼音 rime-ice（https://github.com/iDvel/rime-ice），见 DATA-SOURCE.txt"
  echo "License: GPL-3.0"
  sed 's/^$/./; s/^/ /' "$1/LICENSE"
  echo
  echo "Files: usr/share/wowtype/words.lm"
  echo "Copyright: WowType contributors; statistics derived from LCCC (thu-coai, MIT)"
  echo " and Chinese Wikipedia (Wikipedia contributors, CC BY-SA 4.0)"
  echo "License: CC-BY-SA-4.0"
  echo " Word-level language model built by wowtype-lmbuild from the LCCC corpus"
  echo " (https://huggingface.co/datasets/thu-coai/lccc) and Chinese Wikipedia"
  echo " (https://zh.wikipedia.org/). Licensed under the Creative Commons"
  echo " Attribution-ShareAlike 4.0 International License:"
  echo " https://creativecommons.org/licenses/by-sa/4.0/legalcode"
}

check_data() { # <数据目录>
  for f in lexicon.tsv english.txt words.lm LICENSE SOURCE.txt VERSION; do
    [[ -f "$1/$f" ]] || { echo "缺 $1/$f，先跑 scripts/make-data.sh" >&2; exit 1; }
  done
}

case "$MODE" in
engine)
  version=$ARG
  data=${WOWTYPE_DATA_DIR:-dist/data}
  check_data "$data"
  . /etc/os-release
  distro="${WOWTYPE_DISTRO:-${ID}${VERSION_ID:-}}"
  debver="${version}-1~${distro}"

  cargo build --release --locked -p wowtype-core
  cmake -S fcitx5-addon -B "$work/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
    -DWOWTYPE_VERSION="$version" >/dev/null
  cmake --build "$work/build" -j"$(nproc)"
  DESTDIR="$stage" cmake --install "$work/build" >/dev/null
  rm -rf "$stage/usr/include"          # 头文件只给开发用
  for bin in wowtype-check wowtype-show; do
    install -Dm755 "target/release/$bin" "$stage/usr/bin/$bin"
  done
  # 只处理 ELF（/usr/bin 里还有 Python 写的设置界面 wowtype-config）
  is_elf() { [[ "$(head -c4 "$1" | od -An -c | tr -d ' ')" == '177ELF' ]]; }
  mapfile -t elfs < <(find "$stage/usr" -type f \( -name '*.so' -o -path '*/bin/*' \) |
                      while read -r f; do is_elf "$f" && echo "$f"; done)
  strip --strip-unneeded "${elfs[@]}"

  # 词库：雾凇拼音（GPL-3.0）+ WowType 的词级语言模型（CC BY-SA 4.0）
  for f in lexicon.tsv english.txt words.lm; do
    install -Dm644 "$data/$f" "$stage/usr/share/wowtype/$f"
  done
  doc="$stage/usr/share/doc/wowtype"
  install -Dm644 README.md "$doc/README.md"
  install -Dm644 "$data/SOURCE.txt" "$doc/DATA-SOURCE.txt"
  install -Dm644 "$data/VERSION" "$doc/DATA-VERSION"
  {
  cat <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: WowType
Source: $HOMEPAGE

Files: *
License: MIT or Apache-2.0

Files: usr/share/wowtype/s2t.tsv
Comment: 由 OpenCC 的字符映射表生成（tools/opencc2tsv.py）
License: Apache-2.0

Files: usr/lib/*/fcitx5/libwowtype.so
Comment: 编进去的 emoji 关键词（core/src/emoji/cldr.tsv）来自 Unicode CLDR 和 emoji-test.txt
Copyright: 1991-2026 Unicode, Inc.
License: Unicode-3.0
 https://www.unicode.org/license.txt

EOF
  data_copyright "$data"
  } > "$doc/copyright"

  # 运行时依赖交给 dpkg-shlibdeps 从 .so 里算（libfcitx5core、libstdc++ 等）
  mkdir -p "$work/debian"
  printf 'Source: wowtype\n\nPackage: wowtype\nArchitecture: any\n' > "$work/debian/control"
  shlibs=$(cd "$work" && dpkg-shlibdeps -O "${elfs[@]}" 2>/dev/null | sed -n 's/^shlibs:Depends=//p')
  depends="${shlibs:+$shlibs, }fcitx5"

  # 设置界面要 PyGObject + GTK 4 + libadwaita；不装也不影响打字
  # emoji 要彩色 emoji 字体才画得出来（桌面版系统一般都装了）；互译用 curl 发请求
  RECOMMENDS="python3-gi, gir1.2-gtk-4.0, gir1.2-adw-1, fonts-noto-color-emoji, curl" \
  REPLACES="wowtype-data-rime-ice" \
  DEB_FILE="wowtype_${version}_${distro}_$(dpkg --print-architecture).deb" \
  build_deb wowtype "$debver" "$(dpkg --print-architecture)" "$depends" \
    "WeChat-style pinyin input method for fcitx5" \
"拼音输入法：长句、半成品输入、按错键纠错、按用户习惯学习。
自带雾凇拼音（rime-ice）词库和词级语言模型。
装完在 fcitx5 配置里添加「WowType」，设置在应用菜单「WowType 设置」里。"
  ;;

data)
  data=$ARG
  check_data "$data"
  version=$(<"$data/VERSION")
  version=${version//-/.}
  # 不用 deb 的系统：解压到 ~/.local/share/wowtype/ 即可
  tarball="$OUT/wowtype-data-rime-ice-$version.tar.gz"
  # 可复现：固定文件顺序、时间和属主，gzip 不写时间戳。内容不变时每次打出来的包
  # sha256 都一样，打包脚本（如 AUR）钉住的校验和不会因为重新发版而失效。
  tar -C "$data" --sort=name --mtime="@${SOURCE_DATE_EPOCH:-0}" \
    --owner=0 --group=0 --numeric-owner -cf - \
    lexicon.tsv english.txt words.lm LICENSE SOURCE.txt | gzip -n >"$tarball"
  echo "$tarball"
  ;;

*)
  echo "未知模式 $MODE" >&2
  exit 2
  ;;
esac
