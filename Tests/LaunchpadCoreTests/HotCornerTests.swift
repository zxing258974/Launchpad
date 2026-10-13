import CoreGraphics
import Testing
@testable import LaunchpadCore

@Suite("HotCornerGeometry")
struct HotCornerGeometryTests {
    let main = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test("单屏四个角", arguments: [
        (CGPoint(x: 0, y: 900), ScreenCorner.topLeft),
        (CGPoint(x: 1439, y: 899), ScreenCorner.topRight),
        (CGPoint(x: 1, y: 1), ScreenCorner.bottomLeft),
        (CGPoint(x: 1440, y: 0), ScreenCorner.bottomRight),
    ])
    func singleScreenCorners(point: CGPoint, expected: ScreenCorner) {
        #expect(HotCornerGeometry.corner(at: point, screens: [main])?.corner == expected)
    }

    @Test("离角稍远或只贴一条边不算")
    func notACorner() {
        #expect(HotCornerGeometry.corner(at: CGPoint(x: 10, y: 0), screens: [main]) == nil)
        #expect(HotCornerGeometry.corner(at: CGPoint(x: 0, y: 450), screens: [main]) == nil)
        #expect(HotCornerGeometry.corner(at: CGPoint(x: 5000, y: 0), screens: [main]) == nil)
    }

    @Test("两屏左右拼接:相邻的角光标会滑过去,不算热角")
    func sharedEdgeCornersAreIgnored() {
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let screens = [main, right]
        #expect(HotCornerGeometry.corner(at: CGPoint(x: 1439, y: 0), screens: screens) == nil)
        #expect(HotCornerGeometry.corner(at: CGPoint(x: 1440, y: 0), screens: screens) == nil)
        // 外侧的角照常
        #expect(HotCornerGeometry.corner(at: CGPoint(x: 0, y: 0), screens: screens)?.corner == .bottomLeft)
        let farRight = HotCornerGeometry.corner(at: CGPoint(x: 3359, y: 1079), screens: screens)
        #expect(farRight?.corner == .topRight)
        #expect(farRight?.screen == 1)
        // 右屏更高:主屏右上角往右仍能滑进右屏,也不算
        #expect(HotCornerGeometry.corner(at: CGPoint(x: 1439, y: 899), screens: screens) == nil)
    }

    @Test("角的标题")
    func titles() {
        #expect(ScreenCorner.allCases.map(\.title) == ["左上角", "右上角", "左下角", "右下角"])
    }
}

@Suite("HotCornerTracker")
struct HotCornerTrackerTests {
    @Test("无延迟:进角立即触发,停在角里不重复")
    func immediateFire() {
        var tracker = HotCornerTracker(delay: 0)
        #expect(tracker.update(corner: .bottomLeft, now: 0) == .fire(.bottomLeft))
        #expect(tracker.update(corner: .bottomLeft, now: 1) == .none)
        #expect(tracker.update(corner: nil, now: 2) == .none)
        #expect(tracker.update(corner: .bottomLeft, now: 3) == .fire(.bottomLeft))
    }

    @Test("有延迟:停够时间才触发,中途离开就作废")
    func dwellBeforeFiring() {
        var tracker = HotCornerTracker(delay: 0.3)
        #expect(tracker.update(corner: .topRight, now: 10) == .recheck(after: 0.3))
        if case .recheck(let after) = tracker.update(corner: .topRight, now: 10.1) {
            #expect(abs(after - 0.2) < 0.0001)
        } else {
            Issue.record("应当要求稍后复查")
        }
        #expect(tracker.update(corner: .topRight, now: 10.3) == .fire(.topRight))

        var interrupted = HotCornerTracker(delay: 0.3)
        _ = interrupted.update(corner: .topRight, now: 0)
        _ = interrupted.update(corner: nil, now: 0.1)
        #expect(interrupted.update(corner: .topRight, now: 0.35) == .recheck(after: 0.3))
    }

    @Test("从一个角直接换到另一个角重新计时")
    func switchingCornersRestarts() {
        var tracker = HotCornerTracker(delay: 0.2)
        _ = tracker.update(corner: .topLeft, now: 0)
        #expect(tracker.update(corner: .bottomLeft, now: 0.5) == .recheck(after: 0.2))
    }

    @Test("负延迟按 0 处理")
    func negativeDelayClamps() {
        #expect(HotCornerTracker(delay: -1).delay == 0)
    }
}
