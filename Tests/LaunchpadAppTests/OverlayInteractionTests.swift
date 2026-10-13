import AppKit
import Foundation
import Testing
@testable import Launchpad
@testable import LaunchpadCore

/// 一套假 App + 临时排列文件 + 面板模型,记录模型发出的动作
@MainActor
final class Fixture {
    let dir: URL
    let settings: AppSettings
    let catalog: AppCatalog
    let model: OverlayModel
    private(set) var launched: [String] = []
    private(set) var dismissCount = 0
    private var clock: TimeInterval = 1000

    init(apps names: [String], columns: Int = 4, rows: Int = 2, missingGrace: TimeInterval = 0) async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lp-app-\(UUID().uuidString)")
        let appsDir = dir.appendingPathComponent("Apps")
        for name in names {
            let contents = appsDir.appendingPathComponent("\(name).app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": "test.\(name.lowercased())", "CFBundleName": name, "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
        }
        let defaults = try #require(UserDefaults(suiteName: "lp-test-\(UUID().uuidString)"))
        settings = AppSettings(defaults: defaults)
        settings.columns = columns
        settings.rows = rows
        catalog = AppCatalog(
            store: LayoutStore(fileURL: dir.appendingPathComponent("layout.json")),
            scanner: AppScanner(roots: [appsDir]),
            capacity: { [settings] in settings.capacity },
            legacyDatabaseURL: { nil },
            missingGracePeriod: missingGrace
        )
        model = OverlayModel(catalog: catalog, settings: settings, icons: IconProvider())
        model.actions = OverlayActions(
            dismiss: { [unowned self] in dismissCount += 1 },
            launch: { [unowned self] app in launched.append(app.id) },
            openSettings: {}
        )
        await catalog.refresh(force: true)
        model.prepareForPresentation(size: CGSize(width: 1000, height: 700))
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    var ids: [[String]] { catalog.layout.pages.map { $0.map(\.id) } }
    var metrics: GridMetrics { model.metrics }

    func iconCenter(_ index: Int) -> CGPoint { metrics.iconCenter(at: index) }

    /// 格子里偏右、避开图标中心的位置(只排序不合并)
    func cellEdge(_ index: Int) -> CGPoint {
        let center = iconCenter(index)
        return CGPoint(x: center.x + metrics.cellSize.width * 0.4, y: center.y)
    }

    func click(_ point: CGPoint) {
        _ = model.mouseDown(at: point)
        model.mouseUp(at: point)
    }

    /// 按下 → 依次经过各点(每点后等 `pause`)→ 可选松开
    func drag(from start: CGPoint, through points: [CGPoint], pause: Duration = .milliseconds(10), release: Bool = true) async throws {
        _ = model.mouseDown(at: start)
        move(to: CGPoint(x: start.x + 8, y: start.y + 8))
        for point in points {
            move(to: point)
            try await Task.sleep(for: pause)
        }
        if release, let last = points.last { model.mouseUp(at: last) }
    }

    func move(to point: CGPoint) {
        clock += 0.016
        model.mouseDragged(to: point, time: clock)
    }

    func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) -> Bool {
        model.keyDown(.init(keyCode: code, modifiers: modifiers, hasMarkedText: false))
    }

    func scroll(dx: CGFloat = 0, dy: CGFloat = 0, precise: Bool, phase: OverlayModel.ScrollInput.Phase) {
        clock += 0.016
        model.scroll(.init(deltaX: dx, deltaY: dy, isPrecise: precise, phase: phase, isMomentum: false, time: clock))
    }
}

private let settle = Duration.milliseconds(300)
private let mergeWait = Duration.milliseconds(550)

@Suite("面板交互", .serialized)
@MainActor
struct OverlayInteractionTests {

    // MARK: 点击

    @Test("首次运行按名称排好;点图标打开 App")
    func clickLaunches() async throws {
        let f = try await Fixture(apps: ["Gamma", "Alpha", "Beta"])
        #expect(f.ids == [["app:test.alpha", "app:test.beta", "app:test.gamma"]])
        f.click(f.iconCenter(1))
        #expect(f.launched == ["test.beta"])
        #expect(f.dismissCount == 0)
    }

