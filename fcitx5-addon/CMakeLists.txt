cmake_minimum_required(VERSION 3.16)

project(wowtype-fcitx5 VERSION 0.7.14 LANGUAGES CXX)

# fcitx5 5.1 的头文件用到了 std::span、std::source_location
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(GNUInstallDirs)

# 最低 fcitx5 5.0（Ubuntu 22.04 是 5.0.14）。5.1 以后才有的功能下面按版本 / 头文件判断
find_package(Fcitx5Core 5.0 REQUIRED)
find_package(Fcitx5Config 5.0 REQUIRED)
find_package(Fcitx5Utils 5.0 REQUIRED)

# Rust 核心产物。先执行：cargo build --release -p wowtype-core（产物在 workspace 根 target/）
#
# 默认静态链接 libwowtype_core.a：插件自成一体，不用再装 libwowtype_core.so，
# 也不会因为 .so 没有 SONAME 而把构建目录的绝对路径写进插件。
option(WOWTYPE_CORE_STATIC "Link the Rust core statically" ON)
if(WOWTYPE_CORE_STATIC)
    set(_wowtype_core_default "${CMAKE_CURRENT_SOURCE_DIR}/../target/release/libwowtype_core.a")
else()
    set(_wowtype_core_default "${CMAKE_CURRENT_SOURCE_DIR}/../target/release/libwowtype_core.so")
endif()
set(WOWTYPE_CORE_LIB "${_wowtype_core_default}"
    CACHE FILEPATH "Path to libwowtype_core.a (or .so with -DWOWTYPE_CORE_STATIC=OFF)")
if(NOT EXISTS "${WOWTYPE_CORE_LIB}")
    message(FATAL_ERROR
        "找不到 ${WOWTYPE_CORE_LIB}。请先在仓库根目录执行 cargo build --release -p wowtype-core，"
        "或用 -DWOWTYPE_CORE_LIB=/path/to/libwowtype_core.a 指定。")
endif()

if(NOT DEFINED FCITX_INSTALL_PKGDATADIR)
    set(FCITX_INSTALL_PKGDATADIR "${CMAKE_INSTALL_DATADIR}/fcitx5")
endif()

add_library(wowtype MODULE
    src/wowtype_engine.cpp
    src/clipboard_copy.cpp
)
# fcitx5 5.1.11 起才有 showCustomInputMethodInformation（切中英文时的小提示）
if(Fcitx5Core_VERSION VERSION_GREATER_EQUAL 5.1.11)
    target_compile_definitions(wowtype PRIVATE WOWTYPE_HAVE_CUSTOM_IM_INFO=1)
endif()
# fcitx5 5.1.10 起才有 ActionableCandidateList（候选上点右键的菜单：「忘掉这个词」，#229）；
# Ubuntu 22.04 的 5.0 上没有右键菜单，Ctrl+Delete 照样能忘
set(WOWTYPE_HAVE_CANDIDATE_ACTIONS OFF)
if(Fcitx5Core_VERSION VERSION_GREATER_EQUAL 5.1.10)
    set(WOWTYPE_HAVE_CANDIDATE_ACTIONS ON)
    target_compile_definitions(wowtype PRIVATE WOWTYPE_HAVE_CANDIDATE_ACTIONS=1)
endif()

target_include_directories(wowtype PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/../core/include"
)
# 设置界面装在哪：插件在后台用它打开默认主题、检查更新（wowtype-config --startup）
# 版本号：打包脚本用 -DWOWTYPE_VERSION 指定（带 ~git 之类的后缀）；没指定时跟着 project() 走。
# 缓存变量第一次配置以后就不变，源码升级后不删 build/ 会一直是旧版本号（#249）：
# 缓存里的还是上次 project() 给的默认值（或者更早的 build/ 里没记、但比现在旧）时，跟上新版本。
if(NOT DEFINED WOWTYPE_VERSION
   OR (DEFINED _WOWTYPE_VERSION_DEFAULT AND WOWTYPE_VERSION STREQUAL _WOWTYPE_VERSION_DEFAULT)
   OR (NOT DEFINED _WOWTYPE_VERSION_DEFAULT AND WOWTYPE_VERSION VERSION_LESS PROJECT_VERSION))
    set(WOWTYPE_VERSION "${PROJECT_VERSION}" CACHE STRING "Version shown in the settings app and the log" FORCE)
