import Foundation
import Testing
@testable import LaunchpadCore

private func app(_ id: String, name: String? = nil, system: Bool = false, utility: Bool = false) -> AppEntry {
    AppEntry(id: id, name: name ?? id, url: URL(fileURLWithPath: "/Applications/\(id).app"), isSystem: system, isUtility: utility)
}

private func ids(_ layout: LaunchLayout) -> [[String]] {
    layout.pages.map { $0.map(\.id) }
}

private func apps(_ names: String...) -> [LaunchItem] {
    names.map(LaunchItem.app)
}

@Suite("LayoutEngine")
struct LayoutEngineTests {

    @Test("分页按容量切开,最后一页可以不满")
    func paginateSplitsByCapacity() {
        let pages = LayoutEngine.paginate(apps("a", "b", "c", "d", "e"), capacity: 2)
        #expect(pages.map { $0.map(\.id) } == [["app:a", "app:b"], ["app:c", "app:d"], ["app:e"]])
        #expect(LayoutEngine.paginate([], capacity: 3).isEmpty)
    }

    @Test("往满页插入时,末尾一格挤到下一页开头")
    func insertingIntoFullPageCascades() {
        let layout = LaunchLayout(pages: [apps("a", "b"), apps("c", "d")])
        let result = LayoutEngine.inserting(.app("x"), at: ItemLocation(page: 0, index: 1), in: layout, capacity: 2)
        #expect(ids(result) == [["app:a", "app:x"], ["app:b", "app:c"], ["app:d"]])
    }

    @Test("插入到不存在的页会补出新页,下标越界放页尾")
    func insertingBeyondLastPageCreatesPage() {
        let layout = LaunchLayout(pages: [apps("a")])
        let result = LayoutEngine.inserting(.app("x"), at: ItemLocation(page: 2, index: 9), in: layout, capacity: 4)
        #expect(ids(result) == [["app:a"], [], ["app:x"]])
        #expect(ids(LayoutEngine.normalized(result, capacity: 4)) == [["app:a"], ["app:x"]])
    }

    @Test("拿掉一格不从后一页往前补,空页保留到提交")
    func removingKeepsPagesIndependent() throws {
        let layout = LaunchLayout(pages: [apps("a"), apps("b", "c")])
        let removed = try #require(LayoutEngine.removing(itemID: "app:a", from: layout))
        #expect(removed.item == .app("a"))
        #expect(ids(removed.layout) == [[], ["app:b", "app:c"]])
        #expect(LayoutEngine.removing(itemID: "app:zzz", from: layout) == nil)
    }

    @Test("拖到 App 上建文件夹,拖到文件夹上追加")
    func mergingCreatesOrExtendsFolder() throws {
        let layout = LaunchLayout(pages: [apps("a", "b")])
        let created = try #require(LayoutEngine.merging(appID: "x", into: "app:b", in: layout, newFolderID: "f1", folderName: "效率"))
        #expect(created.pages[0][1] == .folder(Folder(id: "f1", name: "效率", appIDs: ["b", "x"])))

        let extended = try #require(LayoutEngine.merging(appID: "y", into: "folder:f1", in: created, newFolderID: "f2", folderName: "-"))
        #expect(extended.folder(withID: "f1")?.appIDs == ["b", "x", "y"])
    }

    @Test("合并到自己、不存在的目标或重复加入时返回 nil")
    func mergingRejectsInvalidTargets() throws {
        let layout = LaunchLayout(pages: [[.app("a"), .folder(Folder(id: "f", name: "F", appIDs: ["b"]))]])
        #expect(LayoutEngine.merging(appID: "a", into: "app:a", in: layout, newFolderID: "n", folderName: "N") == nil)
        #expect(LayoutEngine.merging(appID: "a", into: "app:none", in: layout, newFolderID: "n", folderName: "N") == nil)
        #expect(LayoutEngine.merging(appID: "b", into: "folder:f", in: layout, newFolderID: "n", folderName: "N") == nil)
    }

    @Test("文件夹拿空了就消失,剩一个仍保留")
    func removingFromFolder() {
        let folder = Folder(id: "f", name: "F", appIDs: ["b", "c"])
        let layout = LaunchLayout(pages: [[.app("a"), .folder(folder)]])
        let one = LayoutEngine.removingApp("b", fromFolder: "f", in: layout)
        #expect(one.folder(withID: "f")?.appIDs == ["c"])
        let none = LayoutEngine.removingApp("c", fromFolder: "f", in: one)
        #expect(ids(none) == [["app:a"]])
        #expect(LayoutEngine.removingApp("c", fromFolder: "missing", in: layout) == layout)
    }