    @Test("点空白处收起;点搜索框不拦截")
    func backgroundAndSearchField() async throws {
        let f = try await Fixture(apps: ["Alpha"])
        f.click(CGPoint(x: 5, y: 350))
        #expect(f.dismissCount == 1)
        let field = f.metrics.searchFieldRect
        #expect(f.model.mouseDown(at: CGPoint(x: field.midX, y: field.midY)) == false)
        // 格子里图标以外的空白也算背景
        f.click(CGPoint(x: f.cellEdge(0).x + f.metrics.cellSize.width * 0.08, y: f.metrics.gridRect.minY + 2))
        #expect(f.dismissCount == 2)
        #expect(f.launched.isEmpty)
    }

    @Test("点页码圆点翻页")
    func clickDot() async throws {
        let f = try await Fixture(apps: (1...10).map { "App\($0)" })
        let dots = f.metrics.dotRects(pageCount: f.model.pageCount)
        #expect(dots.count == 2)
        f.click(CGPoint(x: dots[1].midX, y: dots[1].midY))
        #expect(f.model.currentPage == 1)
    }

    // MARK: 拖拽

    @Test("拖到别的格子上排序")
    func dragReorders() async throws {
        let f = try await Fixture(apps: ["A", "B", "C", "D", "E"])
        try await f.drag(from: f.iconCenter(0), through: [f.cellEdge(2)], pause: settle)
        #expect(f.ids == [["app:test.b", "app:test.c", "app:test.a", "app:test.d", "app:test.e"]])
        #expect(f.model.drag == nil)
    }

    @Test("压在图标中心停住再松手,合成文件夹")
    func dropOnCenterCreatesFolder() async throws {
        let f = try await Fixture(apps: ["A", "B", "C", "D"])
        try await f.drag(from: f.iconCenter(0), through: [f.iconCenter(2)], pause: mergeWait)
        let page = try #require(f.catalog.layout.pages.first)
        #expect(page.count == 3)
        #expect(page[0] == .app("test.b"))
        let folder = try #require(page[1].folder)
        #expect(folder.appIDs == ["test.c", "test.a"])
        #expect(folder.name == FolderNaming.fallbackName)
        #expect(page[2] == .app("test.d"))
    }

    @Test("从旁边一路滑到相邻图标正中停住:目标不会先被挤开,能合成文件夹")
    func glideIntoNeighborCenterMerges() async throws {
        let f = try await Fixture(apps: ["A", "B", "C", "D"])
        let start = f.iconCenter(0)
        let end = f.iconCenter(1)
        let path = (1...12).map { step in
            CGPoint(x: start.x + (end.x - start.x) * CGFloat(step) / 12, y: start.y)
        }
        try await f.drag(from: start, through: path, pause: .milliseconds(40), release: false)
        try await Task.sleep(for: mergeWait)
        f.model.mouseUp(at: end)
        let page = try #require(f.catalog.layout.pages.first)
        #expect(page.first?.folder?.appIDs == ["test.b", "test.a"])
    }

    @Test("悬停在图标左半边插到它前面,右半边插到它后面")
    func insertionSideFollowsPointer() async throws {
        let f = try await Fixture(apps: ["A", "B", "C", "D"])
        let left = CGPoint(x: f.iconCenter(2).x - f.metrics.cellSize.width * 0.4, y: f.iconCenter(2).y)
        try await f.drag(from: f.iconCenter(3), through: [left], pause: settle)
        #expect(f.ids == [["app:test.a", "app:test.b", "app:test.d", "app:test.c"]])
    }

