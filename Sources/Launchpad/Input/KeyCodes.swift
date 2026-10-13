import AppKit
import Carbon.HIToolbox

/// 用到的虚拟键码(取自 Carbon 的 kVK_*,单一来源)
enum KeyCode {
    static let escape = UInt16(kVK_Escape)
    static let returnKey = UInt16(kVK_Return)
    static let enter = UInt16(kVK_ANSI_KeypadEnter)
    static let delete = UInt16(kVK_Delete)
    static let forwardDelete = UInt16(kVK_ForwardDelete)
    static let left = UInt16(kVK_LeftArrow)
    static let right = UInt16(kVK_RightArrow)
    static let down = UInt16(kVK_DownArrow)
    static let up = UInt16(kVK_UpArrow)
    static let comma = UInt16(kVK_ANSI_Comma)
    static let tab = UInt16(kVK_Tab)
    static let space = UInt16(kVK_Space)

    static let functionKeys: [UInt16: String] = [
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4",
        UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
        UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15", UInt16(kVK_F16): "F16",
        UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18", UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20",
    ]

    static let symbols: [UInt16: String] = [
        space: "空格", returnKey: "↩", enter: "⌤", tab: "⇥", delete: "⌫",
        forwardDelete: "⌦", escape: "⎋", left: "←", right: "→", down: "↓", up: "↑",
        UInt16(kVK_Home): "↖", UInt16(kVK_End): "↘", UInt16(kVK_PageUp): "⇞", UInt16(kVK_PageDown): "⇟",
    ]
}
