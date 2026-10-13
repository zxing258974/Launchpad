import LaunchpadCore
import SwiftUI

/// 全屏启动台。所有元素按 `GridMetrics` 算好的绝对位置摆放,与点击命中判断同源。
struct LaunchpadView: View {
    @Bindable var model: OverlayModel
    @FocusState private var focus: Field?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    enum Field: Hashable { case search, folderName }

    var body: some View {
        let metrics = model.metrics
        let folder = model.displayedFolder
        let style = OverlayStyle(contrast: contrast)
        ZStack(alignment: .topLeading) {
            Color.black.opacity(model.effectiveDim + style.extraDim)

            PagesLayer(model: model, metrics: metrics)
                .blur(radius: folder == nil ? 0 : OverlayStyle.backgroundBlur)
                .opacity(folder == nil ? 1 : OverlayStyle.backgroundFade)
                .scaleEffect(model.isShown || reduceMotion ? 1 : OverlayStyle.enterScale)
                .opacity(model.isShown ? 1 : 0)
                .accessibilityHidden(folder != nil)

            if model.isSearching && model.searchResultIDs.isEmpty {
                Text("无结果")
                    .font(OverlayStyle.emptyStateFont)
                    .foregroundStyle(.white.opacity(OverlayStyle.primaryText))
                    .position(x: metrics.containerSize.width / 2, y: metrics.gridRect.midY)
            }

            SearchField(model: model, focus: $focus, style: style)
                .position(x: metrics.searchFieldRect.midX, y: metrics.searchFieldRect.midY)
                .opacity(model.isShown && folder == nil ? 1 : 0)
                .accessibilityHidden(folder != nil)
                // 读屏先到搜索框,再到图标
                .accessibilitySortPriority(1)

            PageDots(current: model.currentPage, rects: metrics.dotRects(pageCount: model.pageCount), style: style) {
                model.goToPage($0)
            }
            .opacity(model.isShown && folder == nil ? 1 : 0)
            .accessibilityHidden(folder != nil)

            if let folder {
                FolderPanel(model: model, folder: folder, metrics: model.folderMetrics(for: folder), focus: $focus, style: style)
                    // 同旧启动台:从文件夹图标所在处展开
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.6, anchor: model.folderOrigin(of: folder.id)).combined(with: .opacity))
            }

            if let drag = model.drag {
                DragGhost(model: model, item: drag.item, grabOffset: drag.grabOffset, size: metrics.iconSize)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: metrics.containerSize.width, height: metrics.containerSize.height)
        .environment(\.colorScheme, .dark)
        .onChange(of: model.searchFocusRequest, initial: true) { focus = .search }
        .onChange(of: model.folderNameFocusRequest) { focus = .folderName }
        .onChange(of: focus) { _, newValue in model.isEditingFolderName = newValue == .folderName }
        .onChange(of: model.isEditingFolderName) { _, editing in
            if !editing, focus == .folderName { focus = .search }
        }
    }
}

/// 当前页及左右相邻页横向排开,按当前页和手势位移平移(远处的页不建视图)
struct PagesLayer: View {
    let model: OverlayModel
    let metrics: GridMetrics

    var body: some View {
        let pages = model.displayedPages
        let current = model.currentPage
        let width = metrics.containerSize.width
        let visible = pages.indices.filter { abs($0 - current) <= 1 }
        ZStack(alignment: .topLeading) {
            ForEach(visible, id: \.self) { pageIndex in
                PageView(model: model, metrics: metrics, items: pages[pageIndex], pageIndex: pageIndex)
                    .offset(x: CGFloat(pageIndex - current) * width + model.pageOffset)
                    // 读屏只读当前页,左右预备页不进无障碍树
                    .accessibilityHidden(pageIndex != current)
            }
        }
        .frame(width: width, height: metrics.containerSize.height, alignment: .topLeading)
    }
}

struct PageView: View {
    let model: OverlayModel
    let metrics: GridMetrics
    let items: [LaunchItem]
    let pageIndex: Int

