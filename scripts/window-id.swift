// 给截图脚本找窗口编号:swift scripts/window-id.swift <pid> <overlay|settings>
// overlay = 该进程层级最高、面积最大的窗口(全屏面板);settings = 普通层级的窗口(设置窗口)
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3, let pid = Int32(arguments[1]) else {
    FileHandle.standardError.write(Data("用法:window-id.swift <pid> <overlay|settings>\n".utf8))
    exit(2)
}
let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
    .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
func area(_ window: [String: Any]) -> Double {
    let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
}
let wantsOverlay = arguments[2] == "overlay"
let candidates = windows.filter { ((($0[kCGWindowLayer as String] as? Int) ?? 0) > 0) == wantsOverlay }
guard let window = candidates.max(by: { area($0) < area($1) }), let id = window[kCGWindowNumber as String] as? Int else {
    FileHandle.standardError.write(Data("没找到窗口\n".utf8))
    exit(1)
}
print(id)
