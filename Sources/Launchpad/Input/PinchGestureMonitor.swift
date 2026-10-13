import AppKit
import CMultitouch
import LaunchpadCore
import os

/// 四指捏合打开、张开收起(同旧启动台)。
///
/// 系统不把四指捏合交给第三方 App,这里经私有框架 MultitouchSupport 直接读触控板原始触点自己识别;
/// 框架在运行时加载,加载不到(系统改了接口)时功能自动不可用,其余照常。
/// 触点在框架自己的线程上回调,识别器状态由 `TouchRelay` 加锁保管,识别出的手势回主线程。
@MainActor
final class PinchGestureMonitor {
    var onGesture: ((PinchDetector.Gesture) -> Void)?

    /// 本机能否读到触控板(框架加载成功且至少有一块触控板)
    let isAvailable: Bool

    private var isEnabled = false
    /// 正在监听的设备列表;设备对象由这个数组持有,停止监听前不能释放
    private var devices: CFArray?
    private var deviceIDs = Set<UInt64>()
    private var observers: [NSObjectProtocol] = []
    private var deviceWatch: Task<Void, Never>?

    /// 每隔这么久核对一次设备,妙控板连上/断开/重连后重新挂接
    static let deviceCheckInterval: Duration = .seconds(30)
    /// 妙控鼠标:抓握时掌心加三指也像四个触点,不参与
    static let mouseFamilies: Set<Int32> = [112, 113]

    init() {
        isAvailable = LPMultitouchLoad() && LPMultitouchCreateDeviceList().map { !Self.trackpads(in: $0).isEmpty } == true
    }

    func setEnabled(_ enabled: Bool) {
        guard isAvailable, enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            start()
            observeSystem()
        } else {
            stop()
            observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
            observers = []
            deviceWatch?.cancel()
        }
    }

    private func start() {
        guard devices == nil, let list = LPMultitouchCreateDeviceList() else { return }
        devices = list
        let trackpads = Self.trackpads(in: list)
        deviceIDs = Set(trackpads.map(LPMultitouchDeviceID))
        TouchRelay.shared.connect { [weak self] gesture in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.onGesture?(gesture) }
            }
        }
        let failures = trackpads.filter { LPMultitouchStart($0, touchFrameCallback) != 0 }.count
        if failures > 0 { Log.app.error("触控板监听启动失败 \(failures) 个,稍后重试") }
        Log.app.notice("触控板手势已启用,触控板 \(trackpads.count) 块")
    }

    private func stop() {
        guard let list = devices else { return }
        Self.trackpads(in: list).forEach { LPMultitouchStop($0, touchFrameCallback) }
        devices = nil
        deviceIDs = []
        TouchRelay.shared.disconnect()
    }

    private func restart() {
        stop()
        start()
    }

    /// 设备换了(增减、断开重连会换编号)、有设备没在跑、或唤醒通知丢了没重启,就重新挂接
    private func needsRestart() -> Bool {
        guard let current = LPMultitouchCreateDeviceList() else { return devices != nil }
        guard let list = devices else { return true }
        let currentIDs = Set(Self.trackpads(in: current).map(LPMultitouchDeviceID))
        return currentIDs != deviceIDs || Self.trackpads(in: list).contains { !LPMultitouchIsRunning($0) }
    }

    /// 睡眠时停、唤醒后重挂(否则唤醒后收不到数据);定期核对设备
    private func observeSystem() {
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let monitor = self, monitor.isEnabled else { return }
                    monitor.restart()
                }
            },
        ]
        deviceWatch?.cancel()
        deviceWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.deviceCheckInterval)
                guard let monitor = self, monitor.isEnabled, monitor.needsRestart() else { continue }
                monitor.restart()
            }
        }
    }

    private static func trackpads(in list: CFArray) -> [LPMTDeviceRef] {
        (0..<CFArrayGetCount(list))
            .compactMap { index in CFArrayGetValueAtIndex(list, index).map { UnsafeMutableRawPointer(mutating: $0) } }
            .filter { !mouseFamilies.contains(LPMultitouchFamilyID($0)) }
    }
}

/// 框架线程上的回调:把接触中的触点交给对应设备的识别器
private func touchFrameCallback(
    _ device: LPMTDeviceRef,
    _ touches: UnsafeMutablePointer<LPMTTouch>?,
    _ count: Int32,
    _ timestamp: Double,
    _ frame: Int32
) {
    TouchRelay.shared.receive(device: device, touches: UnsafeBufferPointer(start: touches, count: Int(max(count, 0))))
}

/// 识别器状态(每台设备一个)与结果出口,跨线程访问一律加锁
final class TouchRelay: Sendable {
    static let shared = TouchRelay()

    typealias Sink = @Sendable (PinchDetector.Gesture) -> Void

    private struct State {
        var detectors: [UInt: PinchDetector] = [:]
        var sink: Sink?
        var hasReceivedFrame = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// 3 = 刚接触,4 = 接触中
    private static let touchingStates: Set<Int32> = [3, 4]

    func connect(_ sink: @escaping Sink) {
        state.withLock { $0 = State(sink: sink) }
    }

    func disconnect() {
        state.withLock { $0 = State() }
    }

    func receive(device: LPMTDeviceRef, touches: UnsafeBufferPointer<LPMTTouch>) {
        let points = touches.filter { Self.touchingStates.contains($0.state) }.map {
            TouchPoint(id: Int($0.identifier), x: Double($0.normalizedPosition.position.x), y: Double($0.normalizedPosition.position.y))
        }
        let key = UInt(bitPattern: device)
        let (gesture, sink, isFirstFrame) = state.withLock { state -> (PinchDetector.Gesture?, Sink?, Bool) in
            var detector = state.detectors[key] ?? PinchDetector()
            let gesture = detector.update(touches: points)
            state.detectors[key] = detector
            let isFirst = state.sink != nil && !state.hasReceivedFrame
            state.hasReceivedFrame = true
            return (gesture, state.sink, isFirst)
        }
        if isFirstFrame { Log.app.notice("已收到触控板触点数据") }
        if let gesture, let sink { sink(gesture) }
    }
}
