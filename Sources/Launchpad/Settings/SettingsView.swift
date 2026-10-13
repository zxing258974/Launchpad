import AppKit
import LaunchpadCore
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let catalog: AppCatalog
    let hotKeyRecorder: HotKeyRecorderModel
    let isPinchAvailable: Bool

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var layoutMessage: String?
    @State private var confirmImport = false
    @State private var confirmReset = false
    /// 从系统设置改完触发角回来(本 App 重新激活)时自增,让冲突提醒重读
    @State private var systemCornersVersion = 0

    var body: some View {
        Form {
            Section {
                CornerPicker(selection: $settings.hotCorners)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                Picker("同时按住", selection: $settings.cornerModifier) {
                    ForEach(CornerModifier.allCases) { Text($0.title).tag($0) }
                }
                SliderRow(
                    title: "停留时间", value: $settings.cornerDelay, range: 0...1, step: 0.05,
                    readout: settings.cornerDelay == 0 ? "立即" : String(format: "%.2f 秒", settings.cornerDelay)
                )
                SystemCornerWarning(enabled: settings.hotCorners, version: systemCornersVersion)
            } header: {
                Text("触发角")
            } footer: {
                Text("光标推到选中的屏幕角落即打开启动台,再推一次收起。停留时间可防误触。")
            }

            Section {
                Toggle("四指捏合打开,张开收起", isOn: $settings.pinchGesture)
                    .disabled(!isPinchAvailable)
                if !isPinchAvailable {
                    Text("这台 Mac 上读不到触控板数据,手势不可用。").font(.caption).foregroundStyle(.secondary)
                } else if settings.pinchGesture {
                    SystemPinchWarning(version: systemCornersVersion)
                }
            } header: {
                Text("手势")
            } footer: {
                Text("同旧启动台:拇指和三根手指在触控板上合拢打开,张开收起。")
            }

            Section("快捷键") {
                LabeledContent("打开 / 收起启动台") {
                    HotKeyRecorderView(model: hotKeyRecorder, combo: $settings.hotKey)
                }
            }

            Section {
                Stepper("每行 \(settings.columns) 个", value: $settings.columns, in: AppSettings.columnRange)
                Stepper("每页 \(settings.rows) 行", value: $settings.rows, in: AppSettings.rowRange)
                SliderRow(
                    title: "图标大小", value: $settings.iconScale, range: 0.7...1.3, step: 0.05,
                    readout: "\(Int((settings.iconScale * 100).rounded()))%"
                )
                SliderRow(
                    title: "背景暗度", value: $settings.backgroundDim, range: AppSettings.dimRange, step: 0.05,
                    readout: "\(Int((settings.backgroundDim * 100).rounded()))%"
                )
            } header: {
                Text("网格")
            } footer: {
                Text("减少行列时,放不下的图标会挤到下一页。壁纸较亮时背景会自动再压暗一些,保证图标名看得清。")
            }

            Section("通用") {
                Toggle("登录时自动启动", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("在菜单栏显示图标", isOn: $settings.showMenuBarIcon)
                if !settings.showMenuBarIcon {
                    Text("隐藏后,在启动台里按 ⌘, 可回到这里。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    Button("从旧启动台导入…") { confirmImport = true }
                        .disabled(!catalog.hasLegacyDatabase)
                        .help(catalog.hasLegacyDatabase ? "读取 macOS 15 及以前启动台留下的排列" : "没有找到旧启动台的数据")
                    Button("恢复默认排列…") { confirmReset = true }
                    Spacer()
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([catalog.storeURL])
                    }
                }
                if !catalog.hasLegacyDatabase {
                    Text("没有找到旧启动台的数据,无法导入。").font(.caption).foregroundStyle(.secondary)
                }
                if let layoutMessage {
                    Text(layoutMessage).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("排列")
            } footer: {
                Text("拖动图标可排序,拖到另一个图标上可建文件夹。排列保存在 \((catalog.storeURL.path as NSString).abbreviatingWithTildeInPath)")
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            SystemHotCorners.synchronize()
            systemCornersVersion += 1
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("用旧启动台的排列覆盖当前排列?", isPresented: $confirmImport) {
            Button("导入", role: .destructive) { importLegacy() }
        } message: {
            Text("读取 macOS 15 及以前启动台留下的排列(含文件夹)。没装的 App 会跳过,新装的排在最后。")
        }
        .confirmationDialog("恢复默认排列?", isPresented: $confirmReset) {
            Button("恢复", role: .destructive) {
                catalog.resetToDefault()
                layoutMessage = "已恢复默认排列。"
            }
        } message: {
            Text("文件夹会被拆散,App 按名称重新排列。")
        }
    }

    /// 以系统登记的实际状态为准;失败时保留错误说明,不再反向触发一次注销
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            loginError = nil
        } catch {
            loginError = "设置失败:\(error.localizedDescription)"
        }
        launchAtLogin = LoginItem.isEnabled
    }

    private func importLegacy() {
        Task {
            switch await catalog.importLegacyLayout() {
            case .imported(let count): layoutMessage = "已导入旧启动台排列(\(count) 个 App)。"
            case .notFound: layoutMessage = "没有找到旧启动台的数据。"
            case .failed(let reason): layoutMessage = "导入失败:\(reason)"
            }
        }
    }
}

/// 带数值读数的滑杆;读数位宽固定,拖动时不跳
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let readout: String

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: step)
                    .accessibilityLabel(title)
                    .accessibilityValue(readout)
                Text(readout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// 一块小屏幕,四个角各一个开关。屏幕面固定深色,浅色/深色外观下都看得清。
struct CornerPicker: View {
    @Binding var selection: Set<ScreenCorner>

    static let screenSize = CGSize(width: 240, height: 150)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.2, green: 0.21, blue: 0.36), Color(red: 0.1, green: 0.1, blue: 0.17)],
                    startPoint: .top, endPoint: .bottom
                ))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                }
                .frame(width: Self.screenSize.width, height: Self.screenSize.height)
                .accessibilityHidden(true)
            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.75))
                .accessibilityHidden(true)
            ForEach(ScreenCorner.allCases, id: \.self) { corner in
                cornerButton(corner)
                    .frame(width: Self.screenSize.width, height: Self.screenSize.height, alignment: alignment(of: corner))
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private func cornerButton(_ corner: ScreenCorner) -> some View {
        let isOn = selection.contains(corner)
        return Button {
            selection = isOn ? selection.subtracting([corner]) : selection.union([corner])
        } label: {
            ZStack {
                Circle()
                    .fill(isOn ? Color.accentColor : Color.black.opacity(0.3))
                    .overlay { Circle().strokeBorder(.white.opacity(isOn ? 0 : 0.85), lineWidth: 1.5) }
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 22, height: 22)
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(corner.title)
        .accessibilityLabel(corner.title)
        .accessibilityValue(isOn ? "已启用" : "未启用")
        .accessibilityAddTraits(.isToggle)
    }

    private func alignment(of corner: ScreenCorner) -> Alignment {
        switch corner {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }
}

/// 系统触发角与这里选的角重叠时提醒。从系统设置改完回来(本 App 重新激活)会重读,新加的冲突也会出现。
struct SystemCornerWarning: View {
    let enabled: Set<ScreenCorner>
    /// 变化即重读系统设置
    let version: Int

    var body: some View {
        let conflicts = ScreenCorner.allCases.filter(enabled.contains).compactMap { corner in
            SystemHotCorners.actionName(for: corner).map { "\(corner.title)(\($0))" }
        }
        if !conflicts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("系统触发角也占用了:\(conflicts.joined(separator: "、"))")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Text("两边会同时生效。建议到 系统设置 › 桌面与程序坞 › 触发角 把它改成「-」。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("打开系统设置") { SystemHotCorners.openSettings() }
            }
        }
    }
}

/// 系统自带的四指捏合(macOS 26 里打开「App」)与张开(显示桌面)开着时会和这里同时触发,提醒去关掉
struct SystemPinchWarning: View {
    /// 变化即重读系统设置
    let version: Int

    var body: some View {
        let conflicts = SystemTrackpadGestures.enabledConflicts
        if !conflicts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("系统自带的「\(conflicts.joined(separator: "」「"))」手势也开着")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Text("两边会同时生效。建议到 系统设置 › 触控板 › 更多手势 把它们关掉。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("打开触控板设置") { SystemTrackpadGestures.openSettings() }
            }
        }
    }
}

