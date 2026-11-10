#!/usr/bin/env bash
# 用 rpmbuild 从当前源码打 Fedora 安装包（.rpm）。
#   scripts/package-rpm.sh <版本> [输出目录]
# 需要 rpm-build rust cargo cmake extra-cmake-modules gcc-c++ pkgconf-pkg-config fcitx5-devel alsa-lib-devel；
# 词库用 scripts/make-data.sh 的产物，默认 dist/data（WOWTYPE_DATA_DIR=<目录> 可以改）。
#
# 版本号可以带 ~（0.3.6~git20261110.abc1234），RPM 把 ~ 排在正式版之前。
# 安装包和打包机器上的 fcitx5 版本绑定，要在目标 Fedora 版本上（或同版本容器里）打。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?用法: package-rpm.sh <版本> [输出目录]}
# RPM 的 Version 不能有连字符、空白或斜杠；不要静默改写标签。
[[ "$VERSION" =~ ^[[:alnum:]][[:alnum:]._+~^]*$ ]] || {
  echo "无效的 RPM 版本号: $VERSION" >&2
  exit 1
}
command -v rpmbuild >/dev/null || { echo "需要 rpmbuild（dnf install rpm-build）" >&2; exit 1; }
FCITX_VERSION=$(pkg-config --modversion Fcitx5Core) || {
  echo "找不到 Fcitx5Core.pc，请安装 fcitx5-devel 和 pkgconf-pkg-config" >&2; exit 1;
}
[[ "$FCITX_VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || {
  echo "无效的 Fcitx5Core 版本：$FCITX_VERSION" >&2; exit 1;
}
OUT=$(realpath -m "${2:-dist}")
DATA=$(realpath -m "${WOWTYPE_DATA_DIR:-dist/data}")
for f in lexicon.tsv english.txt words.lm LICENSE SOURCE.txt; do
  [[ -s "$DATA/$f" ]] || { echo "缺 $DATA/$f，先跑 scripts/make-data.sh" >&2; exit 1; }
done
mkdir -p "$OUT"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work"/{SOURCES,SPECS,BUILD,BUILDROOT,SRPMS}

# 只打包构建输入，不带现有 target/、CMake 缓存或 .git：rpmbuild 在独立目录从头编，
# 不依赖按键测试留下的二进制。
src="$work/source"
mkdir -p "$src/dist/data" "$src/packaging"
tar --exclude=target --exclude='build*' -cf - \
  Cargo.toml Cargo.lock core voice voice-daemon fcitx5-addon icons themes settings README.md |
  tar -xf - -C "$src"
cp "$DATA"/{lexicon.tsv,english.txt,words.lm,LICENSE,SOURCE.txt} "$src/dist/data/"
if [[ -f "$DATA/VERSION" ]]; then
  cp "$DATA/VERSION" "$src/dist/data/"
fi

# 各部分的许可证（和 deb 包的 copyright 内容一致）
cat > "$src/packaging/COPYRIGHT" <<'EOF'
WowType — https://github.com/Gloridust/WowType

程序（fcitx5 插件、设置界面、wowtype-check、wowtype-show、主题、图标）：
  MIT 或 Apache-2.0，二选一。

/usr/share/wowtype/s2t.tsv：
  由 OpenCC 的字符映射表生成（tools/opencc2tsv.py），Apache-2.0。

插件里编进去的 emoji 关键词（core/src/emoji/cldr.tsv）：
  来自 Unicode CLDR 和 emoji-test.txt，Copyright 1991-2026 Unicode, Inc.，
  Unicode-3.0（https://www.unicode.org/license.txt）。

/usr/share/wowtype/lexicon.tsv、/usr/share/wowtype/english.txt：
  转换自雾凇拼音 rime-ice（https://github.com/iDvel/rime-ice），GPL-3.0，
  全文见同目录 LICENSE.rime-ice，来源见 /usr/share/doc/wowtype/DATA-SOURCE.txt。

/usr/share/wowtype/words.lm：
  WowType 的词级语言模型，由 wowtype-lmbuild 从 LCCC 语料（thu-coai，MIT，
  https://huggingface.co/datasets/thu-coai/lccc）和中文维基百科（Wikipedia
  contributors，CC BY-SA 4.0，https://zh.wikipedia.org/）统计得到。
  按知识共享 署名-相同方式共享 4.0 国际许可协议授权：
  https://creativecommons.org/licenses/by-sa/4.0/legalcode
EOF

tar -czf "$work/SOURCES/wowtype-src.tar.gz" -C "$src" .
rm -rf "$src"

{
  printf '%%global wt_version %s\n' "$VERSION"
  printf '%%global wt_fcitx_version %s\n' "$FCITX_VERSION"
  cat <<'SPEC'
# 插件静态链接 Rust 核心，不单独出 debuginfo 包
%global debug_package %{nil}

Name:           wowtype
Version:        %{wt_version}
Release:        1%{?dist}
Summary:        WeChat-style pinyin input method for fcitx5
License:        (MIT OR Apache-2.0) AND Apache-2.0 AND Unicode-3.0 AND GPL-3.0-only AND CC-BY-SA-4.0
URL:            https://github.com/Gloridust/WowType
Source0:        wowtype-src.tar.gz
ExclusiveArch:  x86_64 aarch64

BuildRequires:  cargo
BuildRequires:  rust
BuildRequires:  cmake
BuildRequires:  extra-cmake-modules
BuildRequires:  gcc-c++
BuildRequires:  pkgconf-pkg-config
BuildRequires:  fcitx5-devel >= %{wt_fcitx_version}
BuildRequires:  alsa-lib-devel
# 自动 SONAME 依赖不表达新增加的 C++ API 符号，需要明确版本下限。
Requires:       fcitx5 >= %{wt_fcitx_version}
# 设置界面要 PyGObject + GTK 4 + libadwaita；不装也不影响打字
Recommends:     python3-gobject
Recommends:     gtk4
Recommends:     libadwaita
# PyGObject 载入 Gtk 时要 cairo-1.0.typelib，在这个包里
Recommends:     gobject-introspection
# emoji 候选要彩色 emoji 字体才画得出来
Recommends:     google-noto-color-emoji-fonts
# 互译用 curl 发请求
Recommends:     curl

%description
拼音输入法：长句、半成品输入、按错键纠错、按用户习惯学习。
自带雾凇拼音（rime-ice）词库和词级语言模型。
装完运行 wowtype-config --add-to-group（或在 fcitx5 配置里添加「WowType 拼音」），
设置在应用菜单「WowType 设置」里。

%prep
%setup -q -c -n wowtype-src

%build
cargo build --release --locked -p wowtype-core
cmake -S fcitx5-addon -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=%{_prefix} -DCMAKE_INSTALL_LIBDIR=%{_lib} \
  -DWOWTYPE_VERSION=%{version}
cmake --build build -j%{?_smp_build_ncpus}%{!?_smp_build_ncpus:2}

%install
DESTDIR=%{buildroot} cmake --install build
rm -rf %{buildroot}%{_includedir}
for bin in wowtype-check wowtype-show; do
  install -Dm755 target/release/$bin %{buildroot}%{_bindir}/$bin
done
install -m644 dist/data/lexicon.tsv dist/data/english.txt dist/data/words.lm \
  %{buildroot}%{_datadir}/wowtype/
doc=%{buildroot}%{_docdir}/wowtype
install -Dm644 README.md $doc/README.md
install -Dm644 dist/data/SOURCE.txt $doc/DATA-SOURCE.txt
if [ -f dist/data/VERSION ]; then
  install -Dm644 dist/data/VERSION $doc/DATA-VERSION
fi
lic=%{buildroot}%{_licensedir}/wowtype
install -Dm644 packaging/COPYRIGHT $lic/COPYRIGHT
install -Dm644 dist/data/LICENSE $lic/LICENSE.rime-ice

%files
%dir %{_licensedir}/wowtype
%license %{_licensedir}/wowtype/COPYRIGHT
%license %{_licensedir}/wowtype/LICENSE.rime-ice
%{_docdir}/wowtype/
%{_bindir}/wowtype-config
%{_bindir}/wowtype-check
%{_bindir}/wowtype-show
%{_libdir}/fcitx5/libwowtype.so
%{_datadir}/fcitx5/addon/wowtype.conf
%{_datadir}/fcitx5/inputmethod/wowtype.conf
%{_datadir}/fcitx5/themes/wowtype/
%{_datadir}/fcitx5/themes/wowtype-dark/
%{_datadir}/gnome-shell/extensions/wowtype-theme@gloridust.github.io/
%{_datadir}/applications/io.github.Gloridust.WowType.Config.desktop
%{_datadir}/icons/hicolor/*/apps/wowtype.*
%{_datadir}/wowtype/

%post
if [ "$1" -eq 1 ]; then
  echo "WowType 已安装。把它加进 fcitx5 的输入法列表：wowtype-config --add-to-group"
  echo "（或 fcitx5-configtool → 添加「WowType 拼音」），然后重启 fcitx5。"
fi

%changelog
SPEC
  # 构建日期写进 changelog（rpmbuild 用它定 SOURCE_DATE_EPOCH）
  printf '* %s WowType <gloridust@users.noreply.github.com> - %s-1\n- 从源码自动打包\n' \
    "$(LC_ALL=C date -u '+%a %b %d %Y')" "$VERSION"
} > "$work/SPECS/wowtype.spec"

rpmbuild -bb "$work/SPECS/wowtype.spec" \
  --define "_topdir $work" \
  --define "_rpmdir $OUT" \
  --define '_rpmfilename %%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm'
shopt -s nullglob
files=("$OUT"/wowtype-"$VERSION"-1*."$(uname -m)".rpm)
(( ${#files[@]} )) || { echo "rpmbuild 没有生成 wowtype-$VERSION 的 rpm" >&2; exit 1; }
printf '%s\n' "${files[@]}"
