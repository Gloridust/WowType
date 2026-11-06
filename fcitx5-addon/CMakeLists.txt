cmake_minimum_required(VERSION 3.16)

project(wowtype-fcitx5 VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(GNUInstallDirs)

find_package(Fcitx5Core REQUIRED)
find_package(Fcitx5Config REQUIRED)
find_package(Fcitx5Utils REQUIRED)

# Rust 核心产物。先执行：cd core && cargo build --release
set(WOWTYPE_CORE_LIB
    "${CMAKE_CURRENT_SOURCE_DIR}/../core/target/release/libwowtype_core.so"
    CACHE FILEPATH "Path to libwowtype_core.so")
if(NOT EXISTS "${WOWTYPE_CORE_LIB}")
    message(FATAL_ERROR
        "找不到 ${WOWTYPE_CORE_LIB}。请先在 core/ 下执行 cargo build --release，"
        "或用 -DWOWTYPE_CORE_LIB=/path/to/libwowtype_core.so 指定。")
endif()

if(NOT DEFINED FCITX_INSTALL_PKGDATADIR)
    set(FCITX_INSTALL_PKGDATADIR "${CMAKE_INSTALL_DATADIR}/fcitx5")
endif()

add_library(wowtype MODULE
    src/wowtype_engine.cpp
)

target_include_directories(wowtype PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/../core/include"
)
target_link_libraries(wowtype PRIVATE
    Fcitx5::Core
    Fcitx5::Config
    Fcitx5::Utils
    "${WOWTYPE_CORE_LIB}"
)

set_target_properties(wowtype PROPERTIES
    INSTALL_RPATH "$ORIGIN/.."
    BUILD_RPATH "${CMAKE_CURRENT_SOURCE_DIR}/../core/target/release"
)

install(TARGETS wowtype
    LIBRARY DESTINATION "${CMAKE_INSTALL_LIBDIR}/fcitx5"
)

# Rust cdylib 与头文件
install(FILES "${WOWTYPE_CORE_LIB}"
    DESTINATION "${CMAKE_INSTALL_LIBDIR}"
)
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../core/include/wowtype_core.h"
    DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}/wowtype"
)

# demo 词典（不是真实词库）
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../core/data/demo_lexicon.tsv"
    DESTINATION "${CMAKE_INSTALL_DATADIR}/wowtype"
    RENAME demo_lexicon.tsv
)

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
