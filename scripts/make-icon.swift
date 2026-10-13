// 生成 App 图标:深色渐变圆角方块上 3×3 彩色小方块(致敬启动台的「一屏 App」)。
// 用法:swift scripts/make-icon.swift <输出的 .iconset 目录>
import AppKit
import SwiftUI

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let tileColors: [NSColor] = [
    NSColor(srgbRed: 1.00, green: 0.42, blue: 0.38, alpha: 1), NSColor(srgbRed: 1.00, green: 0.70, blue: 0.25, alpha: 1),
    NSColor(srgbRed: 0.98, green: 0.86, blue: 0.30, alpha: 1), NSColor(srgbRed: 0.40, green: 0.85, blue: 0.45, alpha: 1),
    NSColor(srgbRed: 0.30, green: 0.80, blue: 0.85, alpha: 1), NSColor(srgbRed: 0.33, green: 0.58, blue: 1.00, alpha: 1),
    NSColor(srgbRed: 0.55, green: 0.45, blue: 1.00, alpha: 1), NSColor(srgbRed: 0.85, green: 0.42, blue: 0.95, alpha: 1),
    NSColor(srgbRed: 1.00, green: 0.45, blue: 0.70, alpha: 1),
]

func continuousRoundedRect(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(cgPath: RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath)
}

func render(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS 图标网格:1024 画布里主体 824,四周留白;小尺寸取整到像素
    let small = pixels <= 32
    let inset = small ? (size * 100 / 1024).rounded() : size * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    // 与系统图标同款的连续曲率圆角(squircle),而不是普通圆角
    let shape = continuousRoundedRect(body, radius: body.width * 0.225)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = size * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    shadow.set()
    NSGradient(colors: [
        NSColor(srgbRed: 0.16, green: 0.17, blue: 0.32, alpha: 1),
        NSColor(srgbRed: 0.07, green: 0.07, blue: 0.14, alpha: 1),
    ])!.draw(in: shape, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // 顶部一道柔光
    NSGraphicsContext.current?.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // 16/32 像素下 3×3 会糊成一片,改画 2×2;整数像素的格子与间距,整组在主体里居中
    let grid = small ? 2 : 3
    let baseGap = small ? max(1, (body.width * 0.1).rounded()) : body.width * 0.07
    let tile = small ? ((body.width - baseGap * CGFloat(grid + 1)) / CGFloat(grid)).rounded(.down) : (body.width - baseGap * 4) / 3
    // 余量为奇数时把多出的 1 像素给中缝,四边留白才对称
    let leftover = body.width - tile * CGFloat(grid) - baseGap * CGFloat(grid - 1)
    let gap = small && Int(leftover) % 2 == 1 ? baseGap + 1 : baseGap
    let groupSize = tile * CGFloat(grid) + gap * CGFloat(grid - 1)
    let origin = small ? ((body.width - groupSize) / 2).rounded(.down) : gap
    let palette = grid == 2 ? [tileColors[0], tileColors[3], tileColors[5], tileColors[7]] : tileColors
    for row in 0..<grid {
        for column in 0..<grid {
            let rect = NSRect(
                x: body.minX + origin + CGFloat(column) * (tile + gap),
                y: body.maxY - origin - tile - CGFloat(row) * (tile + gap),
                width: tile, height: tile
            )
            let color = palette[row * grid + column]
            let path = continuousRoundedRect(rect, radius: tile * 0.26)
            NSGradient(colors: [color.blended(withFraction: 0.25, of: .white)!, color])!.draw(in: path, angle: -90)
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(pixels: points * scale).write(to: output.appendingPathComponent(name))
    }
}
print("已生成 \(output.path)")