    @Test("拖到文件夹图标上加进文件夹")
    func dropIntoExistingFolder() async throws {
        let f = try await Fixture(apps: ["A", "B", "C"])
        f.catalog.commit(LaunchLayout(pages: [[.app("test.a"), .folder(Folder(id: "f", name: "F", appIDs: ["test.b"])), .app("test.c")]]))
        try await f.drag(from: f.iconCenter(2), through: [f.iconCenter(1)], pause: mergeWait)
        #expect(f.ids == [["app:test.a", "folder:f"]])
        #expect(f.catalog.layout.folder(withID: "f")?.appIDs == ["test.b", "test.c"])
    }

    @Test("Esc 取消拖拽,排列不变")
    func escapeCancelsDrag() async throws {
        let f = try await Fixture(apps: ["A", "B", "C"])
        let before = f.ids
        try await f.drag(from: f.iconCenter(0), through: [f.cellEdge(2)], pause: settle, release: false)
        #expect(f.model.drag != nil)
        #expect(f.key(KeyCode.escape))
        #expect(f.model.drag == nil)
        #expect(f.ids == before)
    }

    @Test("拖到屏幕右边缘停住,翻到新的一页并放在那里")
    func edgeFlipCreatesPage() async throws {
        let f = try await Fixture(apps: ["A", "B", "C"])
        try await f.drag(from: f.iconCenter(0), through: [CGPoint(x: 990, y: 300)], pause: .milliseconds(800))
        #expect(f.ids == [["app:test.b", "app:test.c"], ["app:test.a"]])
        #expect(f.model.currentPage == 1)
    }

    @Test("搜索时不能拖")
    func noDragWhileSearching() async throws {
        let f = try await Fixture(apps: ["Alpha", "Alpine"])
        f.model.setQuery("al")
        try await f.drag(from: f.iconCenter(0), through: [f.cellEdge(1)], pause: settle)
        #expect(f.model.drag == nil)
        #expect(f.ids == [["app:test.alpha", "app:test.alpine"]])
    }

    // MARK: 文件夹

    @Test("点文件夹打开;拖出面板后放回网格")
    func dragOutOfFolder() async throws {
        let f = try await Fixture(apps: ["A", "B", "C"])
        f.catalog.commit(LaunchLayout(pages: [[.app("test.a"), .folder(Folder(id: "f", name: "F", appIDs: ["test.b", "test.c"]))]]))
        f.click(f.iconCenter(1))
        #expect(f.model.openFolderID == "f")
        let folder = try #require(f.model.displayedFolder)
        let folderMetrics = f.model.folderMetrics(for: folder)
        let outside = CGPoint(x: 500, y: folderMetrics.panelRect.maxY + 60)
        try await f.drag(from: folderMetrics.iconCenter(at: 0), through: [outside, f.cellEdge(2)], pause: settle)
        #expect(f.model.openFolderID == nil)
        #expect(f.ids == [["app:test.a", "folder:f", "app:test.b"]])
        #expect(f.catalog.layout.folder(withID: "f")?.appIDs == ["test.c"])
    }

