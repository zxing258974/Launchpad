import AppKit
import Carbon.HIToolbox

/// 全局快捷键(Carbon RegisterEventHotKey,不需要辅助功能权限)
@MainActor
final class GlobalHotKey {
    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x4C_50_41_44 // 'LPAD'

    /// 注册;传 nil 即取消。组合键被别的 App 占用时注册失败,记日志。
    func register(_ combo: KeyCombo?) {
        unregister()
        guard let combo else { return }
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            combo.keyCode, Self.carbonModifiers(combo.modifierFlags), id,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
        if status != noErr {
            Log.app.error("快捷键 \(combo.display, privacy: .public) 注册失败: \(status)")
            hotKeyRef = nil
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.onPress?() }
            return noErr
        }, 1, &spec, context, &handlerRef)
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result = 0
        if flags.contains(.command) { result |= cmdKey }
        if flags.contains(.option) { result |= optionKey }
        if flags.contains(.control) { result |= controlKey }
        if flags.contains(.shift) { result |= shiftKey }
        return UInt32(result)
    }
}
