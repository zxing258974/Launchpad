import Foundation
import SQLite3

/// 旧启动台(macOS 15 及以前)留在 `$DARWIN_USER_DIR/com.apple.dock.launchpad/db/db` 的排列。
///
/// 表结构要点:items(rowid, type, parent_id, ordering),type 1=根 2=文件夹 3=页 4=App(根 id 记在 dbinfo.launchpad_root);
/// 根 → 页 → App/文件夹 → 文件夹内的页 → App。ordering 偶有重复,同序再按 rowid。
public struct LegacyApp: Hashable, Sendable {
    public let bundleID: String
    public let title: String

    public init(bundleID: String, title: String) {
        self.bundleID = bundleID
        self.title = title
    }
}

public enum LegacyItem: Hashable, Sendable {
    case app(LegacyApp)
    case folder(title: String, apps: [LegacyApp])
}

public struct LegacyLayout: Hashable, Sendable {
    public let pages: [[LegacyItem]]

    /// 旧排列里出现的全部 bundle id(含重复)
    public var bundleIDs: [String] {
        pages.joined().flatMap { item -> [String] in
            switch item {
            case .app(let app): [app.bundleID]
            case .folder(_, let apps): apps.map(\.bundleID)
            }
        }
    }

    public var appCount: Int { bundleIDs.count }
}

public enum LegacyLaunchpadReader {
    public enum ReadError: Error, Equatable {
        case notFound
        case openFailed(String)
        case queryFailed(String)
    }

    struct Row {
        let rowID: Int
        let type: Int
        let parentID: Int
        let ordering: Int
        let title: String?
        let bundleID: String?
    }

    enum ItemType {
        static let folder = 2
        static let page = 3
        static let app = 4
    }

    public static func defaultDatabaseURL() -> URL? {
        let length = confstr(_CS_DARWIN_USER_DIR, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_DIR, &buffer, length) > 0 else { return nil }
        let userDir = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let url = URL(fileURLWithPath: userDir).appendingPathComponent("com.apple.dock.launchpad/db/db")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public static func read(databaseAt url: URL) throws(ReadError) -> LegacyLayout {
        guard FileManager.default.fileExists(atPath: url.path) else { throw .notFound }
        let database = try open(url)
        defer { sqlite3_close(database) }
        let rootID = try query(database, "SELECT value FROM dbinfo WHERE key = 'launchpad_root'") {
            Int(sqlite3_column_int64($0, 0))
        }.first ?? 1
        let rows = try query(database, """
            SELECT i.rowid, i.type, i.parent_id, i.ordering, COALESCE(a.title, g.title), a.bundleid
            FROM items i
            LEFT JOIN apps a ON a.item_id = i.rowid
            LEFT JOIN groups g ON g.item_id = i.rowid
            """) { statement in
            Row(
                rowID: Int(sqlite3_column_int64(statement, 0)),
                type: Int(sqlite3_column_int64(statement, 1)),
                parentID: Int(sqlite3_column_int64(statement, 2)),
                ordering: Int(sqlite3_column_int64(statement, 3)),
                title: text(statement, 4),
                bundleID: text(statement, 5)
            )
        }
        return buildLayout(rows: rows, rootID: rootID)
    }

    /// 由扁平的行拼出树。纯函数,便于单测。
    static func buildLayout(rows: [Row], rootID: Int) -> LegacyLayout {
        let children = Dictionary(grouping: rows, by: \.parentID)
            .mapValues { $0.sorted { ($0.ordering, $0.rowID) < ($1.ordering, $1.rowID) } }
        func childRows(of id: Int, type: Int) -> [Row] {
            (children[id] ?? []).filter { $0.type == type }
        }
        func legacyApp(_ row: Row) -> LegacyApp? {
            guard let bundleID = row.bundleID, !bundleID.isEmpty else { return nil }
            return LegacyApp(bundleID: bundleID, title: row.title ?? bundleID)
        }
        let pages: [[LegacyItem]] = childRows(of: rootID, type: ItemType.page).map { page in
            (children[page.rowID] ?? []).compactMap { row -> LegacyItem? in
                switch row.type {
                case ItemType.app:
                    return legacyApp(row).map(LegacyItem.app)
                case ItemType.folder:
                    let apps = childRows(of: row.rowID, type: ItemType.page)
                        .flatMap { childRows(of: $0.rowID, type: ItemType.app) }
                        .compactMap(legacyApp)
                    return apps.isEmpty ? nil : .folder(title: row.title ?? FolderNaming.fallbackName, apps: apps)
                default:
                    return nil
                }
            }
        }
        return LegacyLayout(pages: pages.filter { !$0.isEmpty })
    }

    // MARK: SQLite

    private static func open(_ url: URL) throws(ReadError) -> OpaquePointer {
        // immutable=1:只读且不碰旁边的 -shm/-wal,不会惊动这份库
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "immutable", value: "1")]
        let uri = components?.url?.absoluteString ?? url.absoluteString
        var database: OpaquePointer?
        let status = sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard status == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "status \(status)"
            sqlite3_close(database)
            throw .openFailed(message)
        }
        return database
    }

    private static func query<T>(
        _ database: OpaquePointer,
        _ sql: String,
        map: (OpaquePointer) -> T
    ) throws(ReadError) -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw .queryFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw .queryFailed(String(cString: sqlite3_errmsg(database))) }
            result.append(map(statement))
        }
        return result
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}

/// 旧排列 → 新排列:按 bundle id 对上已安装的 App;没装的跳过,新装的排到最后。
public enum LegacyLayoutMapper {
    public static func layout(
        from legacy: LegacyLayout,
        apps: [AppEntry],
        capacity: Int,
        makeFolderID: () -> String
    ) -> LaunchLayout {
        // 同一 bundle id 可能装了多份(如三个「卸载 Adobe」),依次分配,不重复使用
        var pool = Dictionary(grouping: apps.filter { $0.bundleID != nil }, by: { $0.bundleID! })
        func take(_ legacyApp: LegacyApp) -> String? {
            guard var candidates = pool[legacyApp.bundleID], !candidates.isEmpty else { return nil }
            let picked = candidates.removeFirst()
            pool[legacyApp.bundleID] = candidates
            return picked.id
        }
        let pages: [[LaunchItem]] = legacy.pages.map { page in
            page.compactMap { item in
                switch item {
                case .app(let legacyApp):
                    return take(legacyApp).map(LaunchItem.app)
                case .folder(let title, let legacyApps):
                    let ids = legacyApps.compactMap(take)
                    return ids.isEmpty ? nil : .folder(Folder(id: makeFolderID(), name: title, appIDs: ids))
                }
            }
        }
        return LayoutEngine.reconciled(
            LaunchLayout(pages: pages.filter { !$0.isEmpty }),
            with: apps,
            capacity: capacity,
            utilitiesFolderID: makeFolderID()
        )
    }
}
