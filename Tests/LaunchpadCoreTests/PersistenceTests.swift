import Foundation
import SQLite3
import Testing
@testable import LaunchpadCore

/// 每个测试一个独立临时目录
struct TempDir: ~Copyable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("lp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

@Suite("LayoutStore")
struct LayoutStoreTests {
    @Test("保存后读回一致(排列 + 已知 App);文件不存在返回 nil")
    func roundTrip() throws {
        let dir = try TempDir()
        let store = LayoutStore(fileURL: dir.url.appendingPathComponent("sub/layout.json"))
        #expect(try store.load() == nil)
        let layout = LaunchLayout(pages: [[.app("a"), .folder(Folder(id: "f", name: "工作", appIDs: ["b"]))], [.app("c")]])
        let apps = [
            AppEntry(id: "b", name: "Beta", url: URL(fileURLWithPath: "/Applications/Beta.app"), version: "2.0 (5)"),
            AppEntry(id: "a", name: "微信", bundleID: "com.a", url: URL(fileURLWithPath: "/Applications/A.app"), isSystem: true),
        ]
        try store.save(.init(layout: layout, apps: apps))
        let loaded = try #require(try store.load())
        #expect(loaded.layout == layout)
        #expect(loaded.apps == apps.sorted { $0.id < $1.id })
    }

    @Test("没有 apps 字段的旧文件照常读取")
    func readsFileWithoutApps() throws {
        let dir = try TempDir()
        let url = dir.url.appendingPathComponent("layout.json")
        try Data(#"{"version": 1, "pages": [[{"app": "x"}]]}"#.utf8).write(to: url)
        let loaded = try #require(try LayoutStore(fileURL: url).load())
        #expect(loaded.layout == LaunchLayout(pages: [[.app("x")]]))
        #expect(loaded.apps.isEmpty)
    }

    @Test("坏文件、未来版本都报错")
    func corruptAndFutureVersion() throws {
        let dir = try TempDir()
        let url = dir.url.appendingPathComponent("layout.json")
        let store = LayoutStore(fileURL: url)
        try Data("not json".utf8).write(to: url)
        #expect(throws: LayoutStore.StoreError.self) { try store.load() }
        try Data(#"{"version": 99, "pages": []}"#.utf8).write(to: url)
        #expect(throws: LayoutStore.StoreError.unsupportedVersion(99)) { try store.load() }
        try Data(#"{"version": 1, "pages": [[{"bogus": 1}]]}"#.utf8).write(to: url)
        #expect(throws: LayoutStore.StoreError.self) { try store.load() }
    }

    @Test("写到不可写位置报错")
    func unwritable() {
        let store = LayoutStore(fileURL: URL(fileURLWithPath: "/dev/null/layout.json"))
        #expect(throws: LayoutStore.StoreError.self) { try store.save(.init(layout: .empty, apps: [])) }
    }
}

@Suite("AppScanner")
struct AppScannerTests {
    private func makeApp(_ dir: URL, _ relative: String, plist: [String: Any]?) throws {
        let app = dir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        if let plist {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        }
    }

    @Test("递归找到 .app、不进包内部、解析符号链接、重复 bundle id 用路径作键")
    func scansBundles() throws {
        let dir = try TempDir()
        let root = dir.url
        try makeApp(root, "Alpha.app", plist: [
            "CFBundleIdentifier": "com.a", "CFBundleName": "Alpha", "LSApplicationCategoryType": "public.app-category.games",
            "CFBundleShortVersionString": "1.2", "CFBundleVersion": "34",
        ])
        try makeApp(root, "Vendor/Beta.app", plist: ["CFBundleIdentifier": "com.dup"])
        try makeApp(root, "Vendor/Gamma.app", plist: ["CFBundleIdentifier": "com.dup"])
        try makeApp(root, "Utilities/Tool.app", plist: ["CFBundleIdentifier": "com.tool"])
        try makeApp(root, "Alpha.app/Contents/Helpers/Inner.app", plist: ["CFBundleIdentifier": "com.inner"])
        try makeApp(root, "Broken.app", plist: nil)
        try makeApp(root, "Plugin.app", plist: ["CFBundleIdentifier": "com.plugin", "CFBundlePackageType": "BNDL"])
        try makeApp(root, "Self.app", plist: ["CFBundleIdentifier": "com.self"])
        try makeApp(root, "a/b/c/Deep.app", plist: ["CFBundleIdentifier": "com.deep"])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Link.app"), withDestinationURL: root.appendingPathComponent("Alpha.app"))

        let apps = AppScanner(roots: [root], excludedBundleIDs: ["com.self"]).scan()
        let byName = Dictionary(uniqueKeysWithValues: apps.map { ($0.name, $0) })

        #expect(Set(byName.keys) == ["Alpha", "Beta", "Gamma", "Tool"])
        #expect(byName["Alpha"]?.id == "com.a")
        #expect(byName["Alpha"]?.category == "public.app-category.games")
        #expect(byName["Alpha"]?.bundleName == "Alpha")
        #expect(byName["Alpha"]?.version == "1.2 34")
        #expect(byName["Tool"]?.version == nil)
        let dupIDs = [byName["Beta"]!.id, byName["Gamma"]!.id]
        #expect(dupIDs.filter { $0 == "com.dup" }.count == 1)
        #expect(dupIDs.contains { $0.hasSuffix(".app") })
        #expect(byName["Tool"]?.isUtility == true)
        #expect(byName["Tool"]?.isSystem == false)
    }

    @Test("同 bundle id 装了多份:每份沿用上次的键,新装的一份不会顶掉旧的")
    func duplicateIDsAreSticky() throws {
        let dir = try TempDir()
        let root = dir.url
        try makeApp(root, "B.app", plist: ["CFBundleIdentifier": "com.dup"])
        let first = AppScanner(roots: [root]).scan()
        #expect(first.map(\.id) == ["com.dup"])
        // 新装一份,且在目录里排在前面
        try makeApp(root, "A.app", plist: ["CFBundleIdentifier": "com.dup"])
        let second = AppScanner(roots: [root]).scan(previous: first)
        let byName = Dictionary(uniqueKeysWithValues: second.map { ($0.name, $0.id) })
        #expect(byName["B"] == "com.dup")
        #expect(byName["A"]?.hasSuffix("A.app") == true)
    }

    @Test("不存在的根目录返回空")
    func missingRoot() {
        #expect(AppScanner(roots: [URL(fileURLWithPath: "/nonexistent-\(UUID())")]).scan().isEmpty)
    }

    @Test("真实系统目录能扫到 App(冒烟)")
    func scansSystemApplications() {
        let apps = AppScanner(roots: [URL(fileURLWithPath: "/System/Applications")]).scan()
        #expect(apps.contains { $0.bundleID == "com.apple.calculator" && $0.isSystem })
        #expect(apps.contains { $0.isUtility })
    }
}

@Suite("LegacyLaunchpad")
struct LegacyLaunchpadTests {
    /// 造一份与旧启动台同结构的库:根 1 → 页 10(空)、页 11、页 12;页 11 上有文件夹 20
    private func makeDatabase(at url: URL) throws {
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE items (rowid INTEGER PRIMARY KEY ASC, uuid VARCHAR, flags INTEGER, type INTEGER, parent_id INTEGER NOT NULL, ordering INTEGER);
        CREATE TABLE apps (item_id INTEGER PRIMARY KEY, title VARCHAR, bundleid VARCHAR, storeid VARCHAR, category_id INTEGER, moddate REAL, bookmark BLOB);
        CREATE TABLE groups (item_id INTEGER PRIMARY KEY, category_id INTEGER, title VARCHAR);
        CREATE TABLE dbinfo (key VARCHAR, value VARCHAR);
        INSERT INTO dbinfo VALUES ('launchpad_root', '1');
        INSERT INTO items (rowid, type, parent_id, ordering) VALUES
          (1, 1, 0, 0), (5, 1, 0, 0),
          (10, 3, 1, 1), (11, 3, 1, 2), (12, 3, 1, 61), (6, 3, 5, 0),
          (30, 4, 11, 3), (31, 4, 11, 0), (20, 2, 11, 1), (21, 3, 20, 0), (40, 4, 21, 0), (41, 4, 21, 1),
          (32, 4, 11, 2), (50, 4, 12, 0), (51, 4, 6, 0), (22, 2, 12, 1), (23, 3, 22, 0);
        INSERT INTO apps (item_id, title, bundleid) VALUES
          (30, '微信', 'com.tencent.xinWeChat'), (31, 'Safari', 'com.apple.Safari'), (32, '卸载', 'com.dup'),
          (40, '终端', 'com.apple.Terminal'), (41, '旧东西', 'com.gone'),
          (50, '卸载', 'com.dup'), (51, '隐藏', 'com.hidden');
        INSERT INTO groups (item_id, title) VALUES (20, '其他'), (22, '空文件夹');
        """
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test("读出页、文件夹与顺序,跳过空页、空文件夹和别的根")
    func readsTree() throws {
        let dir = try TempDir()
        let url = dir.url.appendingPathComponent("db")
        try makeDatabase(at: url)
        let legacy = try LegacyLaunchpadReader.read(databaseAt: url)
        #expect(legacy.pages == [
            [
                .app(LegacyApp(bundleID: "com.apple.Safari", title: "Safari")),
                .folder(title: "其他", apps: [
                    LegacyApp(bundleID: "com.apple.Terminal", title: "终端"),
                    LegacyApp(bundleID: "com.gone", title: "旧东西"),
                ]),
                .app(LegacyApp(bundleID: "com.dup", title: "卸载")),
                .app(LegacyApp(bundleID: "com.tencent.xinWeChat", title: "微信")),
            ],
            [.app(LegacyApp(bundleID: "com.dup", title: "卸载"))],
        ])
        #expect(legacy.appCount == 6)
    }

    @Test("库不存在、不是库都报错")
    func readErrors() throws {
        #expect(throws: LegacyLaunchpadReader.ReadError.notFound) {
            try LegacyLaunchpadReader.read(databaseAt: URL(fileURLWithPath: "/nonexistent/db"))
        }
        let dir = try TempDir()
        let url = dir.url.appendingPathComponent("db")
        try Data("garbage".utf8).write(to: url)
        #expect(throws: LegacyLaunchpadReader.ReadError.self) { try LegacyLaunchpadReader.read(databaseAt: url) }
    }

    @Test("映射到已安装 App:同 bundle id 多份依次分配,没装的丢弃,新装的排最后")
    func mapsToInstalledApps() throws {
        let dir = try TempDir()
        let url = dir.url.appendingPathComponent("db")
        try makeDatabase(at: url)
        let legacy = try LegacyLaunchpadReader.read(databaseAt: url)
        let installed = [
            AppEntry(id: "com.apple.Safari", name: "Safari", bundleID: "com.apple.Safari", url: URL(fileURLWithPath: "/s")),
            AppEntry(id: "com.apple.Terminal", name: "终端", bundleID: "com.apple.Terminal", url: URL(fileURLWithPath: "/t")),
            AppEntry(id: "com.dup", name: "卸载 A", bundleID: "com.dup", url: URL(fileURLWithPath: "/d1")),
            AppEntry(id: "/d2", name: "卸载 B", bundleID: "com.dup", url: URL(fileURLWithPath: "/d2")),
            AppEntry(id: "com.new", name: "New", bundleID: "com.new", url: URL(fileURLWithPath: "/n")),
        ]
        var counter = 0
        let layout = LegacyLayoutMapper.layout(from: legacy, apps: installed, capacity: 3) {
            counter += 1
            return "f\(counter)"
        }
        #expect(layout.pages.map { $0.map(\.id) } == [
            ["app:com.apple.Safari", "folder:f1", "app:com.dup"],
            ["app:/d2", "app:com.new"],
        ])
        #expect(layout.folder(withID: "f1") == Folder(id: "f1", name: "其他", appIDs: ["com.apple.Terminal"]))
    }

    @Test("本机默认库路径要么不存在,要么指向 com.apple.dock.launchpad")
    func defaultURL() {
        if let url = LegacyLaunchpadReader.defaultDatabaseURL() {
            #expect(url.path.contains("com.apple.dock.launchpad/db/db"))
        }
    }
}
