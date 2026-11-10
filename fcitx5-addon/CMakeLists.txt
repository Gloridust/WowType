cmake_minimum_required(VERSION 3.16)

project(wowtype-fcitx5 VERSION 0.3.8 LANGUAGES CXX)

# fcitx5 5.1 的头文件用到了 std::span、std::source_location
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(GNUInstallDirs)

find_package(Fcitx5Core 5.1 REQUIRED)
find_package(Fcitx5Config 5.1 REQUIRED)
find_package(Fcitx5Utils 5.1 REQUIRED)

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
)
# fcitx5 5.1.11 起才有 showCustomInputMethodInformation（切中英文时的小提示）
if(Fcitx5Core_VERSION VERSION_GREATER_EQUAL 5.1.11)
    target_compile_definitions(wowtype PRIVATE WOWTYPE_HAVE_CUSTOM_IM_INFO=1)
endif()

target_include_directories(wowtype PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/../core/include"
)
# 设置界面装在哪：插件在后台用它打开默认主题、检查更新（wowtype-config --startup）
set(WOWTYPE_VERSION "${PROJECT_VERSION}" CACHE STRING "Version shown in the settings app and the log")
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

configure_file(conf/wowtype.conf.in
    "${CMAKE_CURRENT_BINARY_DIR}/wowtype.conf" @ONLY)
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
    add_executable(wowtype-key-harness test/key_harness.cpp)
    target_link_libraries(wowtype-key-harness PRIVATE Fcitx5::Core Fcitx5::Utils)
endif()
