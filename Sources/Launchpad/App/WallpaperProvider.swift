import AppKit
import CoreGraphics
import CoreImage
import ImageIO

/// 旧启动台的背景:当前桌面壁纸大幅高斯模糊、略提饱和(窗口全被盖住,只见壁纸的色调)。
/// 按「壁纸文件 + 修改时间 + 尺寸 + 深浅外观」缓存,换壁纸、换外观自然重算。
/// 视频类动态壁纸读不出静态图时返回 nil,由调用方退回毛玻璃。
@MainActor
final class WallpaperProvider {
    struct Background: Sendable {
        let image: SendableImage
        /// 模糊后壁纸亮区(90 分位)的相对亮度(0 黑 ~ 1 白),用来自动加深背景保证白字可读
        let luminance: Double
    }

    private struct Key: Hashable, Sendable {
        let url: URL
        let modified: Date?
        let width: Int
        let height: Int
        let isDark: Bool
    }

    /// 模糊后细节全无,按屏幕一半分辨率渲染足够,省时省内存
    static let renderScale: CGFloat = 0.5
    /// 多屏、多桌面空间各有各的壁纸,留几份
    static let cacheLimit = 6

    private var cache: [Key: Background] = [:]
    private var recency: [Key] = []
    private var rendering: [Key: Task<Background?, Never>] = [:]

    func cachedBackground(for screen: NSScreen) -> Background? {
        guard let key = key(for: screen), let cached = cache[key] else { return nil }
        remember(cached, for: key)
        return cached
    }

    func background(for screen: NSScreen) async -> Background? {
        guard let key = key(for: screen) else { return nil }
        if let cached = cache[key] {
            remember(cached, for: key)
            return cached
        }
        let task = rendering[key] ?? Task.detached(priority: .userInitiated) {
            Self.render(url: key.url, size: CGSize(width: key.width, height: key.height), dark: key.isDark)
        }
        rendering[key] = task
        let result = await task.value
        rendering[key] = nil
        if let result { remember(result, for: key) }
        return result
    }

    private func remember(_ background: Background, for key: Key) {
        cache[key] = background
        recency = recency.filter { $0 != key } + [key]
        while recency.count > Self.cacheLimit {
            cache[recency.removeFirst()] = nil
        }
    }

    private func key(for screen: NSScreen) -> Key? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let size = screen.frame.size
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return Key(
            url: url, modified: modified,
            width: Int(size.width * Self.renderScale), height: Int(size.height * Self.renderScale), isDark: isDark
        )
    }

    // MARK: 渲染(后台线程)

    nonisolated static func render(url: URL, size: CGSize, dark: Bool) -> Background? {
        guard size.width > 0, size.height > 0, let source = loadImage(url: url, dark: dark),
              source.extent.width > 0, source.extent.height > 0 else { return nil }
        // 铺满(aspect fill)后居中裁切
        let scale = max(size.width / source.extent.width, size.height / source.extent.height)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = scaled.clampedToExtent()
            .applyingGaussianBlur(sigma: size.width * 0.02)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.15])
        let crop = CGRect(
            x: scaled.extent.midX - size.width / 2, y: scaled.extent.midY - size.height / 2,
            width: size.width, height: size.height
        )
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let image = context.createCGImage(blurred, from: crop) else { return nil }
        return Background(image: SendableImage(image: image), luminance: brightLuminance(of: image))
    }

    /// 随外观切换的动态壁纸(HEIC 多帧):按 apple_desktop 元数据取深色或浅色那一帧,否则取主图
    nonisolated static func loadImage(url: URL, dark: Bool) -> CIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let index = CGImageSourceGetCount(source) > 1 ? appearanceFrame(in: source, dark: dark) ?? 0 : 0
        return CGImageSourceCreateImageAtIndex(source, index, nil).map { CIImage(cgImage: $0) }
    }

    /// apple_desktop:apr / h24 / solar 元数据是 base64 的 plist;外观信息在 {"l": 浅色帧, "d": 深色帧}
    /// (apr 直接就是这个字典,h24/solar 放在 "ap" 键下)
    nonisolated static func appearanceFrame(in source: CGImageSource, dark: Bool) -> Int? {
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return nil }
        var frame: Int?
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { _, tag in
            guard (CGImageMetadataTagCopyPrefix(tag) as String?) == "apple_desktop",
                  let value = CGImageMetadataTagCopyValue(tag) as? String,
                  let data = Data(base64Encoded: value),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return true }
            let appearance = (plist["ap"] as? [String: Any]) ?? plist
            frame = appearance[dark ? "d" : "l"] as? Int
            return frame == nil
        }
        return frame
    }

    /// 缩到 32×20 取各像素相对亮度的 90 分位:比平均值更照顾上亮下暗这类壁纸的亮区
    nonisolated static func brightLuminance(of image: CGImage, percentile: Double = 0.9) -> Double {
        let width = 32, height = 20
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        func linear(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let values = stride(from: 0, to: pixels.count, by: 4).map {
            0.2126 * linear(pixels[$0]) + 0.7152 * linear(pixels[$0 + 1]) + 0.0722 * linear(pixels[$0 + 2])
        }.sorted()
        return values[min(Int(Double(values.count) * percentile), values.count - 1)]
    }

    /// 让白字在模糊壁纸上至少有 3:1 的对比度所需的最低暗度(封顶 0.5,标签还有阴影兜底)。
    /// 黑色蒙层在 sRGB 编码空间混合,亮度实际降为 L·(1-d)^2.2:
    /// 1.05 / (L·(1-d)^2.2 + 0.05) ≥ 3  ⇒  d ≥ 1 - (0.3 / L)^(1/2.2)
    nonisolated static func minimumDim(forLuminance luminance: Double) -> Double {
        guard luminance > 0.3 else { return 0 }
        return min(1 - pow(0.3 / luminance, 1 / 2.2), 0.5)
    }
}

/// CGImage 不可变,跨线程传递是安全的
struct SendableImage: @unchecked Sendable {
    let image: CGImage
}
