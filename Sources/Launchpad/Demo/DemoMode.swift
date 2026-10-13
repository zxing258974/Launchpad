import AppKit
import LaunchpadCore

/// 截图用的演示模式:`--demo` 启动时 App 列表、图标、排列、壁纸全部换成生成的假数据,
/// 排列和设置写进临时目录与单独的设置域,不碰真实数据。
/// `--demo-scene grid|search|folder|settings` 直接摆好要截的画面,不需要鼠标键盘操作。
/// 截图流程见 scripts/screenshots.sh。
@MainActor
enum DemoMode {
    static let isEnabled = CommandLine.arguments.contains("--demo")

    enum Scene: String {
        case grid, search, folder, settings
    }

    static var scene: Scene {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--demo-scene"), arguments.indices.contains(index + 1) else { return .grid }
        return Scene(rawValue: arguments[index + 1]) ?? .grid
    }

    static let searchQuery = "ph"
    static let creativeFolderID = "demo-creative"
    static let utilitiesFolderID = "demo-utilities"
    static let defaultsSuite = "com.zhangxing.Launchpad.demo"

    /// 虚构的 App:名称、SF Symbol、渐变上下两色
    struct FakeApp {
        let name: String
        let symbol: String
        let top: UInt32
        let bottom: UInt32

        var id: String { "demo." + name.lowercased().filter(\.isLetter) }
    }

    private static func app(_ name: String, _ symbol: String, _ top: UInt32, _ bottom: UInt32) -> FakeApp {
        FakeApp(name: name, symbol: symbol, top: top, bottom: bottom)
    }

    static let creative: [FakeApp] = [
        app("Sketchpad", "paintbrush.pointed.fill", 0xFF8A65, 0xE64A19),
        app("Photo Lab", "photo.on.rectangle.angled", 0x64B5F6, 0x1E63D6),
        app("Frame Cut", "film.fill", 0x9575CD, 0x512DA8),
        app("Color Mixer", "paintpalette.fill", 0xFFD54F, 0xF57C00),
        app("Blueprint", "pencil.and.ruler.fill", 0x4DB6AC, 0x00796B),
        app("Vector", "scribble.variable", 0xF06292, 0xC2185B),
    ]

    static let utilities: [FakeApp] = [
        app("Disk Doctor", "internaldrive.fill", 0xB0BEC5, 0x546E7A),
        app("Monitor", "gauge.with.dots.needle.67percent", 0x81C784, 0x2E7D32),
        app("Archive", "archivebox.fill", 0xBCAAA4, 0x6D4C41),
        app("Snapshot", "camera.viewfinder", 0x90A4AE, 0x37474F),
        app("Vault", "lock.fill", 0x7986CB, 0x283593),
        app("Logbook", "doc.text.magnifyingglass", 0xA1887F, 0x4E342E),
    ]

    /// 第一页:33 个 App + 两个文件夹(插在第 10、21 格),正好 7×5
    static let firstPage: [FakeApp] = [
        app("Mailbox", "envelope.fill", 0x5AB0FF, 0x1565C0),
        app("Planner", "calendar", 0xFF7A7A, 0xD32F2F),
        app("Photon", "camera.aperture", 0xFFB74D, 0xEF6C00),
        app("Notebook", "note.text", 0xFFE082, 0xFFB300),
        app("Chatter", "bubble.left.and.bubble.right.fill", 0x69F0AE, 0x00A152),
        app("Atlas", "map.fill", 0x4DD0E1, 0x00838F),
        app("Tunes", "music.note", 0xFF80AB, 0xE91E63),
        app("Skyline", "cloud.sun.fill", 0x80D8FF, 0x0288D1),
        app("Timekeeper", "clock.fill", 0x616161, 0x212121),
        app("Abacus", "plus.forwardslash.minus", 0x9E9E9E, 0x424242),
        app("Voyager", "globe", 0x64B5F6, 0x1976D2),
        app("Shell", "terminal.fill", 0x424242, 0x111111),
        app("CodeForge", "chevron.left.forwardslash.chevron.right", 0xB388FF, 0x6200EA),
        app("Airwaves", "antenna.radiowaves.left.and.right", 0xCE93D8, 0x8E24AA),
        app("Library", "books.vertical.fill", 0xFFAB40, 0xE65100),
        app("Checklist", "checklist", 0x82B1FF, 0x2962FF),
        app("People", "person.2.fill", 0xBCAAA4, 0x795548),
        app("Lingo", "quote.bubble.fill", 0x8C9EFF, 0x3D5AFE),
        app("Pulse", "heart.fill", 0xFF8A80, 0xD50000),
        app("Ticker", "chart.line.uptrend.xyaxis", 0x4F4F4F, 0x1B1B1B),
        app("Dwelling", "house.fill", 0xFFCC80, 0xFB8C00),
        app("Cinema", "popcorn.fill", 0xFF5252, 0xB71C1C),
        app("Arcade", "gamecontroller.fill", 0xB39DDB, 0x5E35B1),
        app("Phonebook", "phone.fill", 0x69F0AE, 0x1B9E4B),
        app("Headlines", "newspaper.fill", 0xFF6E6E, 0xC62828),
        app("Recorder", "waveform", 0xFF5C8A, 0xAD1457),
        app("Viewer", "doc.richtext.fill", 0x90CAF9, 0x1E88E5),
        app("Market", "bag.fill", 0x40C4FF, 0x0277BD),
        app("Control", "gearshape.fill", 0xBDBDBD, 0x616161),
        app("Locator", "location.fill", 0x76FF03, 0x33A02C),
        app("Cloudbox", "icloud.fill", 0x80D8FF, 0x039BE5),
        app("Gambit", "crown.fill", 0xFFD740, 0xFF8F00),
        app("Studio Mix", "slider.horizontal.3", 0xEA80FC, 0xAA00FF),
    ]

