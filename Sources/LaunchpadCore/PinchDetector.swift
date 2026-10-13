import Foundation

/// 触控板上的一个触点。坐标为归一化值(0…1),原点在触控板左下。
public struct TouchPoint: Equatable, Sendable {
    public let id: Int
    public let x: Double
    public let y: Double

    public init(id: Int, x: Double, y: Double) {
        self.id = id
        self.x = x
        self.y = y
    }
}

/// 旧启动台的手势:拇指和三根手指合拢 = 打开,张开 = 收起。
///
/// 做法:四(或五)根手指落下时记下它们离重心的平均距离和重心位置作为基准,之后距离缩到基准的 60% 以下算「捏合」,
/// 涨到 160% 以上算「张开」。重心位移必须明显小于张合幅度,所以四指整体扫动(调度中心、切换空间)、
/// 一根手指不动其余手指平行拖过去这类动作都不算。一次手势只报一次:中途换了手指会重新取基准,
/// 但要等手指离开(少于四指)才能再报。
public struct PinchDetector: Sendable {
    public enum Gesture: Equatable, Sendable {
        case pinchIn
        case pinchOut
    }

    /// 触控板宽高比:归一化坐标横竖不等长,换算回真实比例再量距离
    public static let defaultAspect = 1.6
    static let fingerRange = 4...5
    static let pinchInRatio = 0.6
    static let pinchOutRatio = 1.6
    /// 至少要合拢/张开这么多(归一化单位),防止起手很紧时的抖动被放大成手势
    static let minimumTravel = 0.06
    /// 重心位移不得超过张合幅度的这个倍数。真实捏合时拇指少动、三指多动,重心约移 1.2 倍;
    /// 拇指完全不动、三指平行拖过去则稳定在 2 倍左右
    static let maximumDriftRatio = 1.5

    private var baseline: (ids: Set<Int>, spread: Double, centerX: Double, centerY: Double)?
    private var hasFired = false
    private let aspect: Double

    public init(aspect: Double = PinchDetector.defaultAspect) {
        self.aspect = aspect
    }

    public mutating func update(touches: [TouchPoint]) -> Gesture? {
        guard Self.fingerRange.contains(touches.count) else {
            baseline = nil
            hasFired = false
            return nil
        }
        let ids = Set(touches.map(\.id))
        let spread = spread(of: touches)
        let (centerX, centerY) = center(of: touches)
        guard let base = baseline, base.ids == ids else {
            baseline = (ids, spread, centerX, centerY)
            return nil
        }
        let travel = abs(spread - base.spread)
        let drift = hypot((centerX - base.centerX) * aspect, centerY - base.centerY)
        guard !hasFired, travel >= Self.minimumTravel, drift < travel * Self.maximumDriftRatio else { return nil }
        if spread <= base.spread * Self.pinchInRatio {
            hasFired = true
            return .pinchIn
        }
        if spread >= base.spread * Self.pinchOutRatio {
            hasFired = true
            return .pinchOut
        }
        return nil
    }

    func center(of touches: [TouchPoint]) -> (x: Double, y: Double) {
        let count = Double(touches.count)
        return (touches.reduce(0) { $0 + $1.x } / count, touches.reduce(0) { $0 + $1.y } / count)
    }

    /// 各触点到重心的平均距离(横向按宽高比还原)
    func spread(of touches: [TouchPoint]) -> Double {
        let (centerX, centerY) = center(of: touches)
        return touches.reduce(0) { total, touch in
            total + hypot((touch.x - centerX) * aspect, touch.y - centerY)
        } / Double(touches.count)
    }
}
