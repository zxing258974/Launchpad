import Foundation

/// 布局的纯函数操作。所有函数都返回新 `Layout`,不改动入参。
///
/// 行为对齐旧启动台:
/// - 各页互相独立,删掉一格不会从后一页往前补;
/// - 往满页插入时,本页末尾挤到下一页开头(必要时新开一页);
/// - 文件夹空了就消失,空页在提交时清掉。
public enum LayoutEngine {

    // MARK: 分页

    public static func paginate(_ items: [LaunchItem], capacity: Int) -> [[LaunchItem]] {
        let size = max(capacity, 1)
        return stride(from: 0, to: items.count, by: size).map {
            Array(items[$0..<min($0 + size, items.count)])
        }
    }

    /// 从 `start` 页开始,把超出容量的部分依次挤到后一页。
    static func cascadingOverflow(_ pages: [[LaunchItem]], from start: Int, capacity: Int) -> [[LaunchItem]] {
        let size = max(capacity, 1)
        var result = pages
        var pageIndex = max(start, 0)
        while pageIndex < result.count {
            if result[pageIndex].count > size {
                let overflow = Array(result[pageIndex][size...])
                result[pageIndex] = Array(result[pageIndex][..<size])
                if pageIndex + 1 < result.count {
                    result[pageIndex + 1] = overflow + result[pageIndex + 1]
                } else {
                    result.append(overflow)
                }
            }
            pageIndex += 1
        }
        return result
    }

    /// 提交前的规整:处理超容、去掉空页。
    public static func normalized(_ layout: LaunchLayout, capacity: Int) -> LaunchLayout {
        let cascaded = cascadingOverflow(layout.pages, from: 0, capacity: capacity)
        return LaunchLayout(pages: cascaded.filter { !$0.isEmpty })
    }

    // MARK: 增删挪

    /// 拿掉一个顶层格子;所在页即使空了也保留(拖拽过程中页码不能跳)。
    public static func removing(itemID: String, from layout: LaunchLayout) -> (layout: LaunchLayout, item: LaunchItem)? {
        guard let location = layout.location(ofItem: itemID),
              let item = layout.item(at: location) else { return nil }
        let pages = layout.pages.enumerated().map { pageIndex, page in
            pageIndex == location.page ? page.filter { $0.id != itemID } : page
        }
        return (LaunchLayout(pages: pages), item)
    }

    /// 在指定位置插入;页不存在就补空页,下标越界就放到页尾,满了往后挤。
    public static func inserting(_ item: LaunchItem, at location: ItemLocation, in layout: LaunchLayout, capacity: Int) -> LaunchLayout {
        let targetPage = max(location.page, 0)
        let padded = layout.pages + Array(repeating: [], count: max(0, targetPage + 1 - layout.pages.count))
        let page = padded[targetPage]
        let index = min(max(location.index, 0), page.count)
        let newPage = Array(page[..<index]) + [item] + Array(page[index...])
        let replaced = padded.enumerated().map { $0.offset == targetPage ? newPage : $0.element }
        return LaunchLayout(pages: cascadingOverflow(replaced, from: targetPage, capacity: capacity))
    }

    /// 把 App 放进目标格:目标是 App 就就地建文件夹,目标是文件夹就追加。
    /// 调用方须先把被拖的 App 从布局里拿掉。目标不存在或是 App 自身时返回 nil。
    public static func merging(
        appID: String,
        into targetItemID: String,
        in layout: LaunchLayout,
        newFolderID: String,
        folderName: String
    ) -> LaunchLayout? {
        guard let location = layout.location(ofItem: targetItemID),
              let target = layout.item(at: location) else { return nil }
        let merged: LaunchItem
        switch target {
        case .app(let targetAppID):
            guard targetAppID != appID else { return nil }
            merged = .folder(Folder(id: newFolderID, name: folderName, appIDs: [targetAppID, appID]))
        case .folder(let folder):
            guard !folder.appIDs.contains(appID) else { return nil }
            merged = .folder(folder.with(appIDs: folder.appIDs + [appID]))
        }
        return replacing(at: location, with: merged, in: layout)
    }