    @Test("改文件夹名、调整文件夹内顺序")
    func replacingFolderUpdatesInPlace() {
        let layout = LaunchLayout(pages: [[.folder(Folder(id: "f", name: "F", appIDs: ["a", "b"])), .app("c")]])
        let renamed = LayoutEngine.replacingFolder(Folder(id: "f", name: "工作", appIDs: ["b", "a"]), in: layout)
        #expect(renamed.pages[0][0] == .folder(Folder(id: "f", name: "工作", appIDs: ["b", "a"])))
        #expect(renamed.pages[0][1] == .app("c"))
        let unknown = LayoutEngine.replacingFolder(Folder(id: "zz", name: "", appIDs: []), in: layout)
        #expect(unknown == layout)
    }

    @Test("对账:删掉卸载的和重复的,新装的按名称排到最后")
    func reconcileDropsMissingAndAppendsNew() {
        let layout = LaunchLayout(pages: [
            [.app("a"), .app("gone"), .folder(Folder(id: "f", name: "F", appIDs: ["b", "gone2"]))],
            [.app("a"), .folder(Folder(id: "g", name: "G", appIDs: ["gone3"]))],
        ])
        let installed = [app("a"), app("b"), app("zeta"), app("delta")]
        let result = LayoutEngine.reconciled(layout, with: installed, capacity: 3, utilitiesFolderID: "u")
        #expect(ids(result) == [["app:a", "folder:f"], ["app:delta", "app:zeta"]])
        #expect(result.folder(withID: "f")?.appIDs == ["b"])
    }

    @Test("对账时末页放不下就新开页")
    func reconcileOverflowsNewApps() {
        let layout = LaunchLayout(pages: [apps("a", "b")])
        let result = LayoutEngine.reconciled(layout, with: [app("a"), app("b"), app("c")], capacity: 2, utilitiesFolderID: "u")
        #expect(ids(result) == [["app:a", "app:b"], ["app:c"]])
    }

    @Test("空布局给默认排列:系统 App、「其他」文件夹、第三方 App")
    func defaultLayoutOrdersSystemFirst() {
        let installed = [
            app("zoom", name: "Zoom"),
            app("safari", name: "Safari", system: true),
            app("term", name: "Terminal", system: true, utility: true),
            app("maps", name: "Maps", system: true),
            app("chrome", name: "Chrome"),
        ]
        let result = LayoutEngine.reconciled(.empty, with: installed, capacity: 10, utilitiesFolderID: "u")
        #expect(ids(result) == [["app:maps", "app:safari", "folder:u", "app:chrome", "app:zoom"]])
        #expect(result.folder(withID: "u") == Folder(id: "u", name: "其他", appIDs: ["term"]))
    }

    @Test("没有实用工具时不建「其他」文件夹")
    func defaultLayoutWithoutUtilities() {
        let result = LayoutEngine.defaultLayout(for: [app("a"), app("b")], capacity: 1, utilitiesFolderID: "u")
        #expect(ids(result) == [["app:a"], ["app:b"]])
    }

    @Test("排序:数字按数值,大小写不敏感")
    func sortingIsNaturalAndCaseInsensitive() {
        let sorted = AppSorting.byName([app("1", name: "app10"), app("2", name: "App2"), app("3", name: "b")])
        #expect(sorted.map(\.name) == ["App2", "app10", "b"])
    }

    @Test("LaunchLayout 查找辅助")
    func layoutLookups() {
        let folder = Folder(id: "f", name: "F", appIDs: ["b", "c"])
        let layout = LaunchLayout(pages: [[.app("a")], [.folder(folder)]])
        #expect(layout.location(ofItem: "folder:f") == ItemLocation(page: 1, index: 0))
        #expect(layout.item(at: ItemLocation(page: 5, index: 0)) == nil)
        #expect(layout.allAppIDs == ["a", "b", "c"])
        #expect(!layout.isEmpty)
        #expect(LaunchLayout(pages: [[]]).isEmpty)
        #expect(LaunchItem.app("a").appID == "a")
        #expect(LaunchItem.folder(folder).appID == nil)
        #expect(LaunchItem.app("a").folder == nil)
    }
}
