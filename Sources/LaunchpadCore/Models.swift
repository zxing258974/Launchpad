import Foundation

/// 一个已安装的 App(扫描结果)。`id` 是布局里引用它的稳定键:优先 bundle id,重名时退回路径。
/// 随排列一起落盘,重启后扫描前就能画出网格,也让「短暂消失」的宽限期跨重启生效。
public struct AppEntry: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let bundleName: String?
    public let bundleID: String?
    public let url: URL
    public let category: String?
    public let isSystem: Bool
    public let isUtility: Bool
    /// 版本号(短版本 + 构建号);App 更新后变化,图标缓存据此刷新
    public let version: String?

    public init(
        id: String,
        name: String,
        bundleName: String? = nil,
        bundleID: String? = nil,
        url: URL,
        category: String? = nil,
        isSystem: Bool = false,
        isUtility: Bool = false,
        version: String? = nil
    ) {
        self.id = id
        self.name = name
        self.bundleName = bundleName
        self.bundleID = bundleID
        self.url = url
        self.category = category
        self.isSystem = isSystem
        self.isUtility = isUtility
        self.version = version
    }
}

/// 启动台里的文件夹。只装 App,不嵌套。
public struct Folder: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let appIDs: [String]

    public init(id: String, name: String, appIDs: [String]) {
        self.id = id
        self.name = name
        self.appIDs = appIDs
    }

    public func renamed(_ newName: String) -> Folder {
        Folder(id: id, name: newName, appIDs: appIDs)
    }

    public func with(appIDs newIDs: [String]) -> Folder {
        Folder(id: id, name: name, appIDs: newIDs)
    }
}

/// 页面上的一格:一个 App 或一个文件夹。
public enum LaunchItem: Hashable, Sendable, Identifiable {
    case app(String)
    case folder(Folder)

    public var id: String {
        switch self {
        case .app(let appID): "app:\(appID)"
        case .folder(let folder): "folder:\(folder.id)"
        }
    }

    /// 这一格包含的全部 App id(文件夹展开)
    public var appIDs: [String] {
        switch self {
        case .app(let appID): [appID]
        case .folder(let folder): folder.appIDs
        }
    }

    public var folder: Folder? {
        if case .folder(let folder) = self { folder } else { nil }
    }

    public var appID: String? {
        if case .app(let appID) = self { appID } else { nil }
    }
}

extension LaunchItem: Codable {
    private enum CodingKeys: String, CodingKey { case app, folder }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let appID = try container.decodeIfPresent(String.self, forKey: .app) {
            self = .app(appID)
        } else if let folder = try container.decodeIfPresent(Folder.self, forKey: .folder) {
            self = .folder(folder)
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "既不是 app 也不是 folder")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .app(let appID): try container.encode(appID, forKey: .app)
        case .folder(let folder): try container.encode(folder, forKey: .folder)
        }
    }
}

/// 页内位置
public struct ItemLocation: Hashable, Sendable {
    public let page: Int
    public let index: Int

    public init(page: Int, index: Int) {
        self.page = page
        self.index = index
    }
}

/// 整个启动台的排列:若干页,每页若干格。
public struct LaunchLayout: Codable, Hashable, Sendable {
    public let pages: [[LaunchItem]]

    public init(pages: [[LaunchItem]]) {
        self.pages = pages
    }

    public static let empty = LaunchLayout(pages: [])

    public var isEmpty: Bool { pages.allSatisfy(\.isEmpty) }

    /// 按显示顺序展开的全部 App id
    public var allAppIDs: [String] { pages.flatMap { $0.flatMap(\.appIDs) } }

    /// 越界返回空页
    public func page(at index: Int) -> [LaunchItem] {
        pages.indices.contains(index) ? pages[index] : []
    }

    public func location(ofItem itemID: String) -> ItemLocation? {
        for (pageIndex, page) in pages.enumerated() {
            if let index = page.firstIndex(where: { $0.id == itemID }) {
                return ItemLocation(page: pageIndex, index: index)
            }
        }
        return nil
    }

    public func item(at location: ItemLocation) -> LaunchItem? {
        let page = page(at: location.page)
        return page.indices.contains(location.index) ? page[location.index] : nil
    }

    public func item(withID itemID: String) -> LaunchItem? {
        location(ofItem: itemID).flatMap(item(at:))
    }

    /// 这个 App(单独或在文件夹里)在第几页
    public func page(containingApp appID: String) -> Int? {
        pages.firstIndex { $0.contains { $0.appIDs.contains(appID) } }
    }

    public func folder(withID folderID: String) -> Folder? {
        pages.lazy.flatMap { $0 }.compactMap(\.folder).first { $0.id == folderID }
    }
}

extension Sequence where Element: Hashable {
    /// 去重并保持原顺序
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
