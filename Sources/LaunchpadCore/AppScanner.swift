import Foundation

/// 扫描磁盘上的 .app。和旧启动台一样看 /Applications、/System/Applications 和 ~/Applications,
/// 会进普通子目录(如 /Applications/Utilities、Adobe 的安装目录),不进 .app 包内部。
public struct AppScanner: Sendable {
    public static let maxDepth = 3

    public static var defaultRoots: [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
    }

    public let roots: [URL]
    public let excludedBundleIDs: Set<String>

    public init(roots: [URL] = AppScanner.defaultRoots, excludedBundleIDs: Set<String> = []) {
        self.roots = roots
        self.excludedBundleIDs = excludedBundleIDs
    }

    /// - Parameter previous: 上次扫描的结果。同 bundle id 装了多份时,每份沿用上次的键,排列位置不会被另一份顶掉。
    public func scan(previous: [AppEntry] = []) -> [AppEntry] {
        let bundles = roots.flatMap(Self.appBundles(under:)).uniqued()
        let infos = bundles.compactMap(Self.readInfo(at:)).filter { info in
            info.bundleID.map { !excludedBundleIDs.contains($0) } ?? true
        }
        return Self.assigningIDs(infos, previous: previous)
    }

    // MARK: 内部步骤

    struct BundleInfo {
        let url: URL
        let name: String
        let bundleName: String?
        let bundleID: String?
        let category: String?
        let version: String?
    }

    /// 根目录下(含子目录)的全部 .app,符号链接解析到真实路径(/Applications/Safari.app 就是链接)。
    static func appBundles(under root: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension.lowercased() == "app" {
                enumerator.skipDescendants()
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                if isDirectory(resolved) { result.append(resolved) }
            } else if enumerator.level >= maxDepth {
                enumerator.skipDescendants()
            }
        }
        return result
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func readInfo(at url: URL) -> BundleInfo? {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        let plist = (try? Data(contentsOf: plistURL))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        // iOS App(Apple 芯片上从 App Store 装的)没有 Contents/Info.plist,但仍能启动,保留
        let isWrappedIOSApp = FileManager.default.fileExists(atPath: url.appendingPathComponent("WrappedBundle").path)
        guard !plist.isEmpty || isWrappedIOSApp else { return nil }
        if (plist["CFBundlePackageType"] as? String).map({ $0 != "APPL" }) ?? false { return nil }

        return BundleInfo(
            url: url,
            name: displayName(of: url),
            bundleName: plist["CFBundleName"] as? String,
            bundleID: (plist["CFBundleIdentifier"] as? String) ?? Bundle(url: url)?.bundleIdentifier,
            category: plist["LSApplicationCategoryType"] as? String,
            version: [plist["CFBundleShortVersionString"], plist["CFBundleVersion"]]
                .compactMap { $0 as? String }.joined(separator: " ").nilIfEmpty
        )
    }

    /// Finder 里显示的本地化名称(「系统设置」而非 System Settings)
    static func displayName(of url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// bundle id 唯一的用 bundle id 作键(App 挪位置不丢排列),重复的退回用路径。
    /// 同一路径上次用过的键优先保留,其余按扫描顺序分配。
    static func assigningIDs(_ infos: [BundleInfo], previous: [AppEntry] = []) -> [AppEntry] {
        let previousIDs = Dictionary(previous.map { ($0.url.path, $0.id) }, uniquingKeysWith: { first, _ in first })
        var used = Set<String>()
        let sticky: [String: String] = infos.reduce(into: [:]) { result, info in
            guard let id = previousIDs[info.url.path], id == info.bundleID || id == info.url.path,
                  used.insert(id).inserted else { return }
            result[info.url.path] = id
        }
        return infos.map { info in
            let key = sticky[info.url.path]
                ?? info.bundleID.flatMap { used.insert($0).inserted ? $0 : nil }
                ?? info.url.path
            let path = info.url.path
            return AppEntry(
                id: key,
                name: info.name,
                bundleName: info.bundleName,
                bundleID: info.bundleID,
                url: info.url,
                category: info.category,
                isSystem: path.hasPrefix("/System/"),
                isUtility: path.contains("/Utilities/"),
                version: info.version
            )
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
