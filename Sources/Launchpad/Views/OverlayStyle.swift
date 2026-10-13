import SwiftUI

/// 启动台面板的视觉 token。面板固定深色;「增强对比度」打开时描边、阴影、选中框都加重。
struct OverlayStyle {
    let isHighContrast: Bool

    init(contrast: ColorSchemeContrast) {
        isHighContrast = contrast == .increased
    }

    // 圆角
    static let fieldRadius: CGFloat = 8
    static let panelRadius: CGFloat = 30
    /// 选中框圆角相对图标尺寸
    static let selectionRadiusRatio: CGFloat = 0.16

    // 半透明白色填充
    static let fieldFill = 0.13
    static let tileFill = 0.2
    static let selectionFill = 0.24
    static let mergePlateFill = 0.3
    /// 合并预览:底板略大于图标主体,目标图标略缩进底板里
    static let mergePlateScale: CGFloat = 1.08
    static let mergeTargetScale: CGFloat = 0.94

    // 文字
    static let primaryText = 0.92
    static let titleFont = Font.system(size: 22, weight: .semibold)
    static let fieldFont = Font.system(size: 14)
    static let emptyStateFont = Font.system(size: 24, weight: .medium)

    /// 图标名:随图标大小在 11–14pt 之间
    static func labelFont(iconSize: CGFloat) -> Font {
        .system(size: min(max(iconSize * 0.13, 11), 14), weight: .medium)
    }

    // 页码点
    static let dotActive = 0.92

    // 浮起物(文件夹面板、拖拽残影)的投影
    static let liftShadow = Color.black.opacity(0.35)

    // 状态
    static let pressedBrightness = -0.28
    static let ghostScale: CGFloat = 1.12
    static let ghostOpacity = 0.92
    static let ghostShadowRadius: CGFloat = 14
    static let folderBackdrop = 0.2
    static let panelShadowRadius: CGFloat = 30
    /// 文件夹打开时背后网格的处理
    static let backgroundBlur: CGFloat = 18
    static let backgroundFade = 0.55
    /// 进场前网格略放大,落定时缩回(旧启动台的进场感)
    static let enterScale: CGFloat = 1.07
    /// 选中框比可点区域四周多出的留白
    static let selectionPadding: CGFloat = 6
    /// 文件夹图标里九宫格小图标与间距(相对底板)
    static let folderTileRatio: CGFloat = 0.26
    static let folderGapRatio: CGFloat = 0.02
    /// 改名框最宽
    static let titleFieldMaxWidth: CGFloat = 320

    var secondaryText: Double { isHighContrast ? 0.85 : 0.65 }
    var placeholderText: Double { isHighContrast ? 0.75 : 0.55 }
    var dotInactive: Double { isHighContrast ? 0.55 : 0.35 }
    var hairline: CGFloat { isHighContrast ? 1 : 0.75 }
    var strokeOpacity: Double { isHighContrast ? 0.5 : 0.18 }
    var selectionStroke: Double { isHighContrast ? 0.85 : 0.45 }
    var selectionStrokeWidth: CGFloat { isHighContrast ? 2 : 1 }
    var labelShadow: (opacity: Double, radius: CGFloat) { isHighContrast ? (0.75, 3) : (0.5, 2) }
    /// 增强对比度时背景额外压暗,保证白字可读
    var extraDim: Double { isHighContrast ? 0.15 : 0 }
}

/// 半透明底 + 细描边的圆角块(搜索框、文件夹底板、改名框共用)
struct TranslucentPlate: View {
    let radius: CGFloat
    let fill: Double
    let style: OverlayStyle

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(.white.opacity(fill))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.white.opacity(style.strokeOpacity), lineWidth: style.hairline)
            }
    }
}

extension View {
    func translucentPlate(radius: CGFloat, fill: Double, style: OverlayStyle) -> some View {
        background { TranslucentPlate(radius: radius, fill: fill, style: style) }
    }
}
