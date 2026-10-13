import AppKit
import LaunchpadCore
import SwiftUI

/// 拖拽排序、拖进拖出文件夹、拖到屏幕边缘翻页。
///
/// 规则对齐旧启动台:悬停到别的格子一小会儿,图标让位;压在图标正中停住,目标高亮,
/// 松手合成文件夹;拖出文件夹面板,文件夹收起、继续在主网格里拖。
/// 任何时刻 `drag.preview` 都是松手会提交的排列,结束时直接提交它。
extension OverlayModel {
    static let reorderDelay = 0.12
    static let mergeDelay = 0.35
    static let edgeZone: CGFloat = 36
    static let edgeFirstDelay = 0.55
    static let edgeRepeatDelay = 0.8

    func beginDrag(_ hit: ItemHit, at point: CGPoint, start: CGPoint) {
        switch hit {
        case .grid(let location, let item):
            guard let removed = LayoutEngine.removing(itemID: item.id, from: catalog.layout) else { return }
            drag = .grid(
                item: item, base: DragSession.withBlankPage(removed.layout), target: location,
                capacity: metrics.capacity, grabOffset: offset(of: start, from: metrics.iconCenter(at: location.index))
            )
        case .folder(let index, let appID, let folderID):
            guard let folder = catalog.layout.folder(withID: folderID) else { return }
            let folderMetrics = folderMetrics(for: folder)
            let center = folderMetrics.iconCenter(at: index % folderMetrics.capacity)
            drag = .folder(appID: appID, in: folder, grabOffset: offset(of: start, from: center))
        }
        press = .dragging
        pressedItemID = nil
        selection = nil
        updateDrag(to: point)
    }

    private func offset(of point: CGPoint, from center: CGPoint) -> CGSize {
        CGSize(width: point.x - center.x, height: point.y - center.y)
    }

    func updateDrag(to point: CGPoint) {
        guard let mode = drag?.mode else { return }
        dragLocation = point
        switch mode {
        case .grid: updateGridDrag(at: point)
        case .folder(let folderID): updateFolderDrag(at: point, folderID: folderID)
        }
    }

    // MARK: 主网格

    private func updateGridDrag(at point: CGPoint) {
        updateEdgeFlip(at: point)
        guard let session = drag, let index = metrics.index(at: point) else {
            // 离开网格(移到搜索框、页码点、两侧空白)就不再算「停在图标上」
            cancelReorder()
            cancelMerge()
            clearMergeTarget()
            return
        }
        let previewPage = session.preview.page(at: currentPage)
        if session.item.appID != nil, let target = previewPage[safe: index], target.id != session.item.id,
           metrics.isOverIconCenter(point, index: index) {
            scheduleMerge(into: target.id)
            return
        }
        cancelMerge()
        clearMergeTarget()
        let desired = ItemLocation(page: currentPage, index: insertionIndex(at: point, cell: index, in: session))
        guard desired != session.target else {
            cancelReorder()
            return
        }
        guard desired != pendingReorderTarget else { return }
        cancelReorder()
        pendingReorderTarget = desired
        pendingReorder = delayed(Self.reorderDelay) { [weak self] in self?.placeDraggedItem(at: desired) }
    }

    /// 悬停在某个图标左半边就插到它前面,右半边插到它后面(按去掉被拖项后的排列算)。
    /// 光标从旁边滑向图标正中时,目标图标不会先被挤开,停稳就能合成文件夹。
    private func insertionIndex(at point: CGPoint, cell index: Int, in session: DragSession) -> Int {
        let basePage = session.base.page(at: currentPage)
        guard let hovered = session.preview.page(at: currentPage)[safe: index] else { return basePage.count }
        guard hovered.id != session.item.id,
              let baseIndex = basePage.firstIndex(where: { $0.id == hovered.id }) else {
            return session.target?.page == currentPage ? session.target?.index ?? index : min(index, basePage.count)
        }
        return point.x < metrics.iconCenter(at: index).x ? baseIndex : baseIndex + 1
    }

    private func placeDraggedItem(at target: ItemLocation) {
        guard var session = drag, session.mode == .grid else { return }
        session.place(at: target, capacity: metrics.capacity)
        pendingReorderTarget = nil
        withAnimation(Motion.reorder) { drag = session }
    }

    private func scheduleMerge(into targetID: String) {
        cancelReorder()
        guard drag?.mergeTargetID != targetID, pendingMergeID != targetID else { return }
        cancelMerge()
        clearMergeTarget()
        pendingMergeID = targetID
        pendingMerge = delayed(Self.mergeDelay) { [weak self] in
            guard let self else { return }
            pendingMergeID = nil
            withAnimation(Motion.mergeHighlight) { drag?.mergeTargetID = targetID }
        }
    }

    private func clearMergeTarget() {
        guard drag?.mergeTargetID != nil else { return }
        withAnimation(Motion.highlightOff) { drag?.mergeTargetID = nil }
    }

