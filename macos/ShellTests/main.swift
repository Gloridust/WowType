// macOS 外壳测试：把照真键盘造的 NSEvent 喂给真的输入控制器（WowTypeInputController.handle），
// 看假输入框收到的编辑区、光标、上屏，和候选框（CandidatePanel）排出来、画出来的这一页。
//
//   macos/ShellTests/run.sh <数据目录>
//
// 和 macos/Tests（只测 Composer，Linux 上也跑）不同，这里编的是 Sources/App 里除 main.swift 以外的全部代码，
// 只在 macOS 上跑。没有 IMKServer、不登记输入法、不往屏幕上放窗口（候选框 onScreen = false，
// 最后还查一遍这个进程在屏幕上没有窗口）。数据目录必须用 WOWTYPE_DATA_DIR 指到临时目录。
// 假的只有 IMK 跨进程的那一段：应用那边的输入框（client()）。

import AppKit

setUpHarness()
runKeyTests()
let shown = windowsOnScreen()
check(shown.isEmpty, "测试进程没有窗口上屏", "\(shown)")
print(failures == 0 ? "全部通过" : "\(failures) 项失败")
exit(failures == 0 ? 0 : 1)
