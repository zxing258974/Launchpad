import CoreGraphics
import Foundation

/// 规则网格的公共几何:格子中心、图标中心、点落在哪一格、可点区域。
/// 坐标系与 SwiftUI 一致:左上为原点。主网格与文件夹面板共用,渲染和点击命中同源。
public protocol CellGrid {
    var columns: Int { get }
    var rows: Int { get }
    var gridRect: CGRect { get }
    var cellSize: CGSize { get }
    var iconSize: CGFloat { get }
}

public extension CellGrid {
    var capacity: Int { columns * rows }

    func cellCenter(at index: Int) -> CGPoint {
        let column = index % columns
        let row = index / columns
        return CGPoint(
            x: gridRect.minX + (CGFloat(column) + 0.5) * cellSize.width,
            y: gridRect.minY + (CGFloat(row) + 0.5) * cellSize.height
        )
    }

    /// 图标 + 标签整体在格子里垂直居中
    func iconCenter(at index: Int) -> CGPoint {
        let cell = cellCenter(at: index)
        return CGPoint(x: cell.x, y: cell.y - (iconSize + GridMetrics.labelHeight) / 2 + iconSize / 2)
    }

    /// 点落在哪一格(含格子空白处);网格外为 nil
    func index(at point: CGPoint) -> Int? {
        guard gridRect.contains(point) else { return nil }
        let column = min(Int((point.x - gridRect.minX) / cellSize.width), columns - 1)
        let row = min(Int((point.y - gridRect.minY) / cellSize.height), rows - 1)
        return row * columns + column
    }

    /// 标签宽度:标签、可点区域、选中框共用,三者对齐。不超过格宽,也不比图标宽太多(名字长就省略中间)
    var labelWidth: CGFloat {
        min(cellSize.width * GridMetrics.labelCellRatio, iconSize * GridMetrics.labelIconRatio)
    }

    /// 图标 + 标签的可点区域;点在格子空白处等于点背景
    func itemRect(at index: Int) -> CGRect {
        let icon = iconCenter(at: index)
        let width = max(iconSize + GridMetrics.iconHitMargin * 2, labelWidth)
        let top = icon.y - iconSize / 2 - GridMetrics.iconHitMargin / 2
        return CGRect(x: icon.x - width / 2, y: top, width: width, height: icon.y + iconSize / 2 + GridMetrics.labelHeight - top)
    }

    /// 点中了哪个图标(必须落在可点区域内)
    func itemIndex(at point: CGPoint) -> Int? {
        index(at: point).flatMap { itemRect(at: $0).contains(point) ? $0 : nil }
    }
}

public extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}

/// 主网格的几何
public struct GridMetrics: CellGrid, Equatable, Sendable {
    /// 图标下方标签区(含与图标的间距)高度
    public static let labelHeight: CGFloat = 30
    /// 图标与标签的间距
    public static let labelSpacing: CGFloat = 6
    public static let searchFieldSize = CGSize(width: 240, height: 30)
    /// macOS 图标在 1024 画布里主体占 824,圆角为主体的 22.5%;文件夹底板按同样比例画,与旁边的 App 一样大
    public static let iconBodyRatio: CGFloat = 824.0 / 1024.0
    public static let iconCornerRatio: CGFloat = 0.225
    public static let dotDiameter: CGFloat = 8
    public static let dotSpacing: CGFloat = 18
    static let labelCellRatio: CGFloat = 0.94
    static let labelIconRatio: CGFloat = 1.7
    /// 图标四周额外算作可点的边距
    static let iconHitMargin: CGFloat = 8

    public let containerSize: CGSize
    public let columns: Int
    public let rows: Int
    public let gridRect: CGRect
    public let cellSize: CGSize
    public let iconSize: CGFloat
    public let searchFieldRect: CGRect
    public let dotsY: CGFloat

