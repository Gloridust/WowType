// swift-tools-version:6.2
// WowType 的 macOS 前端。不在 Cargo workspace 里；Rust 核心由 scripts/build.sh 先编好。
import PackageDescription

// 输入法程序要链接 Rust 核心的静态库，库由 build.sh 编好，按完整路径从 WOWTYPE_CORE_LIB 传进来。
// 没有这个变量时（直接 swift test）不声明输入法程序，只编译、测试不需要链接核心的部分。
let coreLib = Context.environment["WOWTYPE_CORE_LIB"].flatMap { $0.isEmpty ? nil : $0 }

let imeTargets: [Target] = coreLib.map { lib in
    [
        .executableTarget(
            name: "WowTypeIME",
            dependencies: ["WowTypeKit", "WowTypeEngine", "CObjCSafe"],
            path: "Sources/WowTypeIME",
            swiftSettings: [.defaultIsolation(MainActor.self)],
            linkerSettings: [
                .linkedFramework("InputMethodKit"),
                .linkedFramework("Carbon"),
                .unsafeFlags([lib]),
            ]
        ),
    ]
} ?? []

let package = Package(
    name: "WowType",
    platforms: [.macOS(.v13)],
    products: coreLib == nil ? [] : [
        .executable(name: "WowType", targets: ["WowTypeIME"]),
    ],
    targets: imeTargets + [
        // 把 core/include/wowtype_core.h 交给 Swift（只引用，不复制）。
        // 不在这里写 link：静态库按完整路径链接（见上面的 WOWTYPE_CORE_LIB）。
        .systemLibrary(name: "CWowTypeCore", path: "Sources/CWowTypeCore"),
        // 和 InputMethodKit、核心都无关的部分，swift test 直接测。
        .target(name: "WowTypeKit", path: "Sources/WowTypeKit"),
        // 会话和引擎的 Swift 封装；只在主线程上用。
        .target(
            name: "WowTypeEngine",
            dependencies: ["CWowTypeCore", "WowTypeKit"],
            path: "Sources/WowTypeEngine"
        ),
        // 应用里抛出的 NSException 不能让输入法崩掉。
        .target(name: "CObjCSafe", path: "Sources/CObjCSafe"),
        .testTarget(
            name: "WowTypeKitTests",
            dependencies: ["WowTypeKit"],
            path: "Tests/WowTypeKitTests"
        ),
    ]
)
