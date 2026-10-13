import AppKit
import LaunchpadCore

/// 打开 App、在访达中显示;失败时弹窗说明原因。
@MainActor
enum AppLauncher {
    static func open(_ app: AppEntry) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let name = app.name
        NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) { _, error in
            guard let error else { return }
            let reason = error.localizedDescription
            Log.app.error("打开 \(name, privacy: .public) 失败: \(reason, privacy: .public)")
            Task { @MainActor in
                showAlert(title: "无法打开「\(name)」", message: reason)
            }
        }
    }

    static func revealInFinder(_ app: AppEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
    }

    static func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate()
        alert.runModal()
    }
}
