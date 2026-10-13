import AppKit
import LaunchpadCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private let icons = IconProvider()
    private let hotCorners = HotCornerMonitor()
    private let hotKey = GlobalHotKey()
    private let statusItem = StatusItemController()
    private let hotKeyRecorder = HotKeyRecorderModel()
    private let pinch = PinchGestureMonitor()
    private var iconRefresh: Task<Void, Never>?
    private var pendingReflow: Task<Void, Never>?
    private var appliedCapacity = 0
    /// 锁屏期间不响应触控板手势(否则解锁后会发现启动台开着)
    private var isScreenLocked = false

    private lazy var catalog = AppCatalog(
        store: LayoutStore(fileURL: LayoutStore.defaultFileURL),
        scanner: AppScanner(excludedBundleIDs: [Bundle.main.bundleIdentifier ?? "com.zhangxing.Launchpad"]),
        capacity: { [settings] in settings.capacity }
    )
    private lazy var model = OverlayModel(catalog: catalog, settings: settings, icons: icons)
    private lazy var overlay = OverlayController(model: model)
    private lazy var settingsWindow = SettingsWindowController { [unowned self] in
        SettingsView(settings: settings, catalog: catalog, hotKeyRecorder: hotKeyRecorder, isPinchAvailable: pinch.isAvailable)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 登录项拉起、或带 --background 启动(脚本重装时)不弹出启动台
        let launchedAtLogin = Self.isLoginLaunch() || CommandLine.arguments.contains("--background")
        catalog.loadSaved()
        appliedCapacity = settings.capacity
        wireUp()
        [.hotCorners, .hotKey, .showMenuBarIcon, .pinchGesture].forEach(apply)

        Task {
            await catalog.refresh(force: true)
            guard let screen = OverlayController.screenUnderMouse() else { return }
            // 首次弹出前先把图标栅格化好、壁纸模糊好,免得主线程现取 100 多个图标卡一下
            async let backgrounds: Void = overlay.prewarmBackgrounds()
            await prepareIcons(for: screen.frame.size)?.value
            await backgrounds
            // 准备期间用户可能已经自己开过(热角、快捷键),那就不再自动弹出
            guard !launchedAtLogin, !overlay.hasBeenShown, let target = OverlayController.screenUnderMouse() else { return }
            overlay.show(on: target)
        }
    }

    /// 已在运行时再次打开(点程序坞图标、访达里双击、聚焦搜索)= 切换启动台
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        overlay.toggle()
        return false
    }

    private func wireUp() {
        model.actions = OverlayActions(
            dismiss: { [unowned self] in overlay.dismiss() },
            launch: { [unowned self] app in
                overlay.dismiss(restoringFocus: false)
                AppLauncher.open(app)
            },
            reveal: { [unowned self] app in
                overlay.dismiss(restoringFocus: false)
                AppLauncher.revealInFinder(app)
            },
            openSettings: { [unowned self] in
                overlay.dismiss(restoringFocus: false)
                settingsWindow.show()
            }
        )
        overlay.onShow = { [unowned self] in
            prepareIcons()
            rescan()
        }
        hotCorners.onTrigger = { [unowned self] _, screen in overlay.toggle(on: screen) }
        hotKey.onPress = { [unowned self] in overlay.toggle() }
        // 同旧启动台:合拢打开(已开着就不动),张开收起
        pinch.onGesture = { [unowned self] gesture in
            guard !isScreenLocked else { return }
            switch gesture {
            case .pinchIn where !overlay.isVisible: overlay.toggle()
            case .pinchOut where overlay.isVisible: overlay.dismiss()
            default: break
            }
        }
        hotKeyRecorder.onRecordingChange = { [unowned self] recording in
            if recording { hotKey.unregister() } else { hotKey.register(settings.hotKey) }
        }
        statusItem.onOpen = { [unowned self] in overlay.toggle() }
        statusItem.onSettings = { [unowned self] in settingsWindow.show() }
        settingsWindow.onResignKey = { [unowned self] in hotKeyRecorder.stop() }
        statusItem.onRescan = { [unowned self] in rescan(force: true) }
        settings.onChange = { [unowned self] key in apply(key) }
        observeSystemEvents()
    }

    /// 锁屏、显示器休眠、切换用户、插拔显示器时收起,免得回来时面板挡在那儿或尺寸不对
    private func observeSystemEvents() {
        let dismiss: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.overlay.dismiss() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: dismiss)
        workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main, using: dismiss)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: dismiss)
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.isScreenLocked = true }
            dismiss(note)
        }
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isScreenLocked = false }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.overlay.appDidResignActive() }
        }
    }

    private func apply(_ key: AppSettings.Key) {
        switch key {
        case .hotCorners, .cornerModifier, .cornerDelay:
            hotCorners.configure(corners: settings.hotCorners, modifiers: settings.cornerModifier.flags, delay: settings.cornerDelay)
        case .hotKey:
            hotKey.register(settings.hotKey)
        case .columns, .rows:
            scheduleReflow()
            scheduleIconRefresh()
        case .iconScale:
            scheduleIconRefresh()
        case .showMenuBarIcon:
            statusItem.setVisible(settings.showMenuBarIcon)
        case .pinchGesture:
            pinch.setEnabled(settings.pinchGesture)
        case .backgroundDim:
            break
        }
    }

    /// 重新扫描已安装 App,有新装的就补栅格化图标
    private func rescan(force: Bool = false) {
        Task {
            await catalog.refresh(force: force)
            prepareIcons()
        }
    }

    @discardableResult
    private func prepareIcons(for size: CGSize? = nil) -> Task<Void, Never>? {
        icons.prepare(Array(catalog.apps.values), pixelSize: model.iconPixelSize(for: size ?? model.containerSize))
    }

    /// 行列改小后才需要把放不下的挤到下一页(这一步不可逆);
    /// 停手一秒再做,连点 -1 +1 回到原值就什么都不动
    private func scheduleReflow() {
        pendingReflow?.cancel()
        pendingReflow = delayed(1) { [weak self] in
            guard let self else { return }
            if settings.capacity < appliedCapacity { catalog.reflow() }
            appliedCapacity = settings.capacity
        }
    }

    /// 拖动「图标大小」滑杆时会连续改值,停手后再重做栅格化
    private func scheduleIconRefresh() {
        iconRefresh?.cancel()
        iconRefresh = delayed(0.3) { [weak self] in self?.prepareIcons() }
    }

    /// 作为登录项被拉起时不弹出启动台
    private static func isLoginLaunch() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
