import AppKit
import CMultitouch
import Foundation
import os
import SQLite3
import Testing
@testable import Launchpad
@testable import LaunchpadCore

@Suite("AppCatalog", .serialized)
@MainActor
struct AppCatalogTests {
    /// 造一份最小的旧启动台库:一页,Beta 在前,文件夹「工具」里放 Alpha
    private func makeLegacyDatabase(at url: URL) throws {
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE items (rowid INTEGER PRIMARY KEY, uuid VARCHAR, flags INTEGER, type INTEGER, parent_id INTEGER NOT NULL, ordering INTEGER);
        CREATE TABLE apps (item_id INTEGER PRIMARY KEY, title VARCHAR, bundleid VARCHAR, storeid VARCHAR, category_id INTEGER, moddate REAL, bookmark BLOB);
        CREATE TABLE groups (item_id INTEGER PRIMARY KEY, category_id INTEGER, title VARCHAR);
        CREATE TABLE dbinfo (key VARCHAR, value VARCHAR);
        INSERT INTO dbinfo VALUES ('launchpad_root', '1');
        INSERT INTO items (rowid, type, parent_id, ordering) VALUES (1,1,0,0), (2,3,1,0), (3,4,2,0), (4,2,2,1), (5,3,4,0), (6,4,5,0);
        INSERT INTO apps (item_id, title, bundleid) VALUES (3, 'Beta', 'test.beta'), (6, 'Alpha', 'test.alpha');
        INSERT INTO groups (item_id, title) VALUES (4, '工具');
        """
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    private func makeCatalog(_ f: Fixture, legacy: URL?) -> AppCatalog {
        AppCatalog(
            store: LayoutStore(fileURL: f.dir.appendingPathComponent("other.json")),
            scanner: AppScanner(roots: [f.dir.appendingPathComponent("Apps")]),
            capacity: { 8 },
            legacyDatabaseURL: { legacy }
        )
    }

    @Test("首次运行自动导入旧启动台排列,新装的排最后")
    func firstRunImportsLegacy() async throws {
        let f = try await Fixture(apps: ["Alpha", "Beta", "Gamma"])
        let db = f.dir.appendingPathComponent("legacy.db")
        try makeLegacyDatabase(at: db)
        let catalog = makeCatalog(f, legacy: db)
        catalog.loadSaved()
        await catalog.refresh(force: true)
        let page = try #require(catalog.layout.pages.first)
        #expect(page.map(\.id).first == "app:test.beta")
        #expect(page[1].folder?.name == "工具")
        #expect(page[1].folder?.appIDs == ["test.alpha"])
        #expect(page[2] == .app("test.gamma"))
        #expect(catalog.searchIndex.search("gam") == ["test.gamma"])

        // 已有排列后不再自动导入
        catalog.resetToDefault()
        let reloaded = makeCatalog(f, legacy: db)
        reloaded.loadSaved()
        await reloaded.refresh(force: true)
        #expect(reloaded.layout.pages.first?.map(\.id) == ["app:test.alpha", "app:test.beta", "app:test.gamma"])
    }

    @Test("手动导入:成功、找不到库、库损坏")
    func manualImport() async throws {
        let f = try await Fixture(apps: ["Alpha", "Beta"])
        let db = f.dir.appendingPathComponent("legacy.db")
        try makeLegacyDatabase(at: db)
        let catalog = makeCatalog(f, legacy: db)
        await catalog.refresh(force: true)
        guard case .imported(let count) = await catalog.importLegacyLayout() else {
            Issue.record("应当导入成功")
            return
        }
        #expect(count == 2)
        #expect(catalog.hasLegacyDatabase)

        guard case .notFound = await makeCatalog(f, legacy: nil).importLegacyLayout() else {
            Issue.record("没有库时应报 notFound")
            return
        }
        let broken = f.dir.appendingPathComponent("broken.db")
        try Data("garbage".utf8).write(to: broken)
        guard case .failed = await makeCatalog(f, legacy: broken).importLegacyLayout() else {
            Issue.record("坏库应报 failed")
            return
        }
    }

    @Test("排列文件坏了:备份后从默认排列重来")
    func brokenStoreIsBackedUp() async throws {
        let f = try await Fixture(apps: ["Alpha"])
        let store = f.dir.appendingPathComponent("other.json")
        try Data("{oops".utf8).write(to: store)
        let catalog = makeCatalog(f, legacy: nil)
        catalog.loadSaved()
        #expect(!FileManager.default.fileExists(atPath: store.path))
        let backups = try FileManager.default.contentsOfDirectory(atPath: f.dir.path).filter { $0.hasPrefix("other.json.broken-") }
        #expect(backups.count == 1)
        await catalog.refresh(force: true)
        #expect(catalog.layout.allAppIDs == ["test.alpha"])
        #expect(FileManager.default.fileExists(atPath: store.path))
    }

    @Test("App 短暂消失(更新、重装)时保留原位,回来后仍在原文件夹")
    func briefAbsenceKeepsPosition() async throws {
        let f = try await Fixture(apps: ["A", "B", "C"], missingGrace: 3600)
        f.catalog.commit(LaunchLayout(pages: [[.folder(Folder(id: "f", name: "F", appIDs: ["test.a", "test.b"])), .app("test.c")]]))
        let beta = f.dir.appendingPathComponent("Apps/Beta.app")
        let parked = f.dir.appendingPathComponent("Beta.app")
        try FileManager.default.moveItem(at: f.dir.appendingPathComponent("Apps/B.app"), to: parked)
        await f.catalog.refresh(force: true)
        #expect(f.catalog.layout.folder(withID: "f")?.appIDs == ["test.a", "test.b"])
        try FileManager.default.moveItem(at: parked, to: beta)
        await f.catalog.refresh(force: true)
        #expect(f.catalog.layout.folder(withID: "f")?.appIDs == ["test.a", "test.b"])
        #expect(f.ids == [["folder:f", "app:test.c"]])
    }

    @Test("重启后首次扫描时 App 恰好不在:靠存盘的 App 信息仍保留原位")
    func graceSurvivesRelaunch() async throws {
        let f = try await Fixture(apps: ["A", "B", "C"])
        f.catalog.commit(LaunchLayout(pages: [[.folder(Folder(id: "f", name: "F", appIDs: ["test.a", "test.b"])), .app("test.c")]]))
        try FileManager.default.moveItem(at: f.dir.appendingPathComponent("Apps/B.app"), to: f.dir.appendingPathComponent("B.app"))
        let relaunched = AppCatalog(
            store: LayoutStore(fileURL: f.dir.appendingPathComponent("layout.json")),
            scanner: AppScanner(roots: [f.dir.appendingPathComponent("Apps")]),
            capacity: { 8 }, legacyDatabaseURL: { nil }, missingGracePeriod: 3600
        )
        relaunched.loadSaved()
        #expect(relaunched.apps["test.b"]?.name == "B")
        await relaunched.refresh(force: true)
        #expect(relaunched.layout.folder(withID: "f")?.appIDs == ["test.a", "test.b"])
        let saved = try #require(try LayoutStore(fileURL: f.dir.appendingPathComponent("layout.json")).load())
        #expect(saved.layout.folder(withID: "f")?.appIDs == ["test.a", "test.b"])
    }

    @Test("提交基于旧快照的排列时,与当前 App 列表对账:新装的不丢,卸载的不留空格")
    func commitReconcilesStaleLayout() async throws {
        let f = try await Fixture(apps: ["A", "B"])
        f.catalog.commit(LaunchLayout(pages: [[.app("test.b"), .app("test.gone")]]))
        #expect(f.ids == [["app:test.b", "app:test.a"]])
    }

    @Test("扫描结果没变时不重写排列;卸载的 App(过了宽限期)被移除")
    func refreshReconciles() async throws {
        let f = try await Fixture(apps: ["Alpha", "Beta"])
        try FileManager.default.removeItem(at: f.dir.appendingPathComponent("Apps/Beta.app"))
        await f.catalog.refresh(force: true)
        #expect(f.catalog.layout.allAppIDs == ["test.alpha"])
        #expect(f.catalog.apps["test.beta"] == nil)
    }
}

@Suite("AppSettings", .serialized)
@MainActor
struct AppSettingsTests {
    @Test("默认值:左下角热角、7×5、显示菜单栏图标")
    func defaults() throws {
        let settings = AppSettings(defaults: try #require(UserDefaults(suiteName: "lp-\(UUID())")))
        #expect(settings.hotCorners == [.bottomLeft])
        #expect(settings.cornerModifier == .none)
        #expect(settings.columns == 7 && settings.rows == 5 && settings.capacity == 35)
        #expect(settings.showMenuBarIcon)
        #expect(settings.pinchGesture)
        #expect(settings.hotKey == nil)
    }

    @Test("改动即落盘并回调,重新读取一致;越界行列被夹住")
    func persistsAndNotifies() throws {
        let suite = "lp-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        var changed: [AppSettings.Key] = []
        settings.onChange = { changed.append($0) }
        settings.hotCorners = [.topRight, .bottomLeft]
        settings.cornerModifier = .option
        settings.cornerDelay = 0.5
        settings.hotKey = KeyCombo(keyCode: 0, modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue, keyLabel: "A")
        settings.showMenuBarIcon = false
        #expect(changed == [.hotCorners, .cornerModifier, .cornerDelay, .hotKey, .showMenuBarIcon])

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.hotCorners == [.topRight, .bottomLeft])
        #expect(reloaded.cornerModifier == .option)
        #expect(reloaded.cornerDelay == 0.5)
        #expect(reloaded.hotKey?.display == "⌥⌘A")
        #expect(!reloaded.showMenuBarIcon)

        defaults.set(99, forKey: AppSettings.Key.columns.rawValue)
        defaults.set(1, forKey: AppSettings.Key.rows.rawValue)
        let clamped = AppSettings(defaults: defaults)
        #expect(clamped.columns == AppSettings.columnRange.upperBound)
        #expect(clamped.rows == AppSettings.rowRange.lowerBound)
        settings.hotKey = nil
        #expect(defaults.data(forKey: AppSettings.Key.hotKey.rawValue) == nil)
    }

    @Test("修饰键标题与标志")
    func cornerModifiers() {
        #expect(CornerModifier.none.flags.isEmpty)
        #expect(CornerModifier.allCases.map(\.flags) == [[], .command, .option, .control, .shift])
        #expect(CornerModifier.allCases.allSatisfy { !$0.title.isEmpty })
    }
}

@Suite("图标与壁纸")
@MainActor
struct VisualCacheTests {
    @Test("图标缓存键带版本号,App 更新后重取")
    func iconKeyIncludesVersion() {
        let old = AppEntry(id: "x", name: "X", url: URL(fileURLWithPath: "/x"), version: "1.0 1")
        let new = AppEntry(id: "x", name: "X", url: URL(fileURLWithPath: "/x"), version: "2.0 7")
        #expect(IconProvider.key(old) != IconProvider.key(new))
        let moved = AppEntry(id: "x", name: "X", url: URL(fileURLWithPath: "/elsewhere/x"), version: "2.0 7")
        #expect(IconProvider.key(moved) != IconProvider.key(new))
    }

    @Test("亮壁纸自动压暗(按伽马编码空间混合计算),暗壁纸不动,最多压到 0.5")
    func minimumDim() {
        #expect(WallpaperProvider.minimumDim(forLuminance: 0.05) == 0)
        #expect(WallpaperProvider.minimumDim(forLuminance: 0.3) == 0)
        // 压暗后白字对比度正好 3:1
        for luminance in [0.4, 0.6, 0.9] {
            let dim = WallpaperProvider.minimumDim(forLuminance: luminance)
            let darkened = luminance * pow(1 - dim, 2.2)
            #expect(abs(1.05 / (darkened + 0.05) - 3) < 0.001)
        }
        #expect(WallpaperProvider.minimumDim(forLuminance: 1) < 0.5)
    }

    @Test("壁纸渲染:铺满裁切到目标尺寸,并测出平均亮度;读不出图返回 nil")
    func renderWallpaper() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lp-wall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func solid(_ white: CGFloat, name: String) throws -> URL {
            let rep = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor(white: white, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 64, height: 32).fill()
            NSGraphicsContext.restoreGraphicsState()
            let url = dir.appendingPathComponent(name)
            try #require(rep.representation(using: .png, properties: [:])).write(to: url)
            return url
        }
        let white = try #require(WallpaperProvider.render(url: try solid(1, name: "w.png"), size: CGSize(width: 40, height: 40), dark: true))
        #expect(white.image.image.width == 40 && white.image.image.height == 40)
        #expect(white.luminance > 0.8)
        let black = try #require(WallpaperProvider.render(url: try solid(0, name: "b.png"), size: CGSize(width: 40, height: 40), dark: false))
        #expect(black.luminance < 0.05)
        #expect(WallpaperProvider.render(url: dir.appendingPathComponent("missing.heic"), size: CGSize(width: 40, height: 40), dark: true) == nil)
    }
}

@Suite("触控板手势", .serialized)
struct TouchRelayTests {
    /// 四个触点围成半径 r 的一圈;state 4 = 接触中
    private func frame(_ r: Float, state: Int32 = 4) -> [LPMTTouch] {
        (0..<4).map { index in
            let angle = Float(index) / 4 * 2 * .pi
            var touch = LPMTTouch()
            touch.identifier = Int32(index + 1)
            touch.state = state
            touch.normalizedPosition.position = LPMTPoint(x: 0.5 + r * cos(angle) / 1.6, y: 0.5 + r * sin(angle))
            return touch
        }
    }

    private func feed(_ relay: TouchRelay, _ touches: [LPMTTouch], device: Int) {
        var copy = touches
        copy.withUnsafeMutableBufferPointer { buffer in
            relay.receive(device: UnsafeMutableRawPointer(bitPattern: device)!, touches: UnsafeBufferPointer(buffer))
        }
    }

    @Test("原始触点帧:合拢识别为捏合送出;悬停中的点不算;各设备分开计")
    func relaysGestures() {
        let relay = TouchRelay()
        let received = OSAllocatedUnfairLock(initialState: [PinchDetector.Gesture]())
        relay.connect { gesture in received.withLock { $0.append(gesture) } }

        feed(relay, frame(0.3), device: 0x10)
        feed(relay, frame(0.3), device: 0x20)
        feed(relay, frame(0.15, state: 2), device: 0x10)   // 悬停:不足四指,重置
        feed(relay, frame(0.3), device: 0x10)
        feed(relay, frame(0.15), device: 0x10)
        #expect(received.withLock { $0 } == [.pinchIn])

        feed(relay, frame(0.5), device: 0x20)
        #expect(received.withLock { $0 } == [.pinchIn, .pinchOut])

        relay.disconnect()
        feed(relay, frame(0.3), device: 0x10)
        feed(relay, frame(0.1), device: 0x10)
        #expect(received.withLock { $0 }.count == 2)
    }
}

@Suite("KeyCombo")
struct KeyComboTests {
    @Test("显示顺序 ⌃⌥⇧⌘,特殊键用符号")
    func display() {
        let all = NSEvent.ModifierFlags([.command, .shift, .option, .control]).rawValue
        #expect(KeyCombo(keyCode: 49, modifiers: all, keyLabel: "空格").display == "⌃⌥⇧⌘空格")
        #expect(KeyCombo.label(keyCode: 118, characters: nil) == "F4")
        #expect(KeyCombo.label(keyCode: 0, characters: "a") == "A")
        #expect(KeyCombo.label(keyCode: 0, characters: nil) == "?")
    }

    @Test("必须带 ⌘⌥⌃ 之一,F 键可以单按")
    func acceptable() {
        #expect(KeyCombo.isAcceptable(keyCode: 118, modifiers: []))
        #expect(!KeyCombo.isAcceptable(keyCode: 0, modifiers: []))
        #expect(!KeyCombo.isAcceptable(keyCode: 0, modifiers: .shift))
        #expect(KeyCombo.isAcceptable(keyCode: 0, modifiers: [.control]))
    }

    @Test("Carbon 修饰键换算")
    @MainActor
    func carbonModifiers() {
        #expect(GlobalHotKey.carbonModifiers([]) == 0)
        #expect(GlobalHotKey.carbonModifiers([.command, .option, .control, .shift]) == UInt32(0x0100 | 0x0800 | 0x1000 | 0x0200))
    }
}
