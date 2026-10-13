import AppKit
import LaunchpadCore
import SwiftUI

/// 网格里的一格:图标 + 名称。状态由外层算好传进来,
/// 自己不读面板的可变状态,输入不变时 SwiftUI 会跳过重算。
struct ItemCell: View {
    let item: LaunchItem
    let model: OverlayModel
    let iconSize: CGFloat
    let cellWidth: CGFloat
    let labelWidth: CGFloat
    /// 选中框尺寸(与可点区域一致)
    let highlightSize: CGSize
    /// 格高:选中框不超出本格
    var cellHeight: CGFloat = .infinity
    /// 在文件夹里时为所属文件夹
    var folderID: String?
    /// 读屏「移到上一页/下一页」是否可用(搜索结果里、首页的「上一页」不提供)
    var canMoveBack = false
    var canMoveForward = false
    var isSelected = false
    var isPressed = false
    var isMergeTarget = false
    var isPlaceholder = false

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let style = OverlayStyle(contrast: contrast)
        VStack(spacing: GridMetrics.labelSpacing) {
            ZStack {
                if isMergeTarget {
                    // 预览即将生成的文件夹底板:与文件夹图标同款,略大一圈
                    let plate = iconSize * GridMetrics.iconBodyRatio * OverlayStyle.mergePlateScale
                    TranslucentPlate(radius: plate * GridMetrics.iconCornerRatio, fill: OverlayStyle.mergePlateFill, style: style)
                        .frame(width: plate, height: plate)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                }
                ItemIcon(item: item, model: model, size: iconSize)
                    .brightness(isPressed ? OverlayStyle.pressedBrightness : 0)
                    .scaleEffect(isMergeTarget && !reduceMotion ? OverlayStyle.mergeTargetScale : 1)
            }
            .frame(width: iconSize, height: iconSize)
            ItemLabel(text: title, iconSize: iconSize, style: style)
                .frame(width: labelWidth)
        }
        .frame(width: cellWidth, height: iconSize + GridMetrics.labelHeight, alignment: .top)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: iconSize * OverlayStyle.selectionRadiusRatio, style: .continuous)
                    .fill(.white.opacity(OverlayStyle.selectionFill))
                    .overlay {
                        RoundedRectangle(cornerRadius: iconSize * OverlayStyle.selectionRadiusRatio, style: .continuous)
                            .strokeBorder(.white.opacity(style.selectionStroke), lineWidth: style.selectionStrokeWidth)
                    }
                    .frame(
                        width: min(highlightSize.width + OverlayStyle.selectionPadding * 2, cellWidth),
                        height: min(highlightSize.height + OverlayStyle.selectionPadding * 2, cellHeight)
                    )
            }
        }
        .opacity(isPlaceholder ? 0 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        // 鼠标走本地事件监听,读屏的「按下」与自定义操作要单独接到模型上
        .accessibilityAction { model.activate(item) }
        .accessibilityActions { accessibilityActions }
    }

    @ViewBuilder
    private var accessibilityActions: some View {
        if let appID = item.appID {
            Button("在访达中显示") { model.revealInFinder(appID) }
        }
        if let folderID, let appID = item.appID {
            Button("移出文件夹") { model.moveOutOfFolder(appID, folderID: folderID) }
        }
        if canMoveBack {
            Button("移到上一页") { model.moveItem(item.id, byPages: -1) }
        }
        if canMoveForward {
            Button("移到下一页") { model.moveItem(item.id, byPages: 1) }
        }
    }

    private var accessibilityTitle: String {
        item.folder == nil ? title : "\(title),文件夹"
    }

    private var accessibilityValue: String {
        item.folder.map { "\($0.appIDs.count) 个 App" } ?? ""
    }

    private var title: String {
        switch item {
        case .app(let appID): model.app(appID)?.name ?? ""
        case .folder(let folder): folder.name
        }
    }

}

struct ItemIcon: View {
    let item: LaunchItem
    let model: OverlayModel
    let size: CGFloat

    var body: some View {
        switch item {
        case .app(let appID):
            AppIcon(app: model.app(appID), icons: model.icons, size: size)
        case .folder(let folder):
            FolderIcon(folder: folder, model: model, size: size)
        }
    }
}

struct AppIcon: View {
    let app: AppEntry?
    let icons: IconProvider
    let size: CGFloat
    /// 文件夹里的小图标不画阴影,一个文件夹省 9 次模糊合成
    var hasShadow = true

    var body: some View {
        // 读 revision 以便栅格化完成后刷新
        let _ = icons.revision
        if let app {
            Image(nsImage: icons.image(for: app))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(hasShadow ? 0.25 : 0), radius: size * 0.04, y: size * 0.02)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }
}

/// 文件夹图标:与 App 图标主体同大、同圆角的半透明底板,里面 3×3 排前 9 个 App
struct FolderIcon: View {
    let folder: Folder
    let model: OverlayModel
    let size: CGFloat

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let plate = size * GridMetrics.iconBodyRatio
        let tile = plate * OverlayStyle.folderTileRatio
        let gap = plate * OverlayStyle.folderGapRatio
        let ids = Array(folder.appIDs.prefix(9))
        ZStack {
            Color.clear
                .frame(width: plate, height: plate)
                .translucentPlate(radius: plate * GridMetrics.iconCornerRatio, fill: OverlayStyle.tileFill, style: OverlayStyle(contrast: contrast))
            VStack(spacing: gap) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<3, id: \.self) { column in
                            let index = row * 3 + column
                            if index < ids.count {
                                AppIcon(app: model.app(ids[index]), icons: model.icons, size: tile, hasShadow: false)
                            } else {
                                Color.clear.frame(width: tile, height: tile)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: size, height: size)
    }
}

struct ItemLabel: View {
    let text: String
    let iconSize: CGFloat
    let style: OverlayStyle

    var body: some View {
        Text(text)
            .font(OverlayStyle.labelFont(iconSize: iconSize))
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.middle)
            .shadow(color: .black.opacity(style.labelShadow.opacity), radius: style.labelShadow.radius, y: 1)
    }
}
