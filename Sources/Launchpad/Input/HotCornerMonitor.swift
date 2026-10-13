import AppKit
import LaunchpadCore

/// 自己实现的触发角:系统「触发角」只能选内置动作,macOS 26 去掉启动台后也没法指向第三方 App。
/// 监听全局鼠标移动(不需要辅助功能权限),光标卡在屏幕真角上停够时间就触发。
@MainActor
final class HotCornerMonitor {
    var onTrigger: ((ScreenCorner, NSScreen) -> Void)?

    private var corners: Set<ScreenCorner> = []
    private var requiredModifiers: NSEvent.ModifierFlags = []
    private var tracker = HotCornerTracker(delay: 0)
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var recheck: Task<Void, Never>?

    func configure(corners: Set<ScreenCorner>, modifiers: NSEvent.ModifierFlags, delay: TimeInterval) {
        self.corners = corners
        self.requiredModifiers = modifiers
        tracker = HotCornerTracker(delay: delay)
        corners.isEmpty ? stop() : start()
    }

    private func start() {
        guard globalMonitor == nil else { return }
        // 只听移动不听拖拽:拖窗口、选文字经过角落不该触发,也省得全系统的拖拽都唤醒本进程
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        // 启动台自己在前台时全局监听收不到,靠本地监听补上(热角再碰一次即收起)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated { self?.evaluate() }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        recheck?.cancel()
    }

    /// 光标在启用的角上、没按着鼠标键、修饰键满足要求,才算「在热角里」
    private func evaluate() {
        let screens = NSScreen.screens
        let held = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let armed = NSEvent.pressedMouseButtons == 0 && held.isSuperset(of: requiredModifiers)
        let active = armed
            ? HotCornerGeometry.corner(at: NSEvent.mouseLocation, screens: screens.map(\.frame)).flatMap { corners.contains($0.corner) ? $0 : nil }
            : nil
        switch tracker.update(corner: active?.corner, now: ProcessInfo.processInfo.systemUptime) {
        case .none:
            if active == nil { recheck?.cancel() }
        case .recheck(let delay):
            recheck?.cancel()
            recheck = delayed(delay) { [weak self] in self?.evaluate() }
        case .fire(let corner):
            guard let active, let screen = screens[safe: active.screen] else { return }
            onTrigger?(corner, screen)
        }
    }
}
