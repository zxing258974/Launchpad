import AppKit
import LaunchpadCore
import Observation
import SwiftUI

/// 面板对外的动作(由控制器注入)
struct OverlayActions {
    var dismiss: @MainActor () -> Void = {}
    var launch: @MainActor (AppEntry) -> Void = { _ in }
    var reveal: @MainActor (AppEntry) -> Void = { _ in }
    var openSettings: @MainActor () -> Void = {}
}

/// 统一的动效。「减弱动态效果」打开时一律换成短促的淡入淡出式缓动,不弹不冲。
@MainActor
enum Motion {
    static var page: Animation { choose(.spring(response: 0.38, dampingFraction: 0.9)) }
    static var folder: Animation { choose(.spring(response: 0.3, dampingFraction: 0.88)) }
    static var reorder: Animation { choose(.spring(response: 0.3, dampingFraction: 0.82)) }
    static var mergeHighlight: Animation { choose(.spring(response: 0.25, dampingFraction: 0.7)) }
    static var present: Animation { choose(.spring(response: 0.34, dampingFraction: 0.86)) }
    static let highlightOff = Animation.easeOut(duration: 0.15)

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private static func choose(_ full: Animation) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : full
    }
}

/// 拖拽中的结构状态。光标位置单独放在 `OverlayModel.dragLocation`,
/// 这样每个鼠标事件只让拖拽残影重绘,不必让整个网格重算。
///
/// 网格模式:`base` 是拿掉被拖项、末尾留一页空白的排列,`preview` 始终是「此刻松手会提交」的排列。
/// 文件夹模式:对文件夹内的 App 顺序做同样的事。
struct DragSession: Equatable {
    enum Mode: Equatable {
        case grid
        case folder(String)
    }

    let item: LaunchItem
    let mode: Mode
    let grabOffset: CGSize
    var base = LaunchLayout.empty
    var preview = LaunchLayout.empty
    var target: ItemLocation?
    var mergeTargetID: String?
    var folderBase: [String] = []
    var folderPreview: [String] = []

    static func grid(item: LaunchItem, base: LaunchLayout, target: ItemLocation, capacity: Int, grabOffset: CGSize) -> DragSession {
        var session = DragSession(item: item, mode: .grid, grabOffset: grabOffset, base: base)
        session.place(at: target, capacity: capacity)
        return session
    }

    static func folder(appID: String, in folder: Folder, grabOffset: CGSize) -> DragSession {
        DragSession(
            item: .app(appID), mode: .folder(folder.id), grabOffset: grabOffset,
            folderBase: folder.appIDs.filter { $0 != appID }, folderPreview: folder.appIDs
        )
    }

    mutating func place(at location: ItemLocation, capacity: Int) {
        target = location
        preview = LayoutEngine.inserting(item, at: location, in: base, capacity: capacity)
    }

    /// 末尾补一页空白,拖到最后一页之后可以新开一页;提交时空页会被清掉
    static func withBlankPage(_ layout: LaunchLayout) -> LaunchLayout {
        layout.pages.last?.isEmpty == true ? layout : LaunchLayout(pages: layout.pages + [[]])
    }
}

/// 全屏启动台的全部交互状态。几何由 `GridMetrics` 统一算,渲染与命中判断共用一套坐标(左上原点)。
@MainActor
@Observable
final class OverlayModel {
    @ObservationIgnored let catalog: AppCatalog
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let icons: IconProvider
    @ObservationIgnored var actions = OverlayActions()

    var containerSize = CGSize(width: 1440, height: 900)
    /// 驱动进出场动画
    var isShown = false
    /// 手势翻页时的实时位移
    var pageOffset: CGFloat = 0
    private(set) var query = ""
    private(set) var searchResultIDs: [String] = []
    var selection: ItemLocation?
    /// 文件夹打开时方向键选中的 App(文件夹内的整体下标)
    var folderSelection: Int?
    var pressedItemID: String?
    var openFolderID: String?
    var folderNameDraft = ""
    var isEditingFolderName = false
    /// 自增即请求把焦点还给搜索框
    var searchFocusRequest = 0
    /// 自增即请求把焦点放到文件夹名(键盘改名)
    var folderNameFocusRequest = 0
    var drag: DragSession?
    var dragLocation: CGPoint = .zero
    /// 文件夹内触控板翻页的实时位移
    var folderPageOffset: CGFloat = 0
    /// 壁纸很亮时自动加深的最低暗度
    var wallpaperDim: Double = 0

