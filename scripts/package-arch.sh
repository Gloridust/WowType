#!/usr/bin/env bash
# 用 makepkg 从当前源码打 Arch Linux 安装包（不要以 root 运行）。
#   scripts/package-arch.sh <版本> [输出目录]
# 需要 base-devel rust cmake extra-cmake-modules fcitx5 alsa-lib；
# 词库用 scripts/make-data.sh 的产物，默认 dist/data。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?用法: package-arch.sh <版本> [输出目录]}
# Arch 的 pkgver 不能有空白、冒号、斜杠或连字符；不要静默改写标签。
[[ "$VERSION" =~ ^[[:alnum:]][[:alnum:]._+~]*$ ]] || {
  echo "无效的 Arch 版本号: $VERSION" >&2
  exit 1
}
(( EUID != 0 )) || { echo "makepkg 不能以 root 运行，请用普通用户运行此脚本" >&2; exit 1; }
command -v makepkg >/dev/null || { echo "需要 Arch Linux 的 makepkg（pacman/base-devel）" >&2; exit 1; }
OUT=$(realpath -m "${2:-dist}")
DATA=$(realpath -m "${WOWTYPE_DATA_DIR:-dist/data}")
for f in lexicon.tsv english.txt words.lm LICENSE SOURCE.txt; do
  [[ -s "$DATA/$f" ]] || { echo "缺 $DATA/${f}，先跑 scripts/make-data.sh" >&2; exit 1; }
done
mkdir -p "$OUT"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# 只打包构建输入，不带现有 target/、CMake 缓存或 .git。makepkg 在独立目录重建，
# 不依赖按键测试留下的二进制，也不往 checkout 写 root 所有的构建文件。
mkdir -p "$work/source/dist/data"
tar --exclude=target --exclude='build*' -cf - \
  Cargo.toml Cargo.lock core voice voice-daemon fcitx5-addon icons themes settings README.md |
  tar -xf - -C "$work/source"
cp "$DATA"/{lexicon.tsv,english.txt,words.lm,LICENSE,SOURCE.txt} "$work/source/dist/data/"
if [[ -f "$DATA/VERSION" ]]; then
  cp "$DATA/VERSION" "$work/source/dist/data/"
fi
tar -cf "$work/wowtype-src.tar" -C "$work/source" .
rm -rf "$work/source"
checksum=$(sha256sum "$work/wowtype-src.tar")
{
  printf 'pkgver=%q\n' "$VERSION"
  printf "sha256sums=('%s')\n" "${checksum%% *}"
  cat <<'PKGBUILD'
pkgname=wowtype
pkgrel=1
pkgdesc='WeChat-style pinyin input method for fcitx5, with bundled dictionaries and language model'
arch=('x86_64')
url='https://github.com/Gloridust/WowType'
license=('MIT' 'Apache-2.0' 'GPL-3.0-only' 'CC-BY-SA-4.0' 'Unicode-3.0')
depends=('fcitx5' 'alsa-lib' 'gcc-libs' 'glibc' 'python')
makedepends=('rust' 'cmake' 'extra-cmake-modules' 'pkgconf')
optdepends=('python-gobject: settings app' 'gtk4: settings app' 'libadwaita: settings app'
            'noto-fonts-emoji: color emoji in candidates' 'curl: translate mode')
# makepkg handles ELF stripping and byte-sized .PKGINFO/.MTREE/.BUILDINFO.
# Avoid a second debug package in the CI release artifacts.
options=('!debug')
source=('wowtype-src.tar')
install=wowtype.install

prepare() {
  cd "$srcdir" || return
  cargo fetch --locked --target "$CARCH-unknown-linux-gnu"
}

build() {
  cd "$srcdir" || return
  cargo build --release --frozen -p wowtype-core --lib \
    --bin wowtype-check --bin wowtype-show
  cmake -S fcitx5-addon -B build -DCMAKE_BUILD_TYPE=None \
    -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib -DWOWTYPE_VERSION="$pkgver"
  cmake --build build -j"$(nproc)"
}

check() {
  cd "$srcdir" || return
  cargo test --release --frozen -p wowtype-core --lib
}

package() {
  cd "$srcdir" || return
  DESTDIR="$pkgdir" cmake --install build
  rm -r "$pkgdir/usr/include/wowtype"
  rmdir --ignore-fail-on-non-empty "$pkgdir/usr/include"
  for bin in wowtype-check wowtype-show; do
    install -Dm755 "target/release/$bin" "$pkgdir/usr/bin/$bin"
  done
  install -m644 dist/data/{lexicon.tsv,english.txt,words.lm} "$pkgdir/usr/share/wowtype/"
  install -Dm644 README.md "$pkgdir/usr/share/doc/wowtype/README.md"
  install -Dm644 dist/data/SOURCE.txt "$pkgdir/usr/share/doc/wowtype/DATA-SOURCE.txt"
  if [[ -f dist/data/VERSION ]]; then
    install -Dm644 dist/data/VERSION "$pkgdir/usr/share/doc/wowtype/DATA-VERSION"
  fi
  install -Dm644 dist/data/LICENSE "$pkgdir/usr/share/licenses/wowtype/LICENSE.rime-ice"
}
PKGBUILD
} > "$work/PKGBUILD"
cat > "$work/wowtype.install" <<'INSTALL'
post_install() {
  cat <<'EOF'
==> WowType 已安装。
  把 WowType 加进 fcitx5 的输入法列表：wowtype-config --add-to-group
  （或 fcitx5-configtool → 添加「WowType 拼音」）
  设置界面需要 python-gobject、gtk4、libadwaita，在应用菜单「WowType 设置」。
  Arch 上没有 im-config，别照 Ubuntu 教程跑它。
EOF
}
post_upgrade() {
  post_install
}
INSTALL

cd "$work"
# 不安装依赖、不提权。CI 先装好依赖，再用普通用户执行这里。
PKGDEST="$OUT" PKGEXT=.pkg.tar.zst BUILDDIR="$work" SRCDEST="$work" \
  SRCPKGDEST="$work" LOGDEST="$work" makepkg --noconfirm --force --nosign
file="$OUT/wowtype-$VERSION-1-$(uname -m).pkg.tar.zst"
[[ -s "$file" ]] || { echo "makepkg 没有生成 $file" >&2; exit 1; }
printf '%s\n' "$file"