endif()
set(_WOWTYPE_VERSION_DEFAULT "${PROJECT_VERSION}" CACHE INTERNAL "WOWTYPE_VERSION 跟着 project() 时的值")
# 系统词库目录（lexicon.tsv、words.lm、demo_lexicon.tsv 等装在这里），跟着安装前缀走
set(WOWTYPE_SYSTEM_DATA_DIR "${CMAKE_INSTALL_FULL_DATADIR}/wowtype"
    CACHE PATH "Directory the addon reads the system lexicon and language model from")
target_compile_definitions(wowtype PRIVATE
    WOWTYPE_CONFIG_TOOL="${CMAKE_INSTALL_FULL_BINDIR}/wowtype-config"
    WOWTYPE_SYSTEM_DATA_DIR="${WOWTYPE_SYSTEM_DATA_DIR}"
    WOWTYPE_ADDON_VERSION="${WOWTYPE_VERSION}")
target_link_libraries(wowtype PRIVATE
    Fcitx5::Core
    Fcitx5::Config
    Fcitx5::Utils
    "${WOWTYPE_CORE_LIB}"
)

if(WOWTYPE_CORE_STATIC)
    # Rust 标准库要的系统库（cargo rustc -- --print native-static-libs）；
    # 静态库里的符号不导出，免得和别的插件冲突
    find_package(Threads REQUIRED)
    target_link_libraries(wowtype PRIVATE Threads::Threads ${CMAKE_DL_LIBS} m)
    # 核心默认带语音输入（cargo 特性 voice），麦克风走 ALSA。
    # 核心用 --no-default-features 编译时可以 -DWOWTYPE_VOICE=OFF 去掉这个依赖
    option(WOWTYPE_VOICE "Rust core was built with the voice feature" ON)
    if(WOWTYPE_VOICE)
        find_package(ALSA REQUIRED)
        target_link_libraries(wowtype PRIVATE ALSA::ALSA)
    endif()
    target_link_options(wowtype PRIVATE "LINKER:--exclude-libs,ALL")
else()
    set_target_properties(wowtype PROPERTIES
        INSTALL_RPATH "$ORIGIN/.."
        BUILD_RPATH "${CMAKE_CURRENT_SOURCE_DIR}/../target/release"
    )
endif()

install(TARGETS wowtype
    # Fcitx5Utils 同前缀时复用宿主的 lib/lib64/multiarch 路径；
    # 不同前缀（包括 Nix store）时按本包的 GNUInstallDirs 计算。
    LIBRARY DESTINATION "${FCITX_INSTALL_ADDONDIR}"
)

# 动态链接时才需要把 Rust cdylib 一起装上
if(NOT WOWTYPE_CORE_STATIC)
    install(FILES "${WOWTYPE_CORE_LIB}"
        DESTINATION "${FCITX_INSTALL_LIBDIR}"
    )
endif()
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../core/include/wowtype_core.h"
    DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}/wowtype"
)

# demo 词典（不是真实词库）与简繁映射表
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../core/data/demo_lexicon.tsv"
    DESTINATION "${CMAKE_INSTALL_DATADIR}/wowtype"
    RENAME demo_lexicon.tsv
)
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../core/data/s2t.tsv")
    install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../core/data/s2t.tsv"
        DESTINATION "${CMAKE_INSTALL_DATADIR}/wowtype"
    )
endif()

# 真实词库、英文词表、词级语言模型、整句增强模型、五笔码表：scripts/make-data.sh、make-wubi.sh 生成在 dist/data，
# 有就一起装进系统数据目录（OPTIONAL：安装时没有就跳过，插件退到 demo 词典）。
# 以前源码安装要自己把它们拷进 ~/.local/share/wowtype/，那份拷贝以后会一直挡在新版数据前面。
# 各发行版的打包脚本自己放这几个文件（同样的位置），这里多装一遍不碍事；不想要就 -DWOWTYPE_DATA_DIR=
set(WOWTYPE_DATA_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../dist/data" CACHE PATH
    "Directory with lexicon.tsv, english.txt, words.lm, nnlm.bin, wubi86.tsv and DATA-MANIFEST (scripts/make-data.sh output); empty to skip")
