import CoreGraphics
import Foundation

/// 翻页手势的落点判定
public enum Paging {
    /// 拖动超过页宽的这个比例就翻页
    static let distanceThreshold: CGFloat = 0.18
    /// 或者甩得够快(点/秒)
    static let velocityThreshold: CGFloat = 500
    /// 首尾页继续拖时的阻尼
    static let edgeResistance: CGFloat = 0.3

    /// - Parameters:
    ///   - offset: 内容的水平位移,负数表示往左拖(去下一页)
    ///   - velocity: 松手时的速度,符号同 offset
    public static func targetPage(current: Int, offset: CGFloat, width: CGFloat, velocity: CGFloat, pageCount: Int) -> Int {
        guard pageCount > 0, width > 0 else { return 0 }
        let farEnough = abs(offset) > width * distanceThreshold
        let fastEnough = abs(velocity) > velocityThreshold && velocity.sign == offset.sign && offset != 0
        guard farEnough || fastEnough else { return clamp(current, pageCount) }
        return clamp(offset < 0 ? current + 1 : current - 1, pageCount)
    }

    /// 首页往右、末页往左拖时给阻尼,模拟橡皮筋
    public static func resisted(offset: CGFloat, current: Int, pageCount: Int) -> CGFloat {
        let atStart = current <= 0 && offset > 0
        let atEnd = current >= pageCount - 1 && offset < 0
        return atStart || atEnd ? offset * edgeResistance : offset
    }

    public static func clamp(_ page: Int, _ pageCount: Int) -> Int {
        min(max(page, 0), max(pageCount - 1, 0))
    }
}

/// 方向键在网格里移动选中项,左右可跨页
public enum GridNavigation {
    public enum Direction: Sendable { case up, down, left, right }

    public static func move(
        from location: ItemLocation,
        _ direction: Direction,
        pageSizes: [Int],
        columns: Int
    ) -> ItemLocation {
        guard pageSizes.indices.contains(location.page) else { return location }
        let size = pageSizes[location.page]
        let index = location.index
        switch direction {
        case .right:
            if index + 1 < size { return ItemLocation(page: location.page, index: index + 1) }
            if let next = pageSizes.indices.first(where: { $0 > location.page && pageSizes[$0] > 0 }) {
                return ItemLocation(page: next, index: 0)
            }
        case .left:
            if index > 0 { return ItemLocation(page: location.page, index: index - 1) }
            if let previous = pageSizes.indices.last(where: { $0 < location.page && pageSizes[$0] > 0 }) {
                return ItemLocation(page: previous, index: pageSizes[previous] - 1)
            }
        case .down:
            if index + columns < size { return ItemLocation(page: location.page, index: index + columns) }
        case .up:
            if index - columns >= 0 { return ItemLocation(page: location.page, index: index - columns) }
        }
        return location
    }
}