    /// 实际背景暗度:用户设置与壁纸亮度要求取大者
    var effectiveDim: Double { max(settings.backgroundDim, wallpaperDim) }

    private var storedPage = 0
    private var storedFolderPage = 0

    // 指针与计时器状态(不参与渲染)
    @ObservationIgnored var press: Press?
    @ObservationIgnored var pendingReorder: Task<Void, Never>?
    @ObservationIgnored var pendingReorderTarget: ItemLocation?
    @ObservationIgnored var pendingFolderReorderIndex: Int?
    @ObservationIgnored var pendingMerge: Task<Void, Never>?
    @ObservationIgnored var pendingMergeID: String?
    @ObservationIgnored var edgeFlip: Task<Void, Never>?
    @ObservationIgnored var edgeFlipDirection = 0
    @ObservationIgnored var scrollState = ScrollState()
    @ObservationIgnored private var lastAnnouncedResultCount: Int?

    init(catalog: AppCatalog, settings: AppSettings, icons: IconProvider) {
        self.catalog = catalog
        self.settings = settings
        self.icons = icons
    }

    // MARK: 派生数据

    var metrics: GridMetrics { metrics(for: containerSize) }

    func metrics(for size: CGSize) -> GridMetrics {
        GridMetrics(containerSize: size, columns: settings.columns, rows: settings.rows, iconScale: settings.iconScale)
    }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// 当前要画的各页:搜索结果 / 拖拽预览 / 正常排列
    var displayedPages: [[LaunchItem]] {
        if isSearching {
            return LayoutEngine.paginate(searchResultIDs.map(LaunchItem.app), capacity: metrics.capacity)
        }
        if let drag, drag.mode == .grid { return drag.preview.pages }
        return catalog.layout.pages
    }

    var pageCount: Int { max(displayedPages.count, 1) }

    /// 当前页;页数变化(拖拽结束清掉空页、卸载 App)时自动夹回有效范围
    var currentPage: Int {
        get { Paging.clamp(storedPage, pageCount) }
        set { storedPage = Paging.clamp(newValue, pageCount) }
    }

    var displayedFolder: Folder? {
        if let drag, case .folder(let folderID) = drag.mode {
            return catalog.layout.folder(withID: folderID)?.with(appIDs: drag.folderPreview)
        }
        return openFolderID.flatMap(catalog.layout.folder(withID:))
    }

    var folderPage: Int {
        get { Paging.clamp(storedFolderPage, folderPageCount) }
        set { storedFolderPage = Paging.clamp(newValue, folderPageCount) }
    }

    private var folderPageCount: Int {
        displayedFolder.map { folderMetrics(for: $0).pageCount } ?? 1
    }

    /// 文件夹图标在屏幕上的位置(单位坐标),文件夹从这里展开;不在当前页就从中间展开
    func folderOrigin(of folderID: String) -> UnitPoint {
        guard let location = catalog.layout.location(ofItem: LaunchItem.folder(Folder(id: folderID, name: "", appIDs: [])).id),
              location.page == currentPage, containerSize.width > 0, containerSize.height > 0 else { return .center }
        let center = metrics.iconCenter(at: location.index)
        return UnitPoint(x: center.x / containerSize.width, y: center.y / containerSize.height)
    }

    func folderMetrics(for folder: Folder) -> FolderMetrics {
        FolderMetrics(grid: metrics, appCount: folder.appIDs.count)
    }

    func app(_ appID: String) -> AppEntry? { catalog.apps[appID] }

    /// 按各屏幕里最高的缩放比栅格化,图标在哪块屏上都清楚
    func iconPixelSize(for size: CGSize) -> Int {
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        return Int((metrics(for: size).iconSize * scale).rounded(.up))
    }

    // MARK: 呈现

    func prepareForPresentation(size: CGSize) {
        resetTransientState()
        containerSize = size
        isShown = false
        searchFocusRequest += 1
    }

    func didDismiss() {
        resetTransientState()
    }

    /// 打开与收起时清掉一切临时状态(当前页保留,下次从同一页继续)
    private func resetTransientState() {
        cancelTimers()
        press = nil
        drag = nil
        pressedItemID = nil
        openFolderID = nil
        isEditingFolderName = false
        selection = nil
        folderSelection = nil
        pageOffset = 0
        folderPageOffset = 0
        query = ""
        searchResultIDs = []
        storedPage = currentPage
    }