    var body: some View {
        let draggedID = model.drag?.item.id
        let mergeTargetID = model.drag?.mergeTargetID
        let pressedID = model.pressedItemID
        let selection = model.selection
        let canRearrange = !model.isSearching
        ZStack(alignment: .topLeading) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                ItemCell(
                    item: item,
                    model: model,
                    iconSize: metrics.iconSize,
                    cellWidth: metrics.cellSize.width,
                    labelWidth: metrics.labelWidth,
                    highlightSize: metrics.itemRect(at: index).size,
                    cellHeight: metrics.cellSize.height,
                    canMoveBack: canRearrange && pageIndex > 0,
                    canMoveForward: canRearrange,
                    isSelected: selection == ItemLocation(page: pageIndex, index: index),
                    isPressed: item.id == pressedID,
                    isMergeTarget: item.id == mergeTargetID,
                    isPlaceholder: item.id == draggedID
                )
                .position(metrics.cellCenter(at: index))
            }
        }
        .frame(width: metrics.containerSize.width, height: metrics.containerSize.height, alignment: .topLeading)
    }
}

/// 跟着光标走的图标。只有它读 `dragLocation`,鼠标每动一下只重绘这一个视图。
struct DragGhost: View {
    let model: OverlayModel
    let item: LaunchItem
    let grabOffset: CGSize
    let size: CGFloat

    var body: some View {
        let location = model.dragLocation
        ItemIcon(item: item, model: model, size: size)
            .scaleEffect(OverlayStyle.ghostScale)
            .opacity(OverlayStyle.ghostOpacity)
            .shadow(color: OverlayStyle.liftShadow, radius: OverlayStyle.ghostShadowRadius, y: OverlayStyle.ghostShadowRadius / 2)
            .position(x: location.x - grabOffset.width, y: location.y - grabOffset.height)
            .allowsHitTesting(false)
    }
}

/// 搜索框:空着时放大镜和「搜索」居中、光标就在它们旁边(同旧启动台);开始输入后靠左铺满,右侧出现清除按钮。
/// 两种状态是同一个 TextField,只换外面的排布,输入时不会丢焦点。
struct SearchField: View {
    @Bindable var model: OverlayModel
    var focus: FocusState<LaunchpadView.Field?>.Binding
    let style: OverlayStyle

    var body: some View {
        let isEmpty = model.query.isEmpty
        HStack(spacing: 6) {
            if isEmpty { Spacer(minLength: 0) }
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(isEmpty ? style.placeholderText : style.secondaryText))
                .accessibilityHidden(true)
            TextField("", text: Binding(get: { model.query }, set: { model.setQuery($0) }),
                      prompt: Text("搜索").foregroundStyle(.white.opacity(style.placeholderText)))
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .fixedSize(horizontal: isEmpty, vertical: false)
                .focused(focus, equals: .search)
                .onSubmit { model.activateSelection() }
                .accessibilityLabel("搜索 App")
            if isEmpty {
                Spacer(minLength: 0)
            } else {
                Button {
                    model.setQuery("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(style.secondaryText))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("清除搜索")
                .accessibilityLabel("清除搜索")
            }
        }
        .font(OverlayStyle.fieldFont)
        .padding(.horizontal, 10)
        .frame(width: GridMetrics.searchFieldSize.width, height: GridMetrics.searchFieldSize.height)
        .translucentPlate(radius: OverlayStyle.fieldRadius, fill: OverlayStyle.fieldFill, style: style)
    }
}

/// 页码点:一行小圆点放在点阵自己的范围里(读屏框也只框住点阵),读屏下可上下滑动翻页
struct PageDots: View {
    let current: Int
    let rects: [CGRect]
    let style: OverlayStyle
    let goTo: (Int) -> Void

    var body: some View {
        if let first = rects.first, let last = rects.last {
            let bounds = first.union(last)
            HStack(spacing: GridMetrics.dotSpacing - GridMetrics.dotDiameter) {
                ForEach(rects.indices, id: \.self) { index in
                    Circle()
                        .fill(.white.opacity(index == current ? OverlayStyle.dotActive : style.dotInactive))
                        .frame(width: GridMetrics.dotDiameter, height: GridMetrics.dotDiameter)
                }
            }
            .animation(.easeOut(duration: 0.2), value: current)
            .frame(width: bounds.width, height: bounds.height)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("页码")
            .accessibilityValue("第 \(current + 1) 页,共 \(rects.count) 页")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: goTo(current + 1)
                case .decrement: goTo(current - 1)
                @unknown default: break
                }
            }
            .position(x: bounds.midX, y: bounds.midY)
        }
    }
}
