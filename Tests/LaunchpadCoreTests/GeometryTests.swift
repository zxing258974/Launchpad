import CoreGraphics
import Testing
@testable import LaunchpadCore

@Suite("GridMetrics")
struct GridMetricsTests {
    let metrics = GridMetrics(containerSize: CGSize(width: 1440, height: 900), columns: 7, rows: 5)

    @Test("每个格子中心反查得到同一个下标")
    func cellCenterRoundTrips() {
        for index in 0..<metrics.capacity {
            #expect(metrics.index(at: metrics.cellCenter(at: index)) == index)
        }
        #expect(metrics.capacity == 35)
    }

    @Test("网格外的点不命中")
    func outsideGridIsNil() {
        #expect(metrics.index(at: CGPoint(x: 5, y: 5)) == nil)
        #expect(metrics.index(at: CGPoint(x: 720, y: 899)) == nil)
    }

    @Test("图标大小随格子缩放,并受上下限约束")
    func iconSizeIsBounded() {
        #expect(metrics.iconSize > 60 && metrics.iconSize < 120)
        let tiny = GridMetrics(containerSize: CGSize(width: 300, height: 200), columns: 10, rows: 8)
        #expect(tiny.iconSize == 24)
        let bigger = GridMetrics(containerSize: CGSize(width: 1440, height: 900), columns: 7, rows: 5, iconScale: 1.2)
        #expect(bigger.iconSize > metrics.iconSize)
    }

    @Test("图标调到最大也保留行距")
    func keepsRowGapAtMaxScale() {
        let big = GridMetrics(containerSize: CGSize(width: 1440, height: 900), columns: 7, rows: 5, iconScale: 1.3)
        let gap = big.cellSize.height - big.iconSize - GridMetrics.labelHeight
        #expect(gap >= 14)
    }

    @Test("压在图标中心才算要合成文件夹")
    func iconCenterHitZone() {
        let center = metrics.iconCenter(at: 3)
        #expect(metrics.isOverIconCenter(center, index: 3))
        #expect(!metrics.isOverIconCenter(CGPoint(x: center.x + metrics.iconSize, y: center.y), index: 3))
    }

    @Test("可点区域覆盖图标和标签,不覆盖格子空白")
    func itemRectCoversIconAndLabel() {
        let rect = metrics.itemRect(at: 8)
        #expect(rect.contains(metrics.iconCenter(at: 8)))
        #expect(rect.contains(CGPoint(x: rect.midX, y: metrics.iconCenter(at: 8).y + metrics.iconSize / 2 + 15)))
        #expect(!rect.contains(CGPoint(x: metrics.cellCenter(at: 8).x + metrics.cellSize.width * 0.49, y: metrics.cellCenter(at: 8).y)))
        let folder = FolderMetrics(grid: metrics, appCount: 4)
        #expect(folder.itemRect(at: 1).contains(folder.iconCenter(at: 1)))
    }

    @Test("页码圆点:一页不画,多页水平居中")
    func dotRects() {
        #expect(metrics.dotRects(pageCount: 1).isEmpty)
        let dots = metrics.dotRects(pageCount: 3)
        #expect(dots.count == 3)
        #expect(abs((dots[0].minX + dots[2].maxX) / 2 - 720) < 0.001)
    }

    @Test("搜索框在顶部居中")
    func searchFieldIsCentered() {
        #expect(metrics.searchFieldRect.midX == 720)
        #expect(metrics.searchFieldRect.maxY < metrics.gridRect.minY)
    }
}

@Suite("FolderMetrics")
struct FolderMetricsTests {
    let grid = GridMetrics(containerSize: CGSize(width: 1440, height: 900), columns: 7, rows: 5)

    @Test("少量 App:至少 3 列、单行、单页")
    func smallFolder() {
        let folder = FolderMetrics(grid: grid, appCount: 2)
        #expect(folder.columns == 3)
        #expect(folder.rows == 1)
        #expect(folder.pageCount == 1)
        #expect(folder.dotRects().isEmpty)
        #expect(folder.panelRect.midX == 720)
    }