    func requestDismiss() {
        actions.dismiss()
    }

    // MARK: 搜索

    func setQuery(_ newValue: String) {
        guard newValue != query else { return }
        query = newValue
        searchResultIDs = isSearching ? catalog.searchIndex.search(newValue) : []
        pageOffset = 0
        selection = searchResultIDs.isEmpty ? nil : ItemLocation(page: 0, index: 0)
        if isSearching {
            currentPage = 0
            // 只在结果数变化时播报,免得读屏排队念一串过期数字
            if searchResultIDs.count != lastAnnouncedResultCount {
                lastAnnouncedResultCount = searchResultIDs.count
                AccessibilityNotification.Announcement(searchResultIDs.isEmpty ? "无结果" : "\(searchResultIDs.count) 个结果").post()
            }
        } else {
            lastAnnouncedResultCount = nil
        }
    }

    // MARK: 翻页

    func goToPage(_ page: Int) {
        let before = currentPage
        withAnimation(Motion.page) {
            currentPage = page
            pageOffset = 0
        }
        if currentPage != before, NSWorkspace.shared.isVoiceOverEnabled {
            AccessibilityNotification.Announcement("第 \(currentPage + 1) 页,共 \(pageCount) 页").post()
        }
    }

    func goToFolderPage(_ page: Int) {
        withAnimation(Motion.page) {
            folderPage = page
            folderPageOffset = 0
        }
    }

    // MARK: 打开 App / 文件夹

    func activate(_ item: LaunchItem) {
        switch item {
        case .app(let appID): launch(appID)
        case .folder(let folder): openFolder(folder.id)
        }
    }

    func launch(_ appID: String) {
        guard let app = catalog.apps[appID] else { return }
        actions.launch(app)
    }

    func revealInFinder(_ appID: String) {
        guard let app = catalog.apps[appID] else { return }
        actions.reveal(app)
    }

    /// 读屏用户的「移到上一页/下一页」(拖拽的替代):放到目标页末尾,满页就占最后一格
    func moveItem(_ itemID: String, byPages delta: Int) {
        guard let removed = LayoutEngine.removing(itemID: itemID, from: catalog.layout),
              let from = catalog.layout.location(ofItem: itemID) else { return }
        let base = DragSession.withBlankPage(removed.layout)
        let page = Paging.clamp(from.page + delta, base.pages.count)
        guard !isSearching, page != from.page else { return }
        let index = min(base.page(at: page).count, metrics.capacity - 1)
        catalog.commit(LayoutEngine.inserting(removed.item, at: ItemLocation(page: page, index: index), in: base, capacity: metrics.capacity))
        currentPage = catalog.layout.location(ofItem: itemID)?.page ?? currentPage
    }

    func openFolder(_ folderID: String) {
        guard let folder = catalog.layout.folder(withID: folderID) else { return }
        folderNameDraft = folder.name
        storedFolderPage = 0
        folderPageOffset = 0
        selection = nil
        folderSelection = nil
        withAnimation(Motion.folder) { openFolderID = folderID }
    }

    func closeFolder() {
        endFolderRename()
        folderSelection = nil
        folderPageOffset = 0
        withAnimation(Motion.folder) { openFolderID = nil }
        searchFocusRequest += 1
    }

    /// 结束改名:写入名称并交还焦点
    func endFolderRename() {
        commitFolderName()
        isEditingFolderName = false
    }

    /// 文件夹改名:空名不收,未改动不写盘
    func commitFolderName() {
        guard let folderID = openFolderID, let folder = catalog.layout.folder(withID: folderID) else { return }
        let name = folderNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != folder.name else {
            folderNameDraft = folder.name
            return
        }
        catalog.commit(LayoutEngine.replacingFolder(folder.renamed(name), in: catalog.layout))
    }

    /// 右键「移出文件夹」:放到当前页末尾(满了往后挤)
    func moveOutOfFolder(_ appID: String, folderID: String) {
        let without = LayoutEngine.removingApp(appID, fromFolder: folderID, in: catalog.layout)
        let end = ItemLocation(page: currentPage, index: .max)
        catalog.commit(LayoutEngine.inserting(.app(appID), at: end, in: without, capacity: metrics.capacity))
        if catalog.layout.folder(withID: folderID) == nil { closeFolder() }
    }

    // MARK: 键盘

    struct KeyInput: Sendable {
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags
        let hasMarkedText: Bool
    }