if(WOWTYPE_DATA_DIR)
    # DATA-MANIFEST：各数据文件的名字、版本、来源（docs/DATA.md「数据版本标记」）
    # nnlm.bin：WowType 自己训的整句增强模型（make-data.sh 下载到了才有）
    foreach(_wowtype_data lexicon.tsv english.txt words.lm nnlm.bin wubi86.tsv DATA-MANIFEST)
        install(FILES "${WOWTYPE_DATA_DIR}/${_wowtype_data}"
            DESTINATION "${CMAKE_INSTALL_DATADIR}/wowtype" OPTIONAL)
    endforeach()
endif()
# 自检工具 wowtype-check、wowtype-show 和跨设备复制粘贴的配对工具 wowtype-sync：
# 和核心库一起由 cargo 编在同一个目录
get_filename_component(_wowtype_cargo_dir "${WOWTYPE_CORE_LIB}" DIRECTORY)
foreach(_wowtype_tool wowtype-check wowtype-show wowtype-sync)
    install(PROGRAMS "${_wowtype_cargo_dir}/${_wowtype_tool}"
        DESTINATION "${CMAKE_INSTALL_BINDIR}" OPTIONAL)
endforeach()

configure_file(conf/wowtype.conf.in
    "${CMAKE_CURRENT_BINARY_DIR}/wowtype.conf" @ONLY)
# 插件清单里要求的 fcitx5 版本：编译时版本的「主.次.0」（5.1.x 上编的写 5.1.0，22.04 的 5.0.14 上编的写 5.0.0）。
# 不写编译时的完整版本：Arch、Fedora 的包对 fcitx5 不写版本，CI 用最新的 fcitx5 编，用户的 fcitx5 只要
# 晚一个小版本没升级，fcitx5 就不加载插件、也不报错。同一个次版本里缺符号（5.1.11 的自定义提示）的风险
# 和以前写死 5.1.0 时一样。
string(REGEX MATCH "^[0-9]+\\.[0-9]+" _wowtype_fcitx_minor "${Fcitx5Core_VERSION}")
set(WOWTYPE_FCITX_CORE_DEP "${_wowtype_fcitx_minor}.0")
configure_file(conf/wowtype-addon.conf.in
    "${CMAKE_CURRENT_BINARY_DIR}/wowtype-addon.conf" @ONLY)

install(FILES "${CMAKE_CURRENT_BINARY_DIR}/wowtype.conf"
    DESTINATION "${CMAKE_INSTALL_DATADIR}/fcitx5/inputmethod"
)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/wowtype-addon.conf"
    DESTINATION "${FCITX_INSTALL_PKGDATADIR}/addon"
    RENAME wowtype.conf
)

# 图标：输入法列表、托盘和设置界面都用 wowtype
install(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../icons/hicolor"
    DESTINATION "${CMAKE_INSTALL_DATADIR}/icons"
    FILES_MATCHING PATTERN "*.png" PATTERN "*.svg"
)

# 绿色主题：fcitx5 经典界面主题（KDE、X11 等用它画候选框）和 GNOME 的 kimpanel 配色扩展
option(WOWTYPE_INSTALL_THEMES "Install the WowType fcitx5 themes and GNOME Shell extension" ON)
if(WOWTYPE_INSTALL_THEMES)
    install(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../themes/fcitx5/"
        DESTINATION "${CMAKE_INSTALL_DATADIR}/fcitx5/themes")
    install(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../themes/gnome-shell/"
        DESTINATION "${CMAKE_INSTALL_DATADIR}/gnome-shell/extensions")
endif()

