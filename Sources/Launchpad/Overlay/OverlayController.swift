import AppKit
import LaunchpadCore
import SwiftUI

/// 盖住整块屏幕(含菜单栏和程序坞)的无边框面板。
/// 打开时激活本 App(同旧启动台),别的 App 就抢不走键盘焦点;收起时把前台还给原来的 App。
final class OverlayPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class OverlayController: NSObject, NSWindowDelegate {
    let model: OverlayModel
    let wallpapers = WallpaperProvider()
    /// 面板尺寸确定之后回调(此时可按真实尺寸准备图标、重新扫描)
    var onShow: (() -> Void)?

    private(set) var isVisible = false
    private(set) var hasBeenShown = false
    private var isDismissing = false
    /// 打开前的前台 App,收起时把前台还给它
    private var previousApp: NSRunningApplication?
    private lazy var panel = makePanel()
    private lazy var router = OverlayEventRouter(model: model)
    /// 三层背景:毛玻璃(兜底)→ 模糊壁纸 → SwiftUI 内容
    private let blurView = NSVisualEffectView()
    private let wallpaperView = NSView()
    /// 只让最近一次打开的背景渲染结果生效,迟到的旧结果丢弃
    private var backgroundTask: Task<Void, Never>?
    /// 演示模式用固定的背景图代替桌面壁纸
    var backgroundOverride: ((CGSize) -> CGImage?)?

    static let reducedTransparencyFill = NSColor(white: 0.12, alpha: 1)

    static let fadeIn = 0.2
    static let fadeOut = 0.16
    static let backgroundFade = 0.25

    init(model: OverlayModel) {
        self.model = model
        super.init()
    }

    func toggle(on screen: NSScreen? = nil) {
        if isVisible {
            dismiss()
        } else if let screen = screen ?? Self.screenUnderMouse() {
            show(on: screen)
        }
    }

    func show(on screen: NSScreen) {
        guard !isVisible else { return }
        isVisible = true
        hasBeenShown = true
        model.prepareForPresentation(size: screen.frame.size)
        onShow?()
        panel.setFrame(screen.frame, display: true)
        applyBackground(for: screen)
        panel.alphaValue = 0
        previousApp = NSWorkspace.shared.frontmostApplication.flatMap { $0 == NSRunningApplication.current ? nil : $0 }
        panel.makeKeyAndOrderFront(nil)
        NSApp.forceActivate()
        router.attach(to: panel)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeIn
            panel.animator().alphaValue = 1
        }
        withAnimation(Motion.present) { model.isShown = true }
    }

    /// - Parameter restoringFocus: 打开 App、去访达、开设置时为 false(由它们接管前台),其余情况把前台还给原 App
    func dismiss(restoringFocus: Bool = true) {
        guard isVisible, !isDismissing else { return }
        isDismissing = true
        if restoringFocus, NSApp.isActive, let previousApp, !previousApp.isTerminated {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate(from: .current, options: [])
        }
        previousApp = nil
        model.commitFolderName()
        withAnimation(.easeIn(duration: Self.fadeOut)) { model.isShown = false }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeOut
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.finishDismiss() }
        })
    }

    private func finishDismiss() {
        backgroundTask?.cancel()
        panel.orderOut(nil)
        router.detach()
        model.didDismiss()
        isVisible = false
        isDismissing = false
    }

    /// 切到别的 App(⌘Tab、点了另一块屏上的窗口)就收起。前台已经换了,不必再还。
    func appDidResignActive() {
        dismiss(restoringFocus: false)
    }

    /// 系统没让本 App 激活时(面板只是 key window),失去键盘焦点同样收起
    func windowDidResignKey(_ notification: Notification) {
        guard !NSApp.isActive else { return }
        dismiss(restoringFocus: false)
    }

    /// 光标所在的屏幕;没接显示器(无头 Mac、拔显示器的瞬间)时为 nil
    static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// 背景:「降低透明度」时纯深色;否则模糊壁纸(首次渲染完成前先用毛玻璃顶着)
    private func applyBackground(for screen: NSScreen) {
        backgroundTask?.cancel()
        guard let layer = wallpaperView.layer else { return }
        if let image = backgroundOverride?(screen.frame.size) {
            layer.backgroundColor = nil
            show(WallpaperProvider.Background(image: SendableImage(image: image), luminance: WallpaperProvider.brightLuminance(of: image)), in: layer, animated: false)
            return
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            layer.contents = nil
            layer.backgroundColor = Self.reducedTransparencyFill.cgColor
            wallpaperView.isHidden = false
            model.wallpaperDim = 0
            return
        }
        layer.backgroundColor = nil
        if let background = wallpapers.cachedBackground(for: screen) {
            show(background, in: layer, animated: false)
            return
        }
        wallpaperView.isHidden = true
        model.wallpaperDim = 0
        backgroundTask = Task { [weak self] in
            guard let background = await self?.wallpapers.background(for: screen),
                  let self, !Task.isCancelled, isVisible else { return }
            show(background, in: layer, animated: true)
        }
    }

    private func show(_ background: WallpaperProvider.Background, in layer: CALayer, animated: Bool) {
        if animated {
            let fade = CATransition()
            fade.duration = Self.backgroundFade
            layer.add(fade, forKey: "contents")
        }
        layer.contents = background.image.image
        wallpaperView.isHidden = false
        // 暗度与壁纸淡入同步变化,不闪
        withAnimation(animated ? .easeOut(duration: Self.backgroundFade) : nil) {
            model.wallpaperDim = WallpaperProvider.minimumDim(forLuminance: background.luminance)
        }
    }

    /// 提前把各屏壁纸模糊好,首次打开不用等
    func prewarmBackgrounds() async {
        guard backgroundOverride == nil else { return }
        for screen in NSScreen.screens { _ = await wallpapers.background(for: screen) }
    }

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel()
        panel.delegate = self
        let root = NSView()
        blurView.material = .fullScreenUI
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.appearance = NSAppearance(named: .darkAqua)
        // 自己托管图层(先给 layer 再开 wantsLayer),AppKit 不会在重绘时覆盖 contents
        let wallpaperLayer = CALayer()
        wallpaperLayer.contentsGravity = .resizeAspectFill
        wallpaperLayer.masksToBounds = true
        wallpaperView.layer = wallpaperLayer
        wallpaperView.wantsLayer = true
        let host = NSHostingView(rootView: LaunchpadView(model: model))
        for view in [blurView, wallpaperView, host] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                view.topAnchor.constraint(equalTo: root.topAnchor),
                view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        panel.contentView = root
        router.contextMenuHost = root
        return panel
    }
}
