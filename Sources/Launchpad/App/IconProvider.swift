import AppKit
import LaunchpadCore
import Observation

/// App 图标缓存。后台按实际像素把图标栅格化成位图,动画时不用每帧缩放 1024 的原图;
/// 还没栅格化的(新装的 App)临时直接取系统图标。
@MainActor
@Observable
final class IconProvider {
    /// 栅格化完成后自增,让视图刷新
    private(set) var revision = 0

    @ObservationIgnored private var images: [String: NSImage] = [:]
    @ObservationIgnored private var rasterizedIDs = Set<String>()
    @ObservationIgnored private var rasterizedSize = 0
    @ObservationIgnored private var inFlight: (size: Int, ids: Set<String>, task: Task<Void, Never>)?

    /// 演示模式用生成的假图标
    @ObservationIgnored var override: ((AppEntry) -> NSImage?)?

    func image(for app: AppEntry) -> NSImage {
        if let override, let image = override(app) { return image }
        if let cached = images[Self.key(app)] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: app.url.path)
        images[Self.key(app)] = icon
        return icon
    }

    /// 缓存键带上版本号和路径:App 更新(图标可能换了)或挪了位置后自动重取
    static func key(_ app: AppEntry) -> String {
        "\(app.id)#\(app.version ?? "")#\(app.url.path)"
    }

    /// 按 `pixelSize` 栅格化还没处理的图标;尺寸变了就全部重做。
    /// 同样的活已经在跑就不重开;返回进行中的任务,需要时可以等它完成。
    @discardableResult
    func prepare(_ apps: [AppEntry], pixelSize: Int) -> Task<Void, Never>? {
        guard override == nil else { return nil }
        let size = max(pixelSize, 32)
        if size != rasterizedSize {
            rasterizedIDs.removeAll()
            rasterizedSize = size
        }
        let pending = apps.filter { !rasterizedIDs.contains(Self.key($0)) }
        guard !pending.isEmpty else { return inFlight?.task }
        let pendingIDs = Set(pending.map(Self.key))
        if let inFlight, inFlight.size == size, pendingIDs.isSubset(of: inFlight.ids) { return inFlight.task }

        inFlight?.task.cancel()
        let work = pending.map { (Self.key($0), $0.url.path) }
        let renderer = Task.detached(priority: .utility) { () -> [(String, SendableImage)] in
            var rendered: [(String, SendableImage)] = []
            for (id, path) in work {
                guard !Task.isCancelled else { break }
                if let box = Self.rasterize(path: path, pixels: size) { rendered.append((id, box)) }
            }
            return rendered
        }
        let task = Task { [weak self] in
            let rendered = await withTaskCancellationHandler { await renderer.value } onCancel: { renderer.cancel() }
            guard let self, !Task.isCancelled, size == rasterizedSize else { return }
            for (id, box) in rendered {
                images[id] = NSImage(cgImage: box.image, size: .zero)
                rasterizedIDs.insert(id)
            }
            inFlight = nil
            revision += 1
        }
        inFlight = (size, pendingIDs, task)
        return task
    }

    nonisolated static func rasterize(path: String, pixels: Int) -> SendableImage? {
        let icon = NSWorkspace.shared.icon(forFile: path)
        var rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        return icon.cgImage(forProposedRect: &rect, context: nil, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            .map(SendableImage.init)
    }
}