    public init(containerSize: CGSize, columns: Int, rows: Int, iconScale: CGFloat = 1) {
        let columnCount = max(columns, 1)
        let rowCount = max(rows, 1)
        let width = containerSize.width
        let height = containerSize.height
        let top = max(height * 0.12, 96)
        let bottom = max(height * 0.11, 80)
        let side = max(width * 0.09, 40)
        let grid = CGRect(x: side, y: top, width: max(width - side * 2, 1), height: max(height - top - bottom, 1))
        let cell = CGSize(width: grid.width / CGFloat(columnCount), height: grid.height / CGFloat(rowCount))
        let fitted = min(cell.width * 0.5, (cell.height - Self.labelHeight) * 0.85) * max(iconScale, 0.3)
        // 再大也要给上下两行留出行距,否则标签分不清属于哪个图标
        let rowGap = max(cell.height * 0.12, 14)
        let maxIcon = min(cell.width * 0.9, cell.height - Self.labelHeight - rowGap)

        self.containerSize = containerSize
        self.columns = columnCount
        self.rows = rowCount
        self.gridRect = grid
        self.cellSize = cell
        self.iconSize = max(min(fitted, maxIcon), 24)
        self.searchFieldRect = CGRect(
            x: (width - Self.searchFieldSize.width) / 2,
            y: max(top * 0.36, 28),
            width: Self.searchFieldSize.width,
            height: Self.searchFieldSize.height
        )
        self.dotsY = height - bottom / 2
    }

    /// 光标是否压在某个图标中心附近(拖到这里松手会合成文件夹)
    public func isOverIconCenter(_ point: CGPoint, index: Int) -> Bool {
        point.distance(to: iconCenter(at: index)) <= iconSize * 0.32
    }

    public func dotRects(pageCount: Int) -> [CGRect] {
        PageDotGeometry.rects(count: pageCount, centerX: containerSize.width / 2, y: dotsY, spacing: Self.dotSpacing)
    }
}

/// 打开的文件夹面板几何。图标大小与主网格一致,最多 `maxRows` 行,放不下就分页。
public struct FolderMetrics: CellGrid, Equatable, Sendable {
    static let titleHeight: CGFloat = 70
    static let padding: CGFloat = 28

    public let columns: Int
    public let rows: Int
    public let pageCount: Int
    public let cellSize: CGSize
    public let iconSize: CGFloat
    public let panelRect: CGRect
    public let titleRect: CGRect
    public let gridRect: CGRect
    public let dotsY: CGFloat

    public init(grid: GridMetrics, appCount: Int, maxRows: Int = 3) {
        let count = max(appCount, 1)
        let columnCount = min(grid.columns, max(count, 3))
        let rowCount = min(max(maxRows, 1), Int((Double(count) / Double(columnCount)).rounded(.up)))
        let capacity = columnCount * rowCount
        let pageCount = Int((Double(count) / Double(capacity)).rounded(.up))
        let gridSize = CGSize(width: CGFloat(columnCount) * grid.cellSize.width, height: CGFloat(rowCount) * grid.cellSize.height)
        let bottom = Self.padding + (pageCount > 1 ? 24 : 0)
        let panelSize = CGSize(width: gridSize.width + Self.padding * 2, height: Self.titleHeight + gridSize.height + bottom)
        let panel = CGRect(
            x: (grid.containerSize.width - panelSize.width) / 2,
            y: (grid.containerSize.height - panelSize.height) / 2,
            width: panelSize.width,
            height: panelSize.height
        )

        self.columns = columnCount
        self.rows = rowCount
        self.pageCount = pageCount
        self.cellSize = grid.cellSize
        self.iconSize = grid.iconSize
        self.panelRect = panel
        self.titleRect = CGRect(x: panel.minX + Self.padding, y: panel.minY + 18, width: panel.width - Self.padding * 2, height: 36)
        self.gridRect = CGRect(origin: CGPoint(x: panel.minX + Self.padding, y: panel.minY + Self.titleHeight), size: gridSize)
        self.dotsY = panel.maxY - 22
    }

    /// 文件夹内第 `page` 页的第 `local` 格对应的整体下标
    public func folderIndex(page: Int, local: Int) -> Int {
        page * capacity + local
    }

    public func dotRects() -> [CGRect] {
        PageDotGeometry.rects(count: pageCount, centerX: panelRect.midX, y: dotsY, spacing: GridMetrics.dotSpacing)
    }
}

enum PageDotGeometry {
    static func rects(count: Int, centerX: CGFloat, y: CGFloat, spacing: CGFloat) -> [CGRect] {
        guard count > 1 else { return [] }
        let start = centerX - CGFloat(count) * spacing / 2
        return (0..<count).map {
            CGRect(x: start + CGFloat($0) * spacing, y: y - spacing / 2, width: spacing, height: spacing)
        }
    }
}
