import AppKit

/// 菜单栏图标:打开启动台、设置、重新扫描、退出
@MainActor
final class StatusItemController: NSObject {
    var onOpen: (() -> Void)?
    var onSettings: (() -> Void)?
    var onRescan: (() -> Void)?

    private var item: NSStatusItem?

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "启动台")
            item.menu = makeMenu()
            self.item = item
        } else if !visible, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "打开启动台", action: #selector(open), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "重新扫描应用", action: #selector(rescan), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出启动台", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func open() { onOpen?() }
    @objc private func settings() { onSettings?() }
    @objc private func rescan() { onRescan?() }
}
