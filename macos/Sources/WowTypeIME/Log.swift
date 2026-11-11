// 日志：系统日志（os.Logger），subsystem 是 bundle id。
// 不记录打的字：编辑区、候选、上屏文字都不进日志，只记长度、状态、文件名和错误。
import Foundation
import os

enum Log {
    nonisolated static let subsystem = Bundle.main.bundleIdentifier ?? "WowType"
    nonisolated static let app = Logger(subsystem: subsystem, category: "app")
    nonisolated static let input = Logger(subsystem: subsystem, category: "input")
    nonisolated static let engine = Logger(subsystem: subsystem, category: "engine")
    nonisolated static let install = Logger(subsystem: subsystem, category: "install")
}

/// 在主线程上同步执行。IMK 的回调本来就在主线程上；万一不是，转到主线程并记一条警告。
/// 参考 macSKK 的 mainSync。
nonisolated func mainSync<T>(_ body: @MainActor () -> T) -> T {
    // 返回值（如 NSMenu）不一定是 Sendable；它只在主线程上产生、交给调用方，用盒子带出来。
    let box = UncheckedBox<T>()
    if Thread.isMainThread {
        MainActor.assumeIsolated { box.value = body() }
    } else {
        Log.input.warning("IMK 回调不在主线程上")
        DispatchQueue.main.sync { MainActor.assumeIsolated { box.value = body() } }
    }
    return box.value!
}

nonisolated private final class UncheckedBox<T>: @unchecked Sendable {
    var value: T?
}

/// 把 IMK 回调的参数（Any!、NSEvent）带进 mainSync。它们都在主线程上产生和使用。
nonisolated struct MainThreadValue<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
