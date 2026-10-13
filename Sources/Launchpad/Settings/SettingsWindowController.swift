import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let makeView: () -> SettingsView
    /// 设置窗口失去焦点(点了别处、切走、打开了启动台)
    var onResignKey: (() -> Void)?

    init(makeView: @escaping () -> SettingsView) {
        self.makeView = makeView
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: makeView()))
            window.title = "启动台设置"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        onResignKey?()
    }

    func windowWillClose(_ notification: Notification) {
        // 关窗即销毁,下次打开重新读取登录项等系统状态
        window = nil
    }
}