    @Test("超过三行就分页")
    func largeFolderPages() {
        let folder = FolderMetrics(grid: grid, appCount: 30)
        #expect(folder.columns == 7)
        #expect(folder.rows == 3)
        #expect(folder.capacity == 21)
        #expect(folder.pageCount == 2)
        #expect(folder.dotRects().count == 2)
        for index in 0..<folder.capacity {
            #expect(folder.index(at: folder.cellCenter(at: index)) == index)
        }
        #expect(folder.panelRect.contains(folder.iconCenter(at: 0)))
    }
}

@Suite("Paging")
struct PagingTests {
    @Test("拖够距离或甩够快才翻页", arguments: [
        (CGFloat(-300), CGFloat(0), 2),
        (CGFloat(-100), CGFloat(0), 1),
        (CGFloat(-100), CGFloat(-900), 2),
        (CGFloat(100), CGFloat(900), 0),
        (CGFloat(100), CGFloat(-900), 1),
        (CGFloat(400), CGFloat(0), 0),
    ])
    func target(offset: CGFloat, velocity: CGFloat, expected: Int) {
        #expect(Paging.targetPage(current: 1, offset: offset, width: 1000, velocity: velocity, pageCount: 3) == expected)
    }

    @Test("首末页不越界,无页时为 0")
    func clamps() {
        #expect(Paging.targetPage(current: 2, offset: -900, width: 1000, velocity: 0, pageCount: 3) == 2)
        #expect(Paging.targetPage(current: 0, offset: 900, width: 1000, velocity: 0, pageCount: 3) == 0)
        #expect(Paging.targetPage(current: 0, offset: 0, width: 1000, velocity: 0, pageCount: 0) == 0)
    }

    @Test("首末页继续拖有阻尼,中间页没有")
    func resistance() {
        #expect(Paging.resisted(offset: 100, current: 0, pageCount: 3) == 30)
        #expect(Paging.resisted(offset: -100, current: 2, pageCount: 3) == -30)
        #expect(Paging.resisted(offset: -100, current: 1, pageCount: 3) == -100)
    }
}

@Suite("GridNavigation")
struct GridNavigationTests {
    let sizes = [5, 0, 3]

    @Test("页内上下左右")
    func withinPage() {
        let start = ItemLocation(page: 0, index: 1)
        #expect(GridNavigation.move(from: start, .right, pageSizes: sizes, columns: 3) == ItemLocation(page: 0, index: 2))
        #expect(GridNavigation.move(from: start, .left, pageSizes: sizes, columns: 3) == ItemLocation(page: 0, index: 0))
        #expect(GridNavigation.move(from: start, .down, pageSizes: sizes, columns: 3) == ItemLocation(page: 0, index: 4))
        #expect(GridNavigation.move(from: start, .up, pageSizes: sizes, columns: 3) == start)
        #expect(GridNavigation.move(from: ItemLocation(page: 0, index: 3), .up, pageSizes: sizes, columns: 3) == ItemLocation(page: 0, index: 0))
        #expect(GridNavigation.move(from: ItemLocation(page: 0, index: 2), .down, pageSizes: sizes, columns: 3) == ItemLocation(page: 0, index: 2))
    }

    @Test("左右到页边跨页,跳过空页")
    func acrossPages() {
        #expect(GridNavigation.move(from: ItemLocation(page: 0, index: 4), .right, pageSizes: sizes, columns: 3) == ItemLocation(page: 2, index: 0))
        #expect(GridNavigation.move(from: ItemLocation(page: 2, index: 0), .left, pageSizes: sizes, columns: 3) == ItemLocation(page: 0, index: 4))
        #expect(GridNavigation.move(from: ItemLocation(page: 2, index: 2), .right, pageSizes: sizes, columns: 3) == ItemLocation(page: 2, index: 2))
        #expect(GridNavigation.move(from: ItemLocation(page: 9, index: 0), .right, pageSizes: sizes, columns: 3) == ItemLocation(page: 9, index: 0))
    }
}

@Suite("FolderNaming")
struct FolderNamingTests {
    @Test("按分类起名,认不出就用默认名")
    func names() {
        #expect(FolderNaming.name(forCategories: [nil, "public.app-category.developer-tools"]) == "开发工具")
        #expect(FolderNaming.name(forCategories: ["public.app-category.puzzle-games"]) == "游戏")
        #expect(FolderNaming.name(forCategories: ["public.app-category.unknown", nil]) == "未命名文件夹")
        #expect(FolderNaming.name(forCategories: []) == "未命名文件夹")
    }
}