    // MARK: 边缘翻页

    private func updateEdgeFlip(at point: CGPoint) {
        let direction = point.x < Self.edgeZone ? -1 : (point.x > containerSize.width - Self.edgeZone ? 1 : 0)
        guard direction != 0 else {
            cancelEdgeFlip()
            return
        }
        guard direction != edgeFlipDirection else { return }
        cancelEdgeFlip()
        edgeFlipDirection = direction
        edgeFlip = Task { @MainActor [weak self] in
            var delay = Self.edgeFirstDelay
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                flipWhileDragging(direction)
                delay = Self.edgeRepeatDelay
            }
        }
    }

    /// 翻到相邻页,并先把被拖项放到新页末尾(满页就占最后一格,原末格往后挤),悬停到格子上再细调
    private func flipWhileDragging(_ direction: Int) {
        guard let session = drag, session.mode == .grid else { return }
        let newPage = currentPage + direction
        guard (0..<pageCount).contains(newPage) else { return }
        cancelReorder()
        cancelMerge()
        clearMergeTarget()
        goToPage(newPage)
        let end = min(session.base.page(at: newPage).count, metrics.capacity - 1)
        placeDraggedItem(at: ItemLocation(page: newPage, index: end))
    }

    // MARK: 文件夹内

    private func updateFolderDrag(at point: CGPoint, folderID: String) {
        guard let session = drag, let folder = displayedFolder, let appID = session.item.appID else { return }
        let folderMetrics = folderMetrics(for: folder)
        guard folderMetrics.panelRect.insetBy(dx: -24, dy: -24).contains(point) else {
            dragOutOfFolder(folderID: folderID, at: point)
            return
        }
        guard let local = folderMetrics.index(at: point) else {
            cancelReorder()
            return
        }
        let desired = min(folderMetrics.folderIndex(page: folderPage, local: local), session.folderBase.count)
        guard desired != session.folderPreview.firstIndex(of: appID) else {
            cancelReorder()
            return
        }
        guard desired != pendingFolderReorderIndex else { return }
        cancelReorder()
        pendingFolderReorderIndex = desired
        pendingReorder = delayed(Self.reorderDelay) { [weak self] in
            guard let self, var current = drag else { return }
            var order = current.folderBase
            order.insert(appID, at: min(desired, order.count))
            current.folderPreview = order
            pendingFolderReorderIndex = nil
            withAnimation(Motion.reorder) { drag = current }
        }
    }

    /// 拖出文件夹面板:文件夹收起,转为主网格拖拽,先放到当前页末尾(此时还没落盘,Esc 可整体撤销)
    private func dragOutOfFolder(folderID: String, at point: CGPoint) {
        guard let session = drag, let appID = session.item.appID else { return }
        cancelTimers()
        commitFolderName()
        let base = DragSession.withBlankPage(LayoutEngine.removingApp(appID, fromFolder: folderID, in: catalog.layout))
        let end = min(base.page(at: currentPage).count, metrics.capacity - 1)
        withAnimation(Motion.folder) {
            openFolderID = nil
            drag = .grid(
                item: .app(appID), base: base, target: ItemLocation(page: currentPage, index: end),
                capacity: metrics.capacity, grabOffset: session.grabOffset
            )
        }
        updateGridDrag(at: point)
    }

    // MARK: 结束

    func endDrag() {
        cancelTimers()
        guard let session = drag else { return }
        switch session.mode {
        case .grid:
            catalog.commit(mergedLayout(for: session) ?? session.preview)
        case .folder(let folderID):
            if let folder = catalog.layout.folder(withID: folderID) {
                catalog.commit(LayoutEngine.replacingFolder(folder.with(appIDs: session.folderPreview), in: catalog.layout))
            }
        }
        // 提交时空页会被清掉,页码可能前移:跟着被拖的图标(或它所在的文件夹)走
        let landed = session.item.appIDs.first.flatMap(catalog.layout.page(containingApp:)) ?? currentPage
        withAnimation(Motion.reorder) {
            drag = nil
            currentPage = landed
        }
    }

    /// 停在别的图标正中松手:合成文件夹(或加进已有文件夹)
    private func mergedLayout(for session: DragSession) -> LaunchLayout? {
        guard let mergeID = session.mergeTargetID, let appID = session.item.appID else { return nil }
        let categories = ((catalog.layout.item(withID: mergeID)?.appIDs ?? []) + [appID]).map { catalog.apps[$0]?.category }
        return LayoutEngine.merging(
            appID: appID, into: mergeID, in: session.base,
            newFolderID: UUID().uuidString, folderName: FolderNaming.name(forCategories: categories)
        )
    }

    func cancelDrag() {
        cancelTimers()
        press = nil
        withAnimation(Motion.reorder) { drag = nil }
    }
}
