import AppKit
import LaunchpadCore
import Observation

/// 热角要求同时按住的修饰键(与系统触发角的设置一致)
enum CornerModifier: String, CaseIterable, Identifiable, Sendable {
    case none, command, option, control, shift

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "无"
        case .command: "⌘ Command"
        case .option: "⌥ Option"
        case .control: "⌃ Control"
        case .shift: "⇧ Shift"
        }
    }

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .none: []
        case .command: .command
        case .option: .option
        case .control: .control
        case .shift: .shift
        }
    }
}

/// 用户设置,存 UserDefaults。任何一项改动都会回调 `onChange`。
@MainActor
@Observable
final class AppSettings {
    enum Key: String {
        case hotCorners, cornerModifier, cornerDelay, hotKey, columns, rows, iconScale, backgroundDim, showMenuBarIcon, pinchGesture
    }

    static let columnRange = 4...12
    static let rowRange = 3...8
    /// 背景至少压暗一点,亮色壁纸上白字也能看清
    static let dimRange = 0.1...0.6

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onChange: ((Key) -> Void)?

    var hotCorners: Set<ScreenCorner> { didSet { persist(.hotCorners, hotCorners.map(\.rawValue).sorted()) } }
    var cornerModifier: CornerModifier { didSet { persist(.cornerModifier, cornerModifier.rawValue) } }
    var cornerDelay: Double { didSet { persist(.cornerDelay, cornerDelay) } }
    var hotKey: KeyCombo? { didSet { persist(.hotKey, hotKey.flatMap { try? JSONEncoder().encode($0) }) } }
    var columns: Int { didSet { persist(.columns, columns) } }
    var rows: Int { didSet { persist(.rows, rows) } }
    var iconScale: Double { didSet { persist(.iconScale, iconScale) } }
    var backgroundDim: Double { didSet { persist(.backgroundDim, backgroundDim) } }
    var showMenuBarIcon: Bool { didSet { persist(.showMenuBarIcon, showMenuBarIcon) } }
    /// 四指捏合打开、张开收起
    var pinchGesture: Bool { didSet { persist(.pinchGesture, pinchGesture) } }

    var capacity: Int { columns * rows }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let corners = (defaults.array(forKey: Key.hotCorners.rawValue) as? [String])?.compactMap(ScreenCorner.init(rawValue:))
        // 旧启动台用户多把左下角设成启动台,默认沿用
        hotCorners = Set(corners ?? [.bottomLeft])
        cornerModifier = defaults.string(forKey: Key.cornerModifier.rawValue).flatMap(CornerModifier.init(rawValue:)) ?? .none
        cornerDelay = defaults.object(forKey: Key.cornerDelay.rawValue) as? Double ?? 0.15
        hotKey = defaults.data(forKey: Key.hotKey.rawValue).flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) }
        columns = Self.clamped(defaults.object(forKey: Key.columns.rawValue) as? Int ?? 7, to: Self.columnRange)
        rows = Self.clamped(defaults.object(forKey: Key.rows.rawValue) as? Int ?? 5, to: Self.rowRange)
        iconScale = defaults.object(forKey: Key.iconScale.rawValue) as? Double ?? 1
        backgroundDim = min(max(defaults.object(forKey: Key.backgroundDim.rawValue) as? Double ?? 0.25, Self.dimRange.lowerBound), Self.dimRange.upperBound)
        showMenuBarIcon = defaults.object(forKey: Key.showMenuBarIcon.rawValue) as? Bool ?? true
        pinchGesture = defaults.object(forKey: Key.pinchGesture.rawValue) as? Bool ?? true
    }

    private func persist(_ key: Key, _ value: Any?) {
        if let value { defaults.set(value, forKey: key.rawValue) } else { defaults.removeObject(forKey: key.rawValue) }
        onChange?(key)
    }

    private static func clamped(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// 全局快捷键。`keyLabel` 在录制时记下,免得再查键盘布局。
struct KeyCombo: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt
    let keyLabel: String

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var display: String {
        let flags = modifierFlags
        let symbols = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { flags.contains($0.0) }
            .map(\.1)
            .joined()
        return symbols + keyLabel
    }

    /// 按键名:特殊键用符号,其余取按键上的字符
    static func label(keyCode: UInt16, characters: String?) -> String {
        KeyCode.symbols[keyCode] ?? KeyCode.functionKeys[keyCode] ?? (characters ?? "?").uppercased()
    }

    /// F 键单按也可以作快捷键,其余键必须带 ⌘/⌥/⌃ 之一
    static func isAcceptable(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        KeyCode.functionKeys[keyCode] != nil || !modifiers.intersection([.command, .option, .control]).isEmpty
    }
}
