import CoreGraphics
import Foundation

public enum ScreenCorner: String, CaseIterable, Codable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    public var title: String {
        switch self {
        case .topLeft: "左上角"
        case .topRight: "右上角"
        case .bottomLeft: "左下角"
        case .bottomRight: "右下角"
        }
    }
}

/// 热角几何。坐标系与 `NSEvent.mouseLocation` 一致:左下为原点、y 向上。
public enum HotCornerGeometry {
    /// 光标贴边时允许的误差(点)
    public static let defaultTolerance: CGFloat = 3

    /// 光标所在的「真角」:多屏拼接处的角光标会滑过去,不算。
    public static func corner(
        at point: CGPoint,
        screens: [CGRect],
        tolerance: CGFloat = defaultTolerance
    ) -> (corner: ScreenCorner, screen: Int)? {
        for (index, screen) in screens.enumerated() {
            guard screen.insetBy(dx: -1, dy: -1).contains(point) else { continue }
            let nearLeft = point.x - screen.minX <= tolerance
            let nearRight = screen.maxX - point.x <= tolerance + 1
            let nearBottom = point.y - screen.minY <= tolerance
            let nearTop = screen.maxY - point.y <= tolerance + 1
            let candidate: ScreenCorner? = switch (nearLeft, nearRight, nearTop, nearBottom) {
            case (true, _, true, _): .topLeft
            case (_, true, true, _): .topRight
            case (true, _, _, true): .bottomLeft
            case (_, true, _, true): .bottomRight
            default: nil
            }
            if let candidate, isBlocked(candidate, of: screen, among: screens) {
                return (candidate, index)
            }
        }
        return nil
    }

    /// 角的两条外侧都没有别的屏幕,光标才会被「卡」在这里。
    static func isBlocked(_ corner: ScreenCorner, of screen: CGRect, among screens: [CGRect]) -> Bool {
        let probe: CGFloat = 2
        let (x, y, dx, dy): (CGFloat, CGFloat, CGFloat, CGFloat) = switch corner {
        case .topLeft: (screen.minX, screen.maxY, -1, 1)
        case .topRight: (screen.maxX, screen.maxY, 1, 1)
        case .bottomLeft: (screen.minX, screen.minY, -1, -1)
        case .bottomRight: (screen.maxX, screen.minY, 1, -1)
        }
        // 水平外侧(稍往屏内收一点)与垂直外侧
        let horizontal = CGPoint(x: x + dx * probe, y: y - dy * probe)
        let vertical = CGPoint(x: x - dx * probe, y: y + dy * probe)
        let others = screens.filter { $0 != screen }
        return !others.contains { $0.contains(horizontal) || $0.contains(vertical) }
    }
}

/// 热角触发的状态机:进角 → 停留够久 → 触发一次;离开角之前不会再触发。
public struct HotCornerTracker: Sendable {
    public enum Effect: Equatable, Sendable {
        case none
        /// 让调用方在这么久之后用当前光标再调一次 `update`
        case recheck(after: TimeInterval)
        case fire(ScreenCorner)
    }

    enum Phase: Equatable, Sendable {
        case idle
        case dwelling(ScreenCorner, since: TimeInterval)
        case fired(ScreenCorner)
    }

    public let delay: TimeInterval
    private(set) var phase: Phase = .idle

    public init(delay: TimeInterval) {
        self.delay = max(delay, 0)
    }

    public mutating func update(corner: ScreenCorner?, now: TimeInterval) -> Effect {
        guard let corner else {
            phase = .idle
            return .none
        }
        switch phase {
        case .fired(let fired) where fired == corner:
            return .none
        case .dwelling(let dwelling, let since) where dwelling == corner:
            let elapsed = now - since
            if elapsed + 0.001 >= delay {
                phase = .fired(corner)
                return .fire(corner)
            }
            return .recheck(after: delay - elapsed)
        default:
            if delay == 0 {
                phase = .fired(corner)
                return .fire(corner)
            }
            phase = .dwelling(corner, since: now)
            return .recheck(after: delay)
        }
    }
}