    /// 用新内容替换同 id 的文件夹;文件夹空了就删掉这一格。
    public static func replacingFolder(_ folder: Folder, in layout: LaunchLayout) -> LaunchLayout {
        let itemID = LaunchItem.folder(folder).id
        guard let location = layout.location(ofItem: itemID) else { return layout }
        if folder.appIDs.isEmpty {
            return removing(itemID: itemID, from: layout)?.layout ?? layout
        }
        return replacing(at: location, with: .folder(folder), in: layout)
    }

    /// 从文件夹里拿出一个 App(不放回网格,由调用方决定放哪)。
    public static func removingApp(_ appID: String, fromFolder folderID: String, in layout: LaunchLayout) -> LaunchLayout {
        guard let folder = layout.folder(withID: folderID) else { return layout }
        return replacingFolder(folder.with(appIDs: folder.appIDs.filter { $0 != appID }), in: layout)
    }

    private static func replacing(at location: ItemLocation, with item: LaunchItem, in layout: LaunchLayout) -> LaunchLayout {
        let pages = layout.pages.enumerated().map { pageIndex, page in
            pageIndex == location.page
                ? page.enumerated().map { $0.offset == location.index ? item : $0.element }
                : page
        }
        return LaunchLayout(pages: pages)
    }

    // MARK: 与已安装 App 对账

    /// 去掉已卸载的、重复的;新装的按名称排到最后。布局为空时给默认排列。
    public static func reconciled(
        _ layout: LaunchLayout,
        with apps: [AppEntry],
        capacity: Int,
        utilitiesFolderID: String
    ) -> LaunchLayout {
        guard !layout.isEmpty else {
            return defaultLayout(for: apps, capacity: capacity, utilitiesFolderID: utilitiesFolderID)
        }
        let known = Set(apps.map(\.id))
        var seen = Set<String>()
        let kept: [[LaunchItem]] = layout.pages.map { page in
            page.compactMap { item in
                switch item {
                case .app(let appID):
                    guard known.contains(appID), seen.insert(appID).inserted else { return nil }
                    return item
                case .folder(let folder):
                    let ids = folder.appIDs.filter { known.contains($0) && seen.insert($0).inserted }
                    return ids.isEmpty ? nil : .folder(folder.with(appIDs: ids))
                }
            }
        }
        let added = AppSorting.byName(apps.filter { !seen.contains($0.id) }).map { LaunchItem.app($0.id) }
        let withAdded = kept.isEmpty ? [added] : Array(kept.dropLast()) + [kept[kept.count - 1] + added]
        return normalized(LaunchLayout(pages: withAdded), capacity: capacity)
    }

    /// 默认排列:系统 App 在前,「其他」文件夹收纳实用工具,第三方 App 按名称排在后面。
    public static func defaultLayout(for apps: [AppEntry], capacity: Int, utilitiesFolderID: String) -> LaunchLayout {
        let system = AppSorting.byName(apps.filter { $0.isSystem && !$0.isUtility })
        let utilities = AppSorting.byName(apps.filter(\.isUtility))
        let others = AppSorting.byName(apps.filter { !$0.isSystem && !$0.isUtility })
        let utilityFolder: [LaunchItem] = utilities.isEmpty
            ? []
            : [.folder(Folder(id: utilitiesFolderID, name: FolderNaming.utilitiesName, appIDs: utilities.map(\.id)))]
        let items = system.map { LaunchItem.app($0.id) } + utilityFolder + others.map { LaunchItem.app($0.id) }
        return LaunchLayout(pages: paginate(items, capacity: capacity))
    }
}

/// App 名称排序:中文按拼音、数字按数值,不随系统语言漂移。
public enum AppSorting {
    private static let locale = Locale(identifier: "zh_Hans")

    public static func byName(_ apps: [AppEntry]) -> [AppEntry] {
        apps.sorted {
            let order = $0.name.compare($1.name, options: [.caseInsensitive, .numeric], locale: locale)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