    @Test("文件夹内拖动调整顺序;点文件夹里的 App 打开它")
    func reorderInsideFolder() async throws {
        let f = try await Fixture(apps: ["A", "B", "C", "D"])
        f.catalog.commit(LaunchLayout(pages: [[.folder(Folder(id: "f", name: "F", appIDs: ["test.a", "test.b", "test.c"])), .app("test.d")]]))
        f.model.openFolder("f")
        let folderMetrics = f.model.folderMetrics(for: try #require(f.model.displayedFolder))
        let target = CGPoint(x: folderMetrics.iconCenter(at: 2).x + folderMetrics.cellSize.width * 0.4, y: folderMetrics.iconCenter(at: 2).y)
        try await f.drag(from: folderMetrics.iconCenter(at: 0), through: [target], pause: settle)
        #expect(f.catalog.layout.folder(withID: "f")?.appIDs == ["test.b", "test.c", "test.a"])
        f.click(folderMetrics.iconCenter(at: 1))
        #expect(f.launched == ["test.c"])
    }

    @Test("改名、点面板外关闭、Esc 关闭")
    func renameAndClose() async throws {
        let f = try await Fixture(apps: ["A", "B"])
        f.catalog.commit(LaunchLayout(pages: [[.folder(Folder(id: "f", name: "F", appIDs: ["test.a", "test.b"]))]]))
        f.model.openFolder("f")
        f.model.folderNameDraft = "  工作  "
        f.click(CGPoint(x: 10, y: 10))
        #expect(f.model.openFolderID == nil)
        #expect(f.catalog.layout.folder(withID: "f")?.name == "工作")
        #expect(f.dismissCount == 0)

        f.model.openFolder("f")
        f.model.folderNameDraft = "   "
        #expect(f.key(KeyCode.escape))
        #expect(f.model.openFolderID == nil)
        #expect(f.catalog.layout.folder(withID: "f")?.name == "工作")
    }

    @Test("右键「移出文件夹」放到当前页末尾,最后一个移走文件夹消失")
    func moveOutOfFolder() async throws {
        let f = try await Fixture(apps: ["A", "B"])
        f.catalog.commit(LaunchLayout(pages: [[.folder(Folder(id: "f", name: "F", appIDs: ["test.a", "test.b"]))]]))
        f.model.openFolder("f")
        f.model.moveOutOfFolder("test.a", folderID: "f")
        #expect(f.ids == [["folder:f", "app:test.a"]])
        f.model.moveOutOfFolder("test.b", folderID: "f")
        #expect(f.ids == [["app:test.a", "app:test.b"]])
        #expect(f.model.openFolderID == nil)
    }

    // MARK: 键盘与搜索

    @Test("方向键移动选中,回车打开")
    func keyboardNavigation() async throws {
        let f = try await Fixture(apps: ["A", "B", "C", "D", "E", "F"])
        #expect(f.key(KeyCode.right))
        #expect(f.model.selection == ItemLocation(page: 0, index: 0))
        #expect(f.key(KeyCode.right))
        #expect(f.key(KeyCode.down))
        #expect(f.model.selection == ItemLocation(page: 0, index: 5))
        #expect(f.key(KeyCode.returnKey))
        #expect(f.launched == ["test.f"])
    }

    @Test("搜索:回车打开第一个结果;Esc 先清空搜索再收起")
    func searchFlow() async throws {
        let f = try await Fixture(apps: ["Alpha", "Beta", "Gamma"])
        f.model.setQuery("gam")
        #expect(f.model.searchResultIDs == ["test.gamma"])
        #expect(f.model.displayedPages == [[.app("test.gamma")]])
        #expect(f.key(KeyCode.enter))
        #expect(f.launched == ["test.gamma"])
        #expect(f.key(KeyCode.escape))
        #expect(f.model.query.isEmpty)
        #expect(f.dismissCount == 0)
        #expect(f.key(KeyCode.escape))
        #expect(f.dismissCount == 1)
    }

    @Test("输入法组字时按键交给输入法;其他键交给搜索框")
    func passThroughKeys() async throws {
        let f = try await Fixture(apps: ["Alpha"])
        #expect(f.model.keyDown(.init(keyCode: KeyCode.returnKey, modifiers: [], hasMarkedText: true)) == false)
        #expect(f.key(0) == false)
    }

    @Test("⌘← ⌘→ 翻页")
    func commandArrowsFlip() async throws {
        let f = try await Fixture(apps: (1...10).map { "App\($0)" })
        #expect(f.key(KeyCode.right, .command))
        #expect(f.model.currentPage == 1)
        #expect(f.key(KeyCode.left, .command))
        #expect(f.model.currentPage == 0)
    }

    // MARK: 翻页手势

    @Test("触控板横扫翻页,扫得不够回弹")
    func trackpadSwipe() async throws {
        let f = try await Fixture(apps: (1...10).map { "App\($0)" })
        f.scroll(precise: true, phase: .began)
        for _ in 0..<10 { f.scroll(dx: -30, precise: true, phase: .changed) }
        f.scroll(precise: true, phase: .ended)
        #expect(f.model.currentPage == 1)

        f.scroll(precise: true, phase: .began)
        f.scroll(dx: 5, precise: true, phase: .changed)
        f.scroll(precise: true, phase: .ended)
        #expect(f.model.currentPage == 1)
        #expect(f.model.pageOffset == 0)
    }

    @Test("鼠标滚轮一格翻一页,有冷却")
    func wheelFlip() async throws {
        let f = try await Fixture(apps: (1...20).map { "App\($0)" })
        f.scroll(dy: -1, precise: false, phase: .none)
        f.scroll(dy: -1, precise: false, phase: .none)
        #expect(f.model.currentPage == 1)
    }

    @Test("按住空白处拖动翻页")
    func backgroundPan() async throws {
        let f = try await Fixture(apps: (1...10).map { "App\($0)" })
        let y = f.metrics.gridRect.maxY + 10
        _ = f.model.mouseDown(at: CGPoint(x: 800, y: y))
        for x in stride(from: 780, through: 300, by: -60) { f.move(to: CGPoint(x: CGFloat(x), y: y)) }
        f.model.mouseUp(at: CGPoint(x: 300, y: y))
        #expect(f.model.currentPage == 1)
        #expect(f.dismissCount == 0)
    }

    // MARK: 审查修复的回归

    @Test("停在图标上高亮后移出网格再松手,不建文件夹")
    func mergeHighlightClearsOutsideGrid() async throws {
        let f = try await Fixture(apps: ["A", "B", "C", "D"])
        let before = f.ids
        let outside = CGPoint(x: 500, y: f.metrics.gridRect.maxY + 10)
        try await f.drag(from: f.iconCenter(0), through: [f.iconCenter(2)], pause: mergeWait, release: false)
        #expect(f.model.drag?.mergeTargetID == "app:test.c")
        f.move(to: outside)
        #expect(f.model.drag?.mergeTargetID == nil)
        f.model.mouseUp(at: outside)
        #expect(f.catalog.layout.pages.joined().allSatisfy { $0.folder == nil })
        #expect(Set(f.ids.joined()) == Set(before.joined()))
    }

    @Test("拖走某页唯一的图标后,视图停在图标落下的那一页")
    func landsOnDroppedPage() async throws {
        let f = try await Fixture(apps: ["A", "B", "C", "D", "E"], columns: 2, rows: 1)
        f.catalog.commit(LaunchLayout(pages: [[.app("test.a")], [.app("test.b"), .app("test.c")], [.app("test.d"), .app("test.e")]]))
        try await f.drag(from: f.iconCenter(0), through: [CGPoint(x: 990, y: f.iconCenter(0).y)], pause: .milliseconds(700), release: false)
        #expect(f.model.currentPage == 1)
        f.model.mouseUp(at: CGPoint(x: 990, y: f.iconCenter(0).y))
        let landed = try #require(f.catalog.layout.page(containingApp: "test.a"))
        #expect(f.model.currentPage == landed)
        #expect(f.catalog.layout.page(at: f.model.currentPage).contains(.app("test.a")))
    }

    @Test("搜索时按住结果拖开再松手,不打开 App")
    func searchPressDraggedAwayDoesNotLaunch() async throws {
        let f = try await Fixture(apps: ["Alpha", "Beta"])
        f.model.setQuery("alp")
        _ = f.model.mouseDown(at: f.iconCenter(0))
        f.move(to: CGPoint(x: 900, y: 600))
        f.model.mouseUp(at: CGPoint(x: 900, y: 600))
        #expect(f.launched.isEmpty)
        #expect(f.model.pressedItemID == nil)
    }

    @Test("文件夹开着时直接打字:收起文件夹,按键交给搜索框")
    func typingWithFolderOpenStartsSearch() async throws {
        let f = try await Fixture(apps: ["A", "B"])
        f.catalog.commit(LaunchLayout(pages: [[.folder(Folder(id: "f", name: "F", appIDs: ["test.a", "test.b"]))]]))
        f.model.openFolder("f")
        #expect(f.key(0) == false)
        #expect(f.model.openFolderID == nil)
    }

    @Test("双击文件夹:第二下不打开刚弹出面板里的 App")
    func doubleClickFolderDoesNotLaunch() async throws {
        let f = try await Fixture(apps: ["A", "B", "C"])
        f.catalog.commit(LaunchLayout(pages: [[.folder(Folder(id: "f", name: "F", appIDs: ["test.a", "test.b", "test.c"]))]]))
        f.click(f.iconCenter(0))
        #expect(f.model.openFolderID == "f")
        let folderMetrics = f.model.folderMetrics(for: try #require(f.model.displayedFolder))
        let point = folderMetrics.iconCenter(at: 1)
        _ = f.model.mouseDown(at: point, clickCount: 2)
        f.model.mouseUp(at: point)
        #expect(f.launched.isEmpty)
        #expect(f.model.openFolderID == "f")
    }

    @Test("双击屏幕边上的文件夹:第二下落在面板外也不会把它关掉")
    func doubleClickFarFolderStaysOpen() async throws {
        let f = try await Fixture(apps: ["A", "B"])
        f.catalog.commit(LaunchLayout(pages: [[.folder(Folder(id: "f", name: "F", appIDs: ["test.a", "test.b"]))]]))
        let point = f.iconCenter(0)
        f.click(point)
        #expect(f.model.openFolderID == "f")
        _ = f.model.mouseDown(at: point, clickCount: 2)
        f.model.mouseUp(at: point)
        #expect(f.model.openFolderID == "f")
        #expect(!f.model.isEditingFolderName)
    }

    @Test("快速一拖后停住再松手,不算甩,回到原页")
    func pausedFlingDoesNotFlip() async throws {
        let f = try await Fixture(apps: (1...10).map { "App\($0)" })
        let y = f.metrics.gridRect.maxY + 10
        _ = f.model.mouseDown(at: CGPoint(x: 600, y: y))
        f.move(to: CGPoint(x: 590, y: y))
        f.move(to: CGPoint(x: 570, y: y))
        f.model.mouseUp(at: CGPoint(x: 570, y: y), time: 5000)
        #expect(f.model.currentPage == 0)
    }

    @Test("Tab 在文件夹里不做事;有选中项时空格打开")
    func tabAndSpaceInFolder() async throws {
        let f = try await Fixture(apps: ["A", "B"])
        f.catalog.commit(LaunchLayout(pages: [[.folder(Folder(id: "f", name: "F", appIDs: ["test.a", "test.b"]))]]))
        f.model.openFolder("f")
        #expect(f.key(KeyCode.tab))
        #expect(f.model.openFolderID == "f")
        #expect(f.key(KeyCode.right))
        #expect(f.key(KeyCode.space))
        #expect(f.launched == ["test.a"])
    }

    @Test("读屏「移到下一页/上一页」:放到目标页末尾,视图跟过去")
    func moveItemByPages() async throws {
        let f = try await Fixture(apps: ["A", "B", "C"], columns: 2, rows: 1)
        #expect(f.ids == [["app:test.a", "app:test.b"], ["app:test.c"]])
        f.model.moveItem("app:test.a", byPages: 1)
        #expect(f.ids == [["app:test.b"], ["app:test.c", "app:test.a"]])
        #expect(f.model.currentPage == 1)
        f.model.moveItem("app:test.c", byPages: -1)
        #expect(f.ids == [["app:test.b", "app:test.c"], ["app:test.a"]])
        f.model.moveItem("app:test.a", byPages: 1)
        #expect(f.ids == [["app:test.b", "app:test.c"], ["app:test.a"]])
    }

    @Test("改名时在文件夹名上双击(选词)照常交给文本框,不结束改名")
    func doubleClickTitleKeepsEditing() async throws {
        let f = try await Fixture(apps: ["A", "B"])
        f.catalog.commit(LaunchLayout(pages: [[.folder(Folder(id: "f", name: "F", appIDs: ["test.a", "test.b"]))]]))
        f.model.openFolder("f")
        f.model.isEditingFolderName = true
        let title = f.model.folderMetrics(for: try #require(f.model.displayedFolder)).titleRect
        #expect(f.model.mouseDown(at: CGPoint(x: title.midX, y: title.midY), clickCount: 2) == false)
        #expect(f.model.isEditingFolderName)
    }

    @Test("读屏移动:首页「上一页」、搜索中都不动排列")
    func moveItemGuards() async throws {
        let f = try await Fixture(apps: ["A", "B", "C"], columns: 2, rows: 1)
        let before = f.ids
        f.model.moveItem("app:test.a", byPages: -1)
        #expect(f.ids == before)
        f.model.setQuery("c")
        f.model.moveItem("app:test.c", byPages: 1)
        #expect(f.ids == before)
    }

    @Test("Tab 请求给文件夹名焦点;只有空格的搜索按 Esc 先清空")
    func tabRenamesAndEscClearsWhitespace() async throws {
        let f = try await Fixture(apps: ["A", "B"])
        f.catalog.commit(LaunchLayout(pages: [[.folder(Folder(id: "f", name: "F", appIDs: ["test.a", "test.b"]))]]))
        f.model.openFolder("f")
        let request = f.model.folderNameFocusRequest
        #expect(f.key(KeyCode.tab))
        #expect(f.model.folderNameFocusRequest == request + 1)
        f.model.closeFolder()
        f.model.setQuery(" ")
        #expect(f.key(KeyCode.escape))
        #expect(f.model.query.isEmpty)
        #expect(f.dismissCount == 0)
    }

    @Test("文件夹翻页手势中途关掉文件夹,位移不残留")
    func folderOffsetResets() async throws {
        let f = try await Fixture(apps: (1...30).map { "App\($0)" }, columns: 4, rows: 2)
        let ids = (1...30).map { "test.app\($0)" }
        f.catalog.commit(LaunchLayout(pages: [[.folder(Folder(id: "f", name: "F", appIDs: ids))]]))
        f.model.openFolder("f")
        f.scroll(precise: true, phase: .began)
        f.scroll(dx: -150, precise: true, phase: .changed)
        #expect(f.model.folderPageOffset != 0)
        f.model.closeFolder()
        #expect(f.model.folderPageOffset == 0)
    }

    @Test("文件夹打开时方向键在文件夹里移动,回车打开")
    func keyboardInsideFolder() async throws {
        let f = try await Fixture(apps: ["A", "B", "C", "D", "E"])
        let ids = ["test.a", "test.b", "test.c", "test.d", "test.e"]
        f.catalog.commit(LaunchLayout(pages: [[.folder(Folder(id: "f", name: "F", appIDs: ids))]]))
        f.model.openFolder("f")
        #expect(f.key(KeyCode.right))
        #expect(f.model.folderSelection == 0)
        #expect(f.key(KeyCode.down))
        #expect(f.model.folderSelection == 4)
        #expect(f.key(KeyCode.returnKey))
        #expect(f.launched == ["test.e"])
        #expect(f.model.selection == nil)
    }

    @Test("首末页的橡皮筋阻尼只施加一次,不会越扫越推不动")
    func rubberBandDoesNotCompound() async throws {
        let f = try await Fixture(apps: ["A"])
        f.scroll(precise: true, phase: .began)
        for _ in 0..<20 { f.scroll(dx: -30, precise: true, phase: .changed) }
        #expect(abs(f.model.pageOffset - (-600 * 0.3)) < 0.001)
        f.scroll(precise: true, phase: .ended)
        #expect(f.model.pageOffset == 0)
    }

    // MARK: 设置联动

    @Test("改行列后重排,满页往后挤")
    func reflowAfterGridChange() async throws {
        let f = try await Fixture(apps: ["A", "B", "C", "D", "E"], columns: 4, rows: 2)
        #expect(f.ids.count == 1)
        f.settings.columns = 2
        f.settings.rows = 1
        f.catalog.reflow()
        #expect(f.ids.map(\.count) == [2, 3] || f.ids.map(\.count) == [2, 2, 1])
    }
}