    static let secondPage: [FakeApp] = [
        app("Scanner", "doc.viewfinder", 0x84FFFF, 0x00B8D4),
        app("Whiteboard", "rectangle.and.pencil.and.ellipsis", 0xFFFF8D, 0xFBC02D),
        app("Flashcards", "rectangle.on.rectangle.angled", 0xFF9E80, 0xDD2C00),
        app("Recipes", "fork.knife", 0xFFAB91, 0xD84315),
        app("Budget", "dollarsign.circle.fill", 0xA5D6A7, 0x388E3C),
        app("Travel", "airplane", 0x81D4FA, 0x0277BD),
        app("Journal", "book.closed.fill", 0xD7CCC8, 0x8D6E63),
        app("Meditate", "leaf.fill", 0xC5E1A5, 0x558B2F),
        app("Starlight", "moon.stars.fill", 0x7C83FD, 0x283593),
        app("Podium", "mic.fill", 0xF48FB1, 0xC2185B),
        app("Pixel", "square.grid.3x3.fill", 0x80CBC4, 0x00695C),
        app("Remote", "display", 0x9FA8DA, 0x3949AB),
        app("Puzzle", "puzzlepiece.fill", 0xFFCC80, 0xEF6C00),
        app("Garden", "camera.macro", 0xAED581, 0x689F38),
    ]

    static var allApps: [FakeApp] { firstPage + creative + utilities + secondPage }

    // MARK: 装配

    /// 独立的设置域,每次启动清空,截出来的设置页是默认值
    static func freshDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: defaultsSuite) ?? .standard
        defaults.removePersistentDomain(forName: defaultsSuite)
        defaults.set(false, forKey: AppSettings.Key.showMenuBarIcon.rawValue)
        return defaults
    }

    /// 临时目录里生成只有 Info.plist 的假 .app,交给正常的扫描流程
    static func makeWorkspace() -> (apps: URL, layoutFile: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchpadDemo-\(ProcessInfo.processInfo.processIdentifier)")
        let appsDir = root.appendingPathComponent("Apps")
        try? FileManager.default.removeItem(at: root)
        for fake in allApps {
            let contents = appsDir.appendingPathComponent("\(fake.name).app/Contents")
            try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": fake.id, "CFBundleName": fake.name, "CFBundlePackageType": "APPL"]
            try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
        }
        return (appsDir, root.appendingPathComponent("layout.json"))
    }

    static func layout() -> LaunchLayout {
        var first = firstPage.map { LaunchItem.app($0.id) }
        first.insert(.folder(Folder(id: creativeFolderID, name: "Creative", appIDs: creative.map(\.id))), at: 9)
        first.insert(.folder(Folder(id: utilitiesFolderID, name: "Utilities", appIDs: utilities.map(\.id))), at: 20)
        return LaunchLayout(pages: [first, secondPage.map { LaunchItem.app($0.id) }])
    }

    // MARK: 图标与壁纸

    private static var iconCache: [String: NSImage] = [:]

    static func icon(for app: AppEntry) -> NSImage? {
        if let cached = iconCache[app.id] { return cached }
        guard let fake = allApps.first(where: { $0.id == app.id }) else { return nil }
        let image = drawIcon(fake)
        iconCache[app.id] = image
        return image
    }

    /// macOS 图标规格:1024 画布里主体 824、连续圆角 22.5%;上浅下深的渐变加白色图形
    private static func drawIcon(_ fake: FakeApp) -> NSImage {
        let side: CGFloat = 256
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let inset = side * 100 / 1024
            let body = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
            let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
            NSGradient(colors: [color(fake.top), color(fake.bottom)])?.draw(in: shape, angle: -90)
            let configuration = NSImage.SymbolConfiguration(pointSize: body.width * 0.42, weight: .semibold)
                .applying(.init(paletteColors: [.white]))
            if let glyph = NSImage(systemSymbolName: fake.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                let size = glyph.size
                glyph.draw(in: NSRect(x: body.midX - size.width / 2, y: body.midY - size.height / 2, width: size.width, height: size.height))
            }
            return true
        }
    }

    /// 深蓝紫底上几团柔和的彩色光斑
    static func wallpaper(size: CGSize) -> CGImage? {
        let width = max(Int(size.width / 2), 1)
        let height = max(Int(size.height / 2), 1)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let base = CGGradient(colorsSpace: space, colors: [cg(0x1A237E), cg(0x4A148C), cg(0x004D61)] as CFArray, locations: [0, 0.55, 1])!
        context.drawLinearGradient(base, start: .zero, end: CGPoint(x: width, y: height), options: [])
        let blobs: [(x: CGFloat, y: CGFloat, radius: CGFloat, color: UInt32)] = [
            (0.2, 0.75, 0.45, 0xEC407A), (0.75, 0.7, 0.4, 0x26C6DA), (0.55, 0.2, 0.5, 0xFFA726), (0.1, 0.15, 0.35, 0x7E57C2),
        ]
        for blob in blobs {
            let center = CGPoint(x: blob.x * CGFloat(width), y: blob.y * CGFloat(height))
            let radius = blob.radius * CGFloat(max(width, height))
            let gradient = CGGradient(colorsSpace: space, colors: [cg(blob.color, alpha: 0.55), cg(blob.color, alpha: 0)] as CFArray, locations: [0, 1])!
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }
        return context.makeImage()
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static func cg(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        color(hex).withAlphaComponent(alpha).cgColor
    }
}
