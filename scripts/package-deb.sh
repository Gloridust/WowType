#!/usr/bin/env bash
# 打 .deb 包（CI 发版用，本地也能跑）。
#
#   scripts/package-deb.sh engine <版本> [输出目录]   输入法本体：fcitx5 插件 + 自检工具
#   scripts/package-deb.sh data <数据目录> [输出目录]  词库包：scripts/make-data.sh 的产物
#
# 本体包和当前系统的 fcitx5 版本绑定，要在目标发行版上（或同版本容器里）打。
# 包的版本号带发行版（0.1.0-1~ubuntu24.04）；文件名里不用 ~（GitHub Release 会把它改成 .）：
# wowtype_0.1.0_ubuntu24.04_amd64.deb。
set -euo pipefail
cd "$(dirname "$0")/.."

MODE=${1:?用法: package-deb.sh engine <版本> | data <数据目录>}
ARG=${2:?缺少参数}
OUT=$(realpath -m "${3:-dist}")
mkdir -p "$OUT"
HOMEPAGE=https://github.com/Gloridust/Wowtype
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

case "$MODE" in
engine)
  version=$ARG
  . /etc/os-release
  distro="${ID}${VERSION_ID:-}"
  debver="${version}-1~${distro}"

  cargo build --release --locked -p wowtype-core
  cmake -S fcitx5-addon -B "$work/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr >/dev/null
  cmake --build "$work/build" -j"$(nproc)"
  DESTDIR="$stage" cmake --install "$work/build" >/dev/null
  rm -rf "$stage/usr/include"          # 头文件只给开发用
  for bin in wowtype-check wowtype-show; do
    install -Dm755 "target/release/$bin" "$stage/usr/bin/$bin"
  done
  find "$stage/usr" -type f \( -name '*.so' -o -path '*/bin/*' \) -exec strip --strip-unneeded {} +

  doc="$stage/usr/share/doc/wowtype"
  install -Dm644 README.md "$doc/README.md"
  cat > "$doc/copyright" <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: WowType
Source: $HOMEPAGE

Files: *
License: MIT or Apache-2.0

Files: usr/share/wowtype/s2t.tsv
Comment: 由 OpenCC 的字符映射表生成（tools/opencc2tsv.py）
License: Apache-2.0
EOF

  # 运行时依赖交给 dpkg-shlibdeps 从 .so 里算（libfcitx5core、libstdc++ 等）
  mkdir -p "$work/debian"
  printf 'Source: wowtype\n\nPackage: wowtype\nArchitecture: any\n' > "$work/debian/control"
  mapfile -t elfs < <(find "$stage/usr" -type f \( -name '*.so' -o -path '*/bin/*' \))
  shlibs=$(cd "$work" && dpkg-shlibdeps -O "${elfs[@]}" 2>/dev/null | sed -n 's/^shlibs:Depends=//p')
  depends="${shlibs:+$shlibs, }fcitx5"

  DEB_FILE="wowtype_${version}_${distro}_$(dpkg --print-architecture).deb" \
  build_deb wowtype "$debver" "$(dpkg --print-architecture)" "$depends" \
    "WeChat-style pinyin input method for fcitx5" \
"拼音输入法：长句、半成品输入、按错键纠错、按用户习惯学习。
装完在 fcitx5 配置里添加「WowType」。需要词库包 wowtype-data-rime-ice，
或者自己把 lexicon.tsv 放到 ~/.local/share/wowtype/。"
  ;;

data)
  data=$ARG
  for f in lexicon.tsv english.txt LICENSE SOURCE.txt VERSION; do
    [[ -f "$data/$f" ]] || { echo "缺 $data/$f，先跑 scripts/make-data.sh" >&2; exit 1; }
  done
  date=$(<"$data/VERSION")
  version=${date//-/.}
  install -Dm644 "$data/lexicon.tsv" "$stage/usr/share/wowtype/lexicon.tsv"
  install -Dm644 "$data/english.txt" "$stage/usr/share/wowtype/english.txt"
  doc="$stage/usr/share/doc/wowtype-data-rime-ice"
  install -Dm644 "$data/SOURCE.txt" "$doc/SOURCE.txt"
  {
    echo "Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/"
    echo "Upstream-Name: rime-ice"
    echo "Source: https://github.com/iDvel/rime-ice"
    echo
    echo "Files: *"
    echo "License: GPL-3.0"
    echo
    sed 's/^$/./; s/^/ /' "$data/LICENSE"
  } > "$doc/copyright"
  build_deb wowtype-data-rime-ice "$version" all "" \
    "Chinese lexicon for WowType (from rime-ice)" \
"雾凇拼音（rime-ice）的中文词库与英文词表，转换成 WowType 的格式。
装到 /usr/share/wowtype/，WowType 启动时自动载入。"

  # 不用 deb 的系统：解压到 ~/.local/share/wowtype/ 即可
  tarball="$OUT/wowtype-data-rime-ice-$version.tar.gz"
  tar -C "$data" -czf "$tarball" lexicon.tsv english.txt LICENSE SOURCE.txt
  echo "$tarball"
  ;;

*)
  echo "未知模式 $MODE" >&2
  exit 2
  ;;
esac
