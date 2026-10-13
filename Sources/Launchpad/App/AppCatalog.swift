import Foundation
import LaunchpadCore
import Observation

/// 已安装 App + 当前排列。扫描在后台线程,结果回主线程对账、落盘。
@MainActor
@Observable
final class AppCatalog {
    private(set) var apps: [String: AppEntry] = [:]
    private(set) var layout: LaunchLayout = .empty
    private(set) var searchIndex = SearchIndex(apps: [], order: [])

    @ObservationIgnored private let store: LayoutStore
    @ObservationIgnored private let scanner: AppScanner
    @ObservationIgnored private let capacity: () -> Int
    @ObservationIgnored private let legacyDatabaseURL: () -> URL?
    @ObservationIgnored private let missingGracePeriod: TimeInterval
    /// 扫描时不见了的 App 从何时开始不见。更新、重装时 App 会短暂消失,宽限期内保留它的位置
    @ObservationIgnored private var missingSince: [String: Date] = [:]
    /// 还没有自己的排列文件:第一次扫描完时先尝试导入旧启动台
    @ObservationIgnored private var isFirstRun = true
    @ObservationIgnored private var lastScan: Date = .distantPast
    @ObservationIgnored private var isScanning = false

    static let minimumRescanInterval: TimeInterval = 5
    static let defaultMissingGracePeriod: TimeInterval = 30 * 60

    init(
        store: LayoutStore,
        scanner: AppScanner,
        capacity: @escaping () -> Int,
        legacyDatabaseURL: @escaping () -> URL? = LegacyLaunchpadReader.defaultDatabaseURL,
        missingGracePeriod: TimeInterval = AppCatalog.defaultMissingGracePeriod,
        displayedStoreURL: URL? = nil
    ) {
        self.store = store
        self.scanner = scanner
        self.capacity = capacity
        self.legacyDatabaseURL = legacyDatabaseURL
        self.missingGracePeriod = missingGracePeriod
        self.storeURL = displayedStoreURL ?? store.fileURL
    }

    /// 设置页里给用户看的排列文件位置(演示模式显示真实默认位置,而不是临时目录)
    let storeURL: URL

    /// 按路径排序的已安装 App(同 bundle id 多份时分配顺序稳定)
    private var installedApps: [AppEntry] { apps.values.sorted { $0.url.path < $1.url.path } }
    var hasLegacyDatabase: Bool { legacyDatabaseURL() != nil }

    /// 读取上次的排列和已知 App(扫描前就能显示);文件坏了就备份后从头来,不让一个坏文件拦住启动。
    func loadSaved() {
        do {
            if let saved = try store.load() {
                layout = saved.layout
                apps = Dictionary(saved.apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                searchIndex = SearchIndex(apps: saved.apps, order: layout.allAppIDs)
                isFirstRun = false
            }
        } catch {
            Log.layout.error("排列文件读取失败,已备份并重建: \(String(describing: error), privacy: .public)")
            let backup = store.fileURL.appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: store.fileURL, to: backup)
        }
    }

    /// 重新扫描已安装 App 并对账。
    func refresh(force: Bool = false) async {
        guard !isScanning, force || Date().timeIntervalSince(lastScan) > Self.minimumRescanInterval else { return }
        isScanning = true
        defer { isScanning = false }
        let scanner = scanner
        let previous = Array(apps.values)
        let scanned = await Task.detached(priority: .userInitiated) { scanner.scan(previous: previous) }.value
        lastScan = Date()
        let present = scanned + recentlyMissing(comparedTo: scanned, now: lastScan)
        let presentApps = Dictionary(present.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let appsChanged = presentApps != apps
        if appsChanged {
            apps = presentApps
            searchIndex = SearchIndex(apps: present, order: layout.allAppIDs)
        }

        let wasFirstRun = isFirstRun
        isFirstRun = false
        if wasFirstRun, let imported = await legacyLayoutIfAvailable() {
            Log.layout.info("首次运行,已导入旧启动台排列")
            commit(imported)
            return
        }
        let reconciled = LayoutEngine.reconciled(layout, with: present, capacity: capacity(), utilitiesFolderID: UUID().uuidString)
        // App 信息变了(挪了位置、升级了)也要落盘,下次启动的快照才准
        if wasFirstRun || appsChanged || reconciled != layout { commit(reconciled) }
    }

    /// 这次没扫到、但消失还不到宽限期的 App:先留着(位置不动,点开失败会提示),回来了就当没走过
    private func recentlyMissing(comparedTo scanned: [AppEntry], now: Date) -> [AppEntry] {
        let scannedIDs = Set(scanned.map(\.id))
        let missing = apps.values.filter { !scannedIDs.contains($0.id) }
        missingSince = Dictionary(uniqueKeysWithValues: missing.map { ($0.id, missingSince[$0.id] ?? now) })
        return missing.filter { now.timeIntervalSince(missingSince[$0.id] ?? now) < missingGracePeriod }
    }

    /// 与当前 App 列表对账、规整后保存;保存失败只记日志,内存里的排列照常生效。
    /// 对账让「拖拽期间刚好装/卸了 App」这类基于旧快照的提交也不会丢新 App 或留下空格。
    func commit(_ newLayout: LaunchLayout) {
        let known = Array(apps.values)
        let checked = known.isEmpty
            ? newLayout
            : LayoutEngine.reconciled(newLayout, with: known, capacity: capacity(), utilitiesFolderID: UUID().uuidString)
        layout = LayoutEngine.normalized(checked, capacity: capacity())
        searchIndex = searchIndex.reordered(by: layout.allAppIDs)
        do {
            try store.save(.init(layout: layout, apps: known))
        } catch {
            Log.layout.error("排列保存失败: \(String(describing: error), privacy: .public)")
        }
    }

    /// 网格行列改了以后重排:满页的往后挤
    func reflow() {
        commit(layout)
    }

    enum ImportOutcome {
        case imported(apps: Int)
        case notFound
        case failed(String)
    }

    /// 手动从旧启动台导入,覆盖当前排列。
    func importLegacyLayout() async -> ImportOutcome {
        guard let url = legacyDatabaseURL() else { return .notFound }
        do {
            let legacy = try await Self.readLegacy(at: url)
            commit(mapped(legacy, onto: installedApps))
            let installedBundleIDs = Set(apps.values.compactMap(\.bundleID))
            return .imported(apps: Set(legacy.bundleIDs).intersection(installedBundleIDs).count)
        } catch {
            return .failed(String(describing: error))
        }
    }

    func resetToDefault() {
        commit(LayoutEngine.defaultLayout(for: installedApps, capacity: capacity(), utilitiesFolderID: UUID().uuidString))
    }

    private func legacyLayoutIfAvailable() async -> LaunchLayout? {
        guard let url = legacyDatabaseURL() else { return nil }
        do {
            let legacy = try await Self.readLegacy(at: url)
            return legacy.appCount > 0 ? mapped(legacy, onto: installedApps) : nil
        } catch {
            Log.layout.error("旧启动台排列读取失败: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func mapped(_ legacy: LegacyLayout, onto installed: [AppEntry]) -> LaunchLayout {
        LegacyLayoutMapper.layout(from: legacy, apps: installed, capacity: capacity()) { UUID().uuidString }
    }

    private static func readLegacy(at url: URL) async throws -> LegacyLayout {
        try await Task.detached(priority: .userInitiated) { try LegacyLaunchpadReader.read(databaseAt: url) }.value
    }
}
