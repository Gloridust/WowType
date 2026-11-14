# WowType：fcitx5 插件 + 设置界面 + 自检工具 + 词库。
# 用法见 flake.nix 和 docs/INSTALL.md 的「NixOS / Nix」一节。
{
  lib,
  stdenv,
  fetchurl,
  rustPlatform,
  cargo,
  rustc,
  cmake,
  kdePackages,
  pkg-config,
  gobject-introspection,
  wrapGAppsHook4,
  fcitx5,
  alsa-lib,
  gtk4,
  libadwaita,
  python3,
}:

let
  # 和 core/Cargo.toml 保持一致
  version = (lib.importTOML ../core/Cargo.toml).package.version;

  # 词库不在 git 里：用发布页上的词库压缩包（scripts/package-deb.sh data 打的），按哈希固定。
  # 换了词库的版本发版后，发布流程会自动开 PR 改这三行（.github/scripts/nix-data-pr.sh）；
  # 手动改的话 hash 在发布页 SHA256SUMS 里，nix hash convert --hash-algo sha256 <十六进制> 转成 SRI 格式。
  dataVersion = "2026.11.11.3";
  data = fetchurl {
    url = "https://github.com/Gloridust/WowType/releases/download/v0.3.12/wowtype-data-rime-ice-${dataVersion}.tar.gz";
    hash = "sha256-6gfD6M9my/fQ68I6uVzJY4Tm84CP0M3uH4eQUyLlHXw=";
  };

  pythonEnv = python3.withPackages (ps: [ ps.pygobject3 ]);
in
stdenv.mkDerivation {
  pname = "wowtype";
  inherit version;

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Cargo.toml
      ../Cargo.lock
      ../core
      ../voice
      ../voice-daemon
      ../fcitx5-addon
      ../icons
      ../themes
      ../settings
      ../README.md
    ];
  };

  cargoDeps = rustPlatform.importCargoLock { lockFile = ../Cargo.lock; };

  nativeBuildInputs = [
    rustPlatform.cargoSetupHook
    cargo
    rustc
    cmake
    kdePackages.extra-cmake-modules
    pkg-config
    gobject-introspection
    wrapGAppsHook4
  ];

  buildInputs = [
    fcitx5
    alsa-lib
    gtk4
    libadwaita
    pythonEnv
  ];

  # 自检工具默认去 /usr/share/wowtype 找词库，改成本包的目录
  postPatch = ''
    substituteInPlace core/src/bin/check.rs \
      --replace-fail /usr/share/wowtype "$out/share/wowtype"
  '';

  # 插件静态链接 Rust 核心：CMake 配置时 target/release/libwowtype_core.a 必须已经在
  preConfigure = ''
    cargo build --release --frozen --offline -p wowtype-core
  '';

  cmakeDir = "../fcitx5-addon";
  cmakeFlags = [
    (lib.cmakeFeature "WOWTYPE_VERSION" version)
    # fcitx5 的 CMake 配置里这个目录指向 fcitx5 自己的 store 路径，要装进本包
    (lib.cmakeFeature "FCITX_INSTALL_PKGDATADIR" "${placeholder "out"}/share/fcitx5")
  ];

  postInstall = ''
    rm -rf "$out/include"
    for bin in wowtype-check wowtype-show; do
      install -Dm755 "../target/release/$bin" "$out/bin/$bin"
    done

    mkdir -p data
    tar -xzf ${data} -C data
    install -Dm644 -t "$out/share/wowtype" data/lexicon.tsv data/english.txt data/words.lm
    install -Dm644 ../README.md "$out/share/doc/wowtype/README.md"
    install -Dm644 data/SOURCE.txt "$out/share/doc/wowtype/DATA-SOURCE.txt"
    echo ${dataVersion} > "$out/share/doc/wowtype/DATA-VERSION"
    install -Dm644 data/LICENSE "$out/share/licenses/wowtype/LICENSE.rime-ice"
    # 五笔码表（rime-wubi，LGPL-3.0）：make-data.sh 的 REV=5 起，词库包里才有它。上面钉的还是旧包时没有它，
    # 设置里五笔灰掉；发版后 nix-data-pr.sh 换成新包，这个判断就总是成立
    if [ -f data/wubi86.tsv ]; then
      install -Dm644 -t "$out/share/wowtype" data/wubi86.tsv
      install -Dm644 -t "$out/share/doc/wowtype" data/WUBI-SOURCE.txt data/WUBI-AUTHORS
      install -Dm644 data/WUBI-LICENSE "$out/share/licenses/wowtype/LICENSE.rime-wubi"
    fi

    # 设置界面：用带 PyGObject 的 Python，词库路径指到本包
    substituteInPlace "$out/bin/wowtype-config" \
      --replace-fail '#!/usr/bin/python3' '#!${pythonEnv.interpreter}' \
      --replace-fail /usr/share/wowtype "$out/share/wowtype" \
      --replace-fail /usr/share/doc/wowtype "$out/share/doc/wowtype"
  '';

  # 只给设置界面套 GTK 环境（GI_TYPELIB_PATH 等），别的 ELF 不用
  dontWrapGApps = true;
  postFixup = ''
    wrapGApp "$out/bin/wowtype-config"
  '';

  passthru = {
    inherit data dataVersion;
  };

  meta = {
    description = "WeChat-style pinyin input method for fcitx5, with bundled dictionaries and language model";
    homepage = "https://github.com/Gloridust/WowType";
    license = with lib.licenses; [
      mit
      asl20
      unicode-30
      gpl3Only # 词库（rime-ice）
      cc-by-sa-40 # 词级语言模型 words.lm
      lgpl3Only # 五笔码表 wubi86.tsv（rime-wubi）
    ];
    platforms = lib.platforms.linux;
    mainProgram = "wowtype-config";
  };
}