enum SystemTrackpadGestures {
    private static let trackpadDomains = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]

    /// 与四指捏合/张开冲突、且开着的系统手势名
    static var enabledConflicts: [String] {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        let pinchOn = trackpadDomains.contains { domain in
            CFPreferencesAppSynchronize(domain as CFString)
            // 没设过即为系统默认(开)
            return (CFPreferencesCopyAppValue("TrackpadFourFingerPinchGesture" as CFString, domain as CFString) as? Int ?? 2) != 0
        }
        guard pinchOn else { return [] }
        return [("showLaunchpadGestureEnabled", "启动台 / App"), ("showDesktopGestureEnabled", "显示桌面")].compactMap { key, name in
            (CFPreferencesCopyAppValue(key as CFString, "com.apple.dock" as CFString) as? Bool ?? true) ? name : nil
        }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum SystemHotCorners {
    private static let keys: [ScreenCorner: String] = [
        .topLeft: "wvous-tl-corner", .topRight: "wvous-tr-corner",
        .bottomLeft: "wvous-bl-corner", .bottomRight: "wvous-br-corner",
    ]

    private static let names: [Int: String] = [
        2: "调度中心", 3: "应用程序窗口", 4: "桌面", 5: "开始屏幕保护程序", 6: "停用屏幕保护程序",
        7: "Dashboard", 10: "让显示器进入睡眠", 11: "启动台", 12: "通知中心", 13: "锁定屏幕", 14: "快速备忘录",
    ]

    /// 系统在这个角上设的动作;没设(0 或 1)返回 nil
    static func actionName(for corner: ScreenCorner) -> String? {
        guard let key = keys[corner],
              let value = CFPreferencesCopyAppValue(key as CFString, "com.apple.dock" as CFString) as? Int,
              value > 1 else { return nil }
        return names[value] ?? "动作 \(value)"
    }

    /// 丢掉缓存,读到系统设置里刚改的值
    static func synchronize() {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
