import AppKit

/// 延时执行;返回的任务被取消就不跑
@MainActor
@discardableResult
func delayed(_ seconds: Double, _ work: @escaping @MainActor () -> Void) -> Task<Void, Never> {
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(seconds))
        guard !Task.isCancelled else { return }
        work()
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension NSApplication {
    /// 激活本 App。macOS 14 起 activate() 是协作式的,由热角、快捷键、脚本启动时会被系统拒绝(实测),
    /// 面板就抢不到键盘焦点、设置窗口显示为未激活;已弃用的旧接口仍然有效。
    func forceActivate() {
        (self as LegacyActivation).activate(ignoringOtherApps: true)
    }
}

/// 经协议调用已弃用的 `activate(ignoringOtherApps:)`,不产生弃用告警
@MainActor
private protocol LegacyActivation {
    func activate(ignoringOtherApps flag: Bool)
}

extension NSApplication: LegacyActivation {}