    /// 返回 true 表示已处理、不再交给文本框
    func keyDown(_ key: KeyInput) -> Bool {
        // 输入法组字时的回车、方向键、Esc 都归输入法
        guard !key.hasMarkedText else { return false }
        let command = key.modifiers.contains(.command)
        switch key.keyCode {
        case KeyCode.escape:
            handleEscape()
            return true
        case _ where isEditingFolderName:
            return false
        case KeyCode.comma where command:
            actions.openSettings()
            return true
        case KeyCode.returnKey, KeyCode.enter:
            if openFolderID == nil { activateSelection() } else { activateFolderSelection() }
            return true
        case KeyCode.left where command:
            goToPage(currentPage - 1)
            return true
        case KeyCode.right where command:
            goToPage(currentPage + 1)
            return true
        case KeyCode.left, KeyCode.right, KeyCode.up, KeyCode.down:
            if openFolderID == nil {
                moveSelection(direction(for: key.keyCode))
            } else {
                moveFolderSelection(direction(for: key.keyCode))
            }
            return true
        case KeyCode.tab where openFolderID != nil:
            // 纯键盘也能改文件夹名
            folderNameFocusRequest += 1
            return true
        case KeyCode.space where openFolderID != nil:
            activateFolderSelection()
            return true
        default:
            // 文件夹开着时直接打字 = 开始搜索:先收起文件夹,按键交给搜索框
            if openFolderID != nil, !command { closeFolder() }
            return false
        }
    }

    private func direction(for keyCode: UInt16) -> GridNavigation.Direction {
        switch keyCode {
        case KeyCode.left: .left
        case KeyCode.right: .right
        case KeyCode.up: .up
        default: .down
        }
    }

    func handleEscape() {
        if drag != nil {
            cancelDrag()
        } else if isEditingFolderName {
            endFolderRename()
            searchFocusRequest += 1
        } else if openFolderID != nil {
            closeFolder()
        } else if !query.isEmpty {
            setQuery("")
        } else {
            requestDismiss()
        }
    }

    func moveSelection(_ direction: GridNavigation.Direction) {
        let pages = displayedPages
        guard let current = selection, pages.indices.contains(current.page) else {
            if pages[safe: currentPage]?.isEmpty == false {
                selection = ItemLocation(page: currentPage, index: 0)
            }
            return
        }
        let next = GridNavigation.move(from: current, direction, pageSizes: pages.map(\.count), columns: metrics.columns)
        selection = next
        if next.page != currentPage { goToPage(next.page) }
    }

    /// 文件夹内的方向键导航:按文件夹分页换算成页内位置,跨页时跟着翻
    func moveFolderSelection(_ direction: GridNavigation.Direction) {
        guard let folder = displayedFolder, !folder.appIDs.isEmpty else { return }
        let folderMetrics = folderMetrics(for: folder)
        let capacity = folderMetrics.capacity
        guard let current = folderSelection else {
            folderSelection = folderMetrics.folderIndex(page: folderPage, local: 0)
            return
        }
        let pageSizes = LayoutEngine.paginate(folder.appIDs.map(LaunchItem.app), capacity: capacity).map(\.count)
        let next = GridNavigation.move(
            from: ItemLocation(page: current / capacity, index: current % capacity),
            direction, pageSizes: pageSizes, columns: folderMetrics.columns
        )
        folderSelection = folderMetrics.folderIndex(page: next.page, local: next.index)
        if next.page != folderPage { goToFolderPage(next.page) }
    }

    func activateFolderSelection() {
        guard let index = folderSelection, let appID = displayedFolder?.appIDs[safe: index] else { return }
        launch(appID)
    }

    func activateSelection() {
        let location = selection ?? (isSearching ? ItemLocation(page: 0, index: 0) : nil)
        guard let location, let item = displayedPages[safe: location.page]?[safe: location.index] else { return }
        activate(item)
    }

    // MARK: 计时器

    func cancelTimers() {
        cancelReorder()
        cancelMerge()
        cancelEdgeFlip()
    }

    func cancelReorder() {
        pendingReorder?.cancel()
        pendingReorder = nil
        pendingReorderTarget = nil
        pendingFolderReorderIndex = nil
    }

    func cancelMerge() {
        pendingMerge?.cancel()
        pendingMerge = nil
        pendingMergeID = nil
    }

    func cancelEdgeFlip() {
        edgeFlip?.cancel()
        edgeFlip = nil
        edgeFlipDirection = 0
    }
}