# 设置界面（GTK 4 + libadwaita，Python）：fcitx5 配置工具里的「自定义词和更多设置」也打开它
option(WOWTYPE_INSTALL_SETTINGS "Install the wowtype-config settings app" ON)
if(WOWTYPE_INSTALL_SETTINGS)
    set(VERSION "${WOWTYPE_VERSION}")
    configure_file("${CMAKE_CURRENT_SOURCE_DIR}/../settings/wowtype-config"
        "${CMAKE_CURRENT_BINARY_DIR}/wowtype-config" @ONLY)
    install(PROGRAMS "${CMAKE_CURRENT_BINARY_DIR}/wowtype-config"
        DESTINATION "${CMAKE_INSTALL_BINDIR}")
    install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../settings/io.github.Gloridust.WowType.Config.desktop"
        DESTINATION "${CMAKE_INSTALL_DATADIR}/applications")
endif()

# 按键行为测试（scripts/addon-test.sh 会打开它）：私有、无界面的 fcitx5 实例里加载插件按键
option(WOWTYPE_BUILD_TESTS "Build the key-handling harness" OFF)
if(WOWTYPE_BUILD_TESTS)
    add_executable(wowtype-key-harness test/key_harness.cpp src/clipboard_copy.cpp)
    target_include_directories(wowtype-key-harness PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
    target_link_libraries(wowtype-key-harness PRIVATE Fcitx5::Core Fcitx5::Utils)
    # 经 D-Bus 问插件版本（Version）的用例拿它对照
    target_compile_definitions(wowtype-key-harness PRIVATE WOWTYPE_ADDON_VERSION="${WOWTYPE_VERSION}")
    # 「密码框也用输入法」（Behavior/AllowInputMethodForPassword）5.0 没有：看头文件里有没有它的读取函数，
    # 有就测「打开以后密码框里照常打中文」，没有就测「密码框里不用输入法、按键原样交给应用」
    get_target_property(_wowtype_fcitx_inc Fcitx5::Core INTERFACE_INCLUDE_DIRECTORIES)
    unset(WOWTYPE_FCITX_GLOBALCONFIG_H CACHE)  # 换了 fcitx5 重新配置时重新找（NO_CACHE 要 CMake 3.21）
    find_file(WOWTYPE_FCITX_GLOBALCONFIG_H fcitx/globalconfig.h
        PATHS ${_wowtype_fcitx_inc} NO_DEFAULT_PATH)
    if(NOT WOWTYPE_FCITX_GLOBALCONFIG_H)
        # 找不到就当没有这个设置的话，5.1 上会悄悄测弱的那种，所以直接报错
        message(FATAL_ERROR "按键测试：在 ${_wowtype_fcitx_inc} 里找不到 fcitx/globalconfig.h")
    endif()
    set(_wowtype_password_option OFF)
    file(STRINGS "${WOWTYPE_FCITX_GLOBALCONFIG_H}" _wowtype_password_lines
        REGEX "allowInputMethodForPassword")
    if(_wowtype_password_lines)
        set(_wowtype_password_option ON)
    endif()
    message(STATUS "WowType 按键测试：fcitx5 ${Fcitx5Core_VERSION}，「密码框也用输入法」设置 ${_wowtype_password_option}"
        "（globalconfig.h：${WOWTYPE_FCITX_GLOBALCONFIG_H}）")
    if(_wowtype_password_option)
        target_compile_definitions(wowtype-key-harness PRIVATE WOWTYPE_HAVE_PASSWORD_IM_OPTION=1)
    endif()
    # 候选的右键菜单（#229）：插件编进去了才测
    if(WOWTYPE_HAVE_CANDIDATE_ACTIONS)
        target_compile_definitions(wowtype-key-harness PRIVATE WOWTYPE_HAVE_CANDIDATE_ACTIONS=1)
    endif()

    # 设置契约：导出 WowtypeConfig 的键、默认值、范围、可选值，scripts/test-config-contract.py 对照 spec/config.json
    add_executable(wowtype-config-dump test/config_dump.cpp)
    target_include_directories(wowtype-config-dump PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/src"
        "${CMAKE_CURRENT_SOURCE_DIR}/../core/include")
    target_link_libraries(wowtype-config-dump PRIVATE Fcitx5::Core Fcitx5::Config Fcitx5::Utils)
endif()
