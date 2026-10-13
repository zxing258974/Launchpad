import Foundation
import Testing
@testable import LaunchpadCore

/// 以 (cx, cy) 为中心、半径 r 摆四个(或 n 个)触点
private func fingers(_ r: Double, center: (Double, Double) = (0.5, 0.5), count: Int = 4, ids: [Int]? = nil) -> [TouchPoint] {
    let ids = ids ?? Array(1...count)
    return ids.enumerated().map { index, id in
        let angle = Double(index) / Double(ids.count) * 2 * .pi
        return TouchPoint(id: id, x: center.0 + r * cos(angle) / PinchDetector.defaultAspect, y: center.1 + r * sin(angle))
    }
}

@Suite("PinchDetector")
struct PinchDetectorTests {
    @Test("四指合拢触发一次「捏合」,同一手势内不重复")
    func pinchInFiresOnce() {
        var detector = PinchDetector()
        #expect(detector.update(touches: fingers(0.3)) == nil)
        #expect(detector.update(touches: fingers(0.22)) == nil)
        #expect(detector.update(touches: fingers(0.15)) == .pinchIn)
        #expect(detector.update(touches: fingers(0.1)) == nil)
    }

    @Test("四指张开触发「张开」")
    func pinchOutFires() {
        var detector = PinchDetector()
        _ = detector.update(touches: fingers(0.1))
        #expect(detector.update(touches: fingers(0.14)) == nil)
        #expect(detector.update(touches: fingers(0.2)) == .pinchOut)
    }

    @Test("抬起手指后可以再次触发")
    func liftResets() {
        var detector = PinchDetector()
        _ = detector.update(touches: fingers(0.3))
        #expect(detector.update(touches: fingers(0.15)) == .pinchIn)
        #expect(detector.update(touches: []) == nil)
        _ = detector.update(touches: fingers(0.3))
        #expect(detector.update(touches: fingers(0.15)) == .pinchIn)
    }

    @Test("三指、六指不算;五指也算")
    func fingerCount() {
        var three = PinchDetector()
        _ = three.update(touches: fingers(0.3, count: 3))
        #expect(three.update(touches: fingers(0.1, count: 3)) == nil)

        var six = PinchDetector()
        _ = six.update(touches: fingers(0.3, count: 6))
        #expect(six.update(touches: fingers(0.1, count: 6)) == nil)

        var five = PinchDetector()
        _ = five.update(touches: fingers(0.3, count: 5))
        #expect(five.update(touches: fingers(0.15, count: 5)) == .pinchIn)
    }

    @Test("四指整体平移(调度中心、切换桌面空间的手势)不触发")
    func translationIgnored() {
        var detector = PinchDetector()
        _ = detector.update(touches: fingers(0.25, center: (0.5, 0.3)))
        #expect(detector.update(touches: fingers(0.25, center: (0.5, 0.6))) == nil)
        #expect(detector.update(touches: fingers(0.24, center: (0.2, 0.7))) == nil)
    }

    @Test("中途换了一根手指就以新的四指重新起算")
    func changedFingersRebaseline() {
        var detector = PinchDetector()
        _ = detector.update(touches: fingers(0.3, ids: [1, 2, 3, 4]))
        #expect(detector.update(touches: fingers(0.15, ids: [1, 2, 3, 5])) == nil)
        #expect(detector.update(touches: fingers(0.08, ids: [1, 2, 3, 5])) == .pinchIn)
    }

    @Test("起手就并得很紧时,手指的细微抖动不算张开")
    func tinyBaselineNeedsRealMovement() {
        var detector = PinchDetector()
        _ = detector.update(touches: fingers(0.01))
        #expect(detector.update(touches: fingers(0.03)) == nil)
        #expect(detector.update(touches: fingers(0.14)) == .pinchOut)
    }

    @Test("捏合触发后又碰到一根手指、手放松一点:同一次手势不会再报「张开」")
    func extraFingerDoesNotRearm() {
        var detector = PinchDetector()
        _ = detector.update(touches: fingers(0.3, ids: [1, 2, 3, 4]))
        #expect(detector.update(touches: fingers(0.1, ids: [1, 2, 3, 4])) == .pinchIn)
        #expect(detector.update(touches: fingers(0.1, ids: [1, 2, 3, 4, 5])) == nil)
        #expect(detector.update(touches: fingers(0.17, ids: [1, 2, 3, 4, 5])) == nil)
    }

    @Test("拇指不动、三指往下拖(或掌根加双指滚动):不是捏合")
    func restingContactsWithDraggingFingersIgnored() {
        var detector = PinchDetector()
        let thumb = TouchPoint(id: 1, x: 0.5, y: 0.1)
        func three(_ y: Double) -> [TouchPoint] {
            [TouchPoint(id: 2, x: 0.48, y: y), TouchPoint(id: 3, x: 0.5, y: y + 0.02), TouchPoint(id: 4, x: 0.52, y: y)]
        }
        _ = detector.update(touches: [thumb] + three(0.9))
        for y in stride(from: 0.85, through: 0.15, by: -0.05) {
            #expect(detector.update(touches: [thumb] + three(y)) == nil)
        }
    }

    @Test("拇指基本不动、主要靠三指往下收的真实捏合照样识别")
    func asymmetricRealPinchFires() {
        var detector = PinchDetector()
        let start = [TouchPoint(id: 1, x: 0.35, y: 0.2), TouchPoint(id: 2, x: 0.45, y: 0.75),
                     TouchPoint(id: 3, x: 0.55, y: 0.8), TouchPoint(id: 4, x: 0.65, y: 0.75)]
        let end = [TouchPoint(id: 1, x: 0.4, y: 0.3), TouchPoint(id: 2, x: 0.47, y: 0.42),
                   TouchPoint(id: 3, x: 0.5, y: 0.45), TouchPoint(id: 4, x: 0.53, y: 0.42)]
        _ = detector.update(touches: start)
        #expect(detector.update(touches: end) == .pinchIn)
    }
}
