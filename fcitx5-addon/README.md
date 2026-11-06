# Wowtype fcitx5 插件骨架

这是把 WeType（微信输入法）拼音排序思路移植到 Linux 的外壳层：

    fcitx5  ->  libwowtype.so (C++ addon)  ->  C ABI  ->  libwowtype_core.so (Rust)

Rust 核心负责音节图、束搜索、词典/LM 打分和排序；C++ 只负责 fcitx5 的
输入上下文、预编辑、候选面板和按键处理。

## 目录

    fcitx5-addon/
      CMakeLists.txt
      conf/wowtype.conf.in          # 输入法注册（fcitx5 里显示的名字）
      conf/wowtype-addon.conf.in    # addon 动态库注册
      src/wowtype_engine.h
      src/wowtype_engine.cpp        # InputMethodEngineV2 实现 + AddonFactory
    core/
      include/wowtype_core.h        # C ABI
      src/ffi.rs                    # C ABI 的 Rust 实现
      data/demo_lexicon.tsv         # 演示词典

## Ubuntu 依赖

以 Ubuntu 22.04/24.04 为例（fcitx5 5.1.x）：

    sudo apt update
    sudo apt install -y \
        build-essential cmake pkg-config \
        libfcitx5core-dev libfcitx5config-dev libfcitx5utils-dev \
        cargo rustc

如果发行版自带的 Rust 太旧，建议用 rustup 安装稳定版：

    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

## 编译

先编译 Rust 核心：

    cd core
    cargo test
    cargo build --release

再编译 C++ addon：

    cd ../fcitx5-addon
    cmake -S . -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr
    cmake --build build -j"$(nproc)"

## 安装

    sudo cmake --install build
    sudo ldconfig

CMake 会安装：

    /usr/lib/<multiarch>/fcitx5/libwowtype.so
    /usr/lib/<multiarch>/libwowtype_core.so
    /usr/share/fcitx5/addon/wowtype.conf
    /usr/share/fcitx5/inputmethod/wowtype.conf
    /usr/share/wowtype/demo_lexicon.tsv

multiarch 通常是 x86_64-linux-gnu。libwowtype.so 的 RPATH 是 $ORIGIN/..，
因此会从上一级目录寻找 libwowtype_core.so。

如果 CMake 没有把文件放到 fcitx5 期望的位置，可以手动安装：

    sudo install -Dm755 core/target/release/libwowtype_core.so \
        /usr/lib/x86_64-linux-gnu/libwowtype_core.so
    sudo install -Dm755 fcitx5-addon/build/libwowtype.so \
        /usr/lib/x86_64-linux-gnu/fcitx5/libwowtype.so
    sudo install -Dm644 fcitx5-addon/build/wowtype.conf \
        /usr/share/fcitx5/inputmethod/wowtype.conf
    sudo install -Dm644 fcitx5-addon/build/wowtype-addon.conf \
        /usr/share/fcitx5/addon/wowtype.conf
    sudo install -Dm644 core/data/demo_lexicon.tsv \
        /usr/share/wowtype/demo_lexicon.tsv
    sudo ldconfig

## 启用

重启 fcitx5：

    fcitx5 -r

然后打开配置工具，添加 Wowtype：

    fcitx5-configtool

或者在“输入法”页把 Wowtype 加到当前分组。切换过去后输入 xian，应能看到
“先 / 西安”等候选；输入 zg 会走简拼并给出“中国”。

## 数据

插件默认读取：

    /usr/share/wowtype/lexicon.tsv

如果不存在，会退回到 /usr/share/wowtype/demo_lexicon.tsv。也可以用环境变量：

    export WOWTYPE_LEXICON=/path/to/lexicon.tsv
    export WOWTYPE_LM=/path/to/bigram.tsv
    fcitx5 -r

词典格式（TSV，UTF-8）：

    拼音<TAB>词<TAB>频次
    xian	先	30000
    xi an	西安	20000
    hua r	花儿	3000

- 多音节拼音用空格或隔音符分隔；不要写成无分隔连写（fangan 有歧义）。
- 儿化用独立的 r 标记。
- 目前 demo 词典只是极小样本，需要换成真实导出的词库或开源词库。

bigram 格式（可选）：

    prev<TAB>cur<TAB>count
    你	好	12345

不传 WOWTYPE_LM 时使用空的 LM，不会影响候选生成。

## 当前边界

- C++ 侧只处理字母、隔音符、空格、数字选词、退格、Esc、回车；翻页、
  标点、符号、云候选、用户词持久化都还没做。
- 排序是骨架版：词典频次 + bigram + 覆盖率 + 线性特征；LTR（LightGBM）、
  NNLM 重排、MixRank 只有 trait/钩子，没有真实模型。
- 真实 WeType 词库是 LOUDS trie + 音节 ID 编码，需要单独写解析器并实现
  Lexicon；MemoryLexicon 的 TSV 加载只用于打通流程。
- 本目录的 C++ 没有在 macOS 开发机上编译（缺少 fcitx5 头文件）。代码按
  fcitx5 5.1.x 的 InputMethodEngineV2 / AddonFactory API 编写；在 Ubuntu
  上如果 fcitx5 版本不同，可能需要按头文件微调。
