import AppKit
import LaunchpadCore

/// 把面板上的鼠标、滚动、键盘事件翻译成模型调用。
/// 用本地事件监听而不是 SwiftUI 手势:拖拽要跨越文件夹面板的出现与消失,手势挂在被移除的视图上会中断。
@MainActor
final class OverlayEventRouter: NSObject {
    private let model: OverlayModel
    private var monitor: Any?
    private weak var window: NSWindow?
    weak var contextMenuHost: NSView?

    init(model: OverlayModel) {
        self.model = model
    }

    func attach(to window: NSWindow) {
        self.window = window
        guard monitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .scrollWheel, .keyDown]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let input = RoutedEvent(event)
            let consumed = MainActor.assumeIsolated { self?.handle(input) ?? false }
            return consumed ? nil : event
        }
    }

    func detach() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// 从 NSEvent 里抽出需要的字段(NSEvent 本身不能跨隔离域)
    struct RoutedEvent: Sendable {
        let type: NSEvent.EventType
        let windowNumber: Int
        let location: CGPoint
        let time: TimeInterval
        let clickCount: Int
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags
        let scroll: OverlayModel.ScrollInput?

        init(_ event: NSEvent) {
            type = event.type
            windowNumber = event.windowNumber
            location = event.locationInWindow
            time = event.timestamp
            clickCount = [.leftMouseDown, .leftMouseUp].contains(event.type) ? event.clickCount : 0
            keyCode = event.type == .keyDown ? event.keyCode : 0
            modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            scroll = event.type == .scrollWheel ? OverlayModel.ScrollInput(
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY,
                isPrecise: event.hasPreciseScrollingDeltas,
                phase: Self.phase(of: event),
                isMomentum: !event.momentumPhase.isEmpty,
                time: event.timestamp
            ) : nil
        }

        private static func phase(of event: NSEvent) -> OverlayModel.ScrollInput.Phase {
            if event.phase.contains(.began) || event.phase.contains(.mayBegin) { return .began }
            if event.phase.contains(.changed) { return .changed }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) { return .ended }
            return .none
        }
    }

    private func handle(_ event: RoutedEvent) -> Bool {
        guard let window, window.isVisible, event.windowNumber == window.windowNumber else { return false }
        let point = CGPoint(x: event.location.x, y: window.frame.height - event.location.y)
        switch event.type {
        case .leftMouseDown:
            return model.mouseDown(at: point, clickCount: event.clickCount)
        case .leftMouseDragged:
            guard model.press != nil else { return false }
            model.mouseDragged(to: point, time: event.time)
            return true
        case .leftMouseUp:
            guard model.press != nil else { return false }
            model.mouseUp(at: point, time: event.time)
            return true
        case .rightMouseDown:
            showContextMenu(at: point, windowLocation: event.location)
            return true
        case .scrollWheel:
            event.scroll.map(model.scroll)
            return true
        case .keyDown:
            let hasMarkedText = (window.firstResponder as? NSTextView)?.hasMarkedText() ?? false
            return model.keyDown(.init(keyCode: event.keyCode, modifiers: event.modifiers, hasMarkedText: hasMarkedText))
        default:
            return false
        }
    }

    // MARK: 右键菜单

    private var menuApp: AppEntry?
    private var menuFolderID: String?

    /// 右键 App 图标弹菜单;其他位置不响应
    private func showContextMenu(at point: CGPoint, windowLocation: CGPoint) {
        let appID: String
        switch model.hitTest(point) {
        case .item(.grid(_, .app(let id))):
            appID = id
            menuFolderID = nil
        case .item(.folder(_, let id, let folderID)):
            appID = id
            menuFolderID = folderID
        default:
            return
        }
        guard let app = model.app(appID), let host = contextMenuHost else { return }
        menuApp = app
        let menu = NSMenu()
        menu.addItem(withTitle: "打开", action: #selector(openApp), keyEquivalent: "").target = self
        menu.addItem(withTitle: "在访达中显示", action: #selector(revealApp), keyEquivalent: "").target = self
        if menuFolderID != nil {
            menu.addItem(.separator())
            menu.addItem(withTitle: "移出文件夹", action: #selector(moveOut), keyEquivalent: "").target = self
        }
        menu.popUp(positioning: nil, at: host.convert(windowLocation, from: nil), in: host)
    }

    @objc private func openApp() {
        menuApp.map { model.launch($0.id) }
    }

    @objc private func revealApp() {
        menuApp.map { model.revealInFinder($0.id) }
    }

    @objc private func moveOut() {
        guard let app = menuApp, let folderID = menuFolderID else { return }
        model.moveOutOfFolder(app.id, folderID: folderID)
    }
}
