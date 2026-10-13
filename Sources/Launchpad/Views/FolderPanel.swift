import LaunchpadCore
import SwiftUI

/// 打开的文件夹:半透明圆角面板,顶部可改名,超过三行分页
struct FolderPanel: View {
    @Bindable var model: OverlayModel
    let folder: Folder
    let metrics: FolderMetrics
    var focus: FocusState<LaunchpadView.Field?>.Binding
    let style: OverlayStyle

    var body: some View {
        let panel = metrics.panelRect
        let pages = LayoutEngine.paginate(folder.appIDs.map(LaunchItem.app), capacity: metrics.capacity)
        let draggedID = model.drag?.item.id
        let pressedID = model.pressedItemID
        let selected = model.folderSelection
        let currentPage = model.folderPage
        let panelShape = RoundedRectangle(cornerRadius: OverlayStyle.panelRadius, style: .continuous)
        ZStack(alignment: .topLeading) {
            Color.black.opacity(OverlayStyle.folderBackdrop)
                .accessibilityHidden(true)

            panelShape
                .fill(.ultraThinMaterial)
                .overlay { panelShape.strokeBorder(.white.opacity(style.strokeOpacity), lineWidth: style.hairline) }
                .shadow(color: OverlayStyle.liftShadow, radius: OverlayStyle.panelShadowRadius, y: OverlayStyle.panelShadowRadius * 0.4)
                .frame(width: panel.width, height: panel.height)
                .position(x: panel.midX, y: panel.midY)
                .accessibilityHidden(true)

            FolderTitleField(model: model, focus: focus, style: style, width: metrics.titleRect.width, height: metrics.titleRect.height)
                .frame(width: metrics.titleRect.width, height: metrics.titleRect.height)
                .position(x: metrics.titleRect.midX, y: metrics.titleRect.midY)

            ZStack(alignment: .topLeading) {
                ForEach(pages.indices, id: \.self) { pageIndex in
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(pages[pageIndex].enumerated()), id: \.element.id) { index, item in
                            ItemCell(
                                item: item, model: model, iconSize: metrics.iconSize, cellWidth: metrics.cellSize.width,
                                labelWidth: metrics.labelWidth, highlightSize: metrics.itemRect(at: index).size,
                                folderID: folder.id,
                                isSelected: selected == metrics.folderIndex(page: pageIndex, local: index),
                                isPressed: item.id == pressedID, isPlaceholder: item.id == draggedID
                            )
                            .position(metrics.cellCenter(at: index))
                        }
                    }
                    .offset(x: CGFloat(pageIndex - currentPage) * panel.width + model.folderPageOffset)
                    .accessibilityHidden(pageIndex != currentPage)
                }
            }
            .frame(width: model.containerSize.width, height: model.containerSize.height, alignment: .topLeading)
            .mask {
                panelShape
                    .frame(width: panel.width, height: panel.height)
                    .position(x: panel.midX, y: panel.midY)
            }

            PageDots(current: currentPage, rects: metrics.dotRects(), style: style) { model.goToFolderPage($0) }
        }
        .frame(width: model.containerSize.width, height: model.containerSize.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("文件夹 \(folder.name)")
        .accessibilityAction(.escape) { model.closeFolder() }
    }
}

/// 文件夹名:平时是居中的标题,改名时显出输入框底板,看得出能编辑
struct FolderTitleField: View {
    @Bindable var model: OverlayModel
    var focus: FocusState<LaunchpadView.Field?>.Binding
    let style: OverlayStyle
    let width: CGFloat
    let height: CGFloat
    /// 读屏打开文件夹时,焦点先落在文件夹名上
    @AccessibilityFocusState private var isAccessibilityFocused: Bool

    var body: some View {
        let isEditing = focus.wrappedValue == .folderName
        TextField("", text: $model.folderNameDraft)
            .textFieldStyle(.plain)
            .font(OverlayStyle.titleFont)
            .foregroundStyle(.white.opacity(OverlayStyle.primaryText))
            .multilineTextAlignment(.center)
            .focused(focus, equals: .folderName)
            .onSubmit { model.endFolderRename() }
            .padding(.horizontal, 8)
            .frame(width: isEditing ? min(width, OverlayStyle.titleFieldMaxWidth) : width, height: height)
            .background {
                if isEditing { TranslucentPlate(radius: OverlayStyle.fieldRadius, fill: OverlayStyle.fieldFill, style: style) }
            }
            .help("点击修改文件夹名(键盘按 Tab)")
            .accessibilityLabel("文件夹名称")
            .accessibilityFocused($isAccessibilityFocused)
            .onAppear { isAccessibilityFocused = true }
    }
}
