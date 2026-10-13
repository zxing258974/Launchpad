import Foundation

/// 排列与已知 App 落盘:一个 JSON 文件,原子写入。
public struct LayoutStore: Sendable {
    public struct Snapshot: Equatable, Sendable {
        public let layout: LaunchLayout
        public let apps: [AppEntry]

        public init(layout: LaunchLayout, apps: [AppEntry]) {
            self.layout = layout
            self.apps = apps
        }
    }

    public enum StoreError: Error, Equatable {
        case unreadable(String)
        case unwritable(String)
        case unsupportedVersion(Int)
    }

    struct Envelope: Codable {
        let version: Int
        let pages: [[LaunchItem]]
        /// 早期文件没有这一项
        let apps: [AppEntry]?
    }

    public static let currentVersion = 1

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Launchpad", isDirectory: true).appendingPathComponent("layout.json")
    }

    /// 文件不存在返回 nil(首次运行);存在但坏了抛错,由调用方决定是否重建。
    public func load() throws(StoreError) -> Snapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fileURL))
        } catch {
            throw .unreadable(error.localizedDescription)
        }
        guard envelope.version <= Self.currentVersion else { throw .unsupportedVersion(envelope.version) }
        return Snapshot(layout: LaunchLayout(pages: envelope.pages), apps: envelope.apps ?? [])
    }

    public func save(_ snapshot: Snapshot) throws(StoreError) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let apps = snapshot.apps.sorted { $0.id < $1.id }
            let data = try encoder.encode(Envelope(version: Self.currentVersion, pages: snapshot.layout.pages, apps: apps))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw .unwritable(error.localizedDescription)
        }
    }
}
