import AppKit
import LaunchpadCore
import SwiftUI

/// 鼠标、触控板的处理。坐标均为面板内、左上原点。
extension OverlayModel {
    /// 按下后到松开前的状态
    enum Press {
        case item(ItemHit, start: CGPoint)
        case background(Hit, start: CGPoint)
        case panning(start: CGPoint, lastX: CGFloat, lastTime: TimeInterval, velocity: CGFloat)
        case dragging
        /// 按下后拖开了但不允许拖拽(搜索结果):松手什么也不做,相当于取消点击
        case cancelled
    }

    enum ItemHit {
        case grid(ItemLocation, LaunchItem)
        case folder(index: Int, appID: String, folderID: String)

        var itemID: String {
            switch self {
            case .grid(_, let item): item.id
            case .folder(_, let appID, _): LaunchItem.app(appID).id
            }
        }
    }

    enum Hit {
        /// 交给文本框(搜索框、文件夹名)
        case passthrough
        case item(ItemHit)
        case dot(Int)
        case folderDot(Int)
        case folderPanel
        case outsideFolder
        case background

        /// 按在空白处或页码点上拖动,可以像旧启动台一样直接拖着翻页
        var allowsPanning: Bool {
            switch self {
            case .background, .dot: true
            default: false
            }
        }
    }

    struct ScrollInput: Sendable {
        enum Phase: Sendable { case began, changed, ended, none }
        let deltaX: CGFloat
        let deltaY: CGFloat
        let isPrecise: Bool
        let phase: Phase
        let isMomentum: Bool
        let time: TimeInterval
    }

    struct ScrollState {
        var lastTime: TimeInterval = 0
        var velocity: CGFloat = 0
        var lastWheelFlip: TimeInterval = 0
        /// 本次手势累计的原始位移;阻尼只在换算成 pageOffset 时施加一次
        var rawOffset: CGFloat = 0
        var folderOffset: CGFloat = 0
    }

    static let dragThreshold: CGFloat = 5
    static let wheelCooldown = 0.35
    /// 松手前停顿超过这么久,就不算「甩」,速度归零
    static let flingTimeout = 0.08

    // MARK: 命中

    func hitTest(_ point: CGPoint) -> Hit {
        if let folder = displayedFolder {
            let folderMetrics = folderMetrics(for: folder)
            guard folderMetrics.panelRect.contains(point) else { return .outsideFolder }
            if folderMetrics.titleRect.contains(point) { return .passthrough }
            if let dot = folderMetrics.dotRects().firstIndex(where: { $0.contains(point) }) { return .folderDot(dot) }
            if let local = folderMetrics.itemIndex(at: point) {
                let index = folderMetrics.folderIndex(page: folderPage, local: local)
                if let appID = folder.appIDs[safe: index] {
                    return .item(.folder(index: index, appID: appID, folderID: folder.id))
                }
            }
            return .folderPanel
        }
        let metrics = metrics
        if metrics.searchFieldRect.insetBy(dx: -6, dy: -6).contains(point) { return .passthrough }
        if let dot = metrics.dotRects(pageCount: pageCount).firstIndex(where: { $0.contains(point) }) { return .dot(dot) }
        if let index = metrics.itemIndex(at: point), let item = displayedPages[safe: currentPage]?[safe: index] {
            return .item(.grid(ItemLocation(page: currentPage, index: index), item))
        }
        return .background
    }

    // MARK: 鼠标

    /// 返回 false 表示不拦截,事件继续交给 SwiftUI(文本框)
    /// 文件夹开着时双击的第二下一律忽略:第一下刚打开的面板正盖在光标下(或光标在面板外),
    /// 不能让它打开里面的 App、立刻关掉文件夹或进入改名
    func mouseDown(at point: CGPoint, clickCount: Int = 1) -> Bool {
        var hit = hitTest(point)
        // 文本框(改名中双击选词)照常交给系统
        if case .passthrough = hit {
            press = nil
            return false
        }
        if clickCount > 1, displayedFolder != nil { hit = .folderPanel }
        // 点在文件夹名以外的地方即结束改名
        if isEditingFolderName { endFolderRename() }
        if case .item(let itemHit) = hit {
            press = .item(itemHit, start: point)
            pressedItemID = itemHit.itemID
        } else {
            press = .background(hit, start: point)
        }
        return true
    }

    func mouseDragged(to point: CGPoint, time: TimeInterval) {
        switch press {
        case .item(let hit, let start):
            guard point.distance(to: start) > Self.dragThreshold else { return }
            if isSearching {
                press = .cancelled
                pressedItemID = nil
            } else {
                beginDrag(hit, at: point, start: start)
            }
        case .background(let hit, let start):
            guard displayedFolder == nil, hit.allowsPanning, point.distance(to: start) > Self.dragThreshold else { return }
            press = .panning(start: start, lastX: point.x, lastTime: time, velocity: 0)
            pageOffset = Paging.resisted(offset: point.x - start.x, current: currentPage, pageCount: pageCount)
        case .panning(let start, let lastX, let lastTime, let velocity):
            let dt = time - lastTime
            let newVelocity = dt > 0 ? (point.x - lastX) / dt : velocity
            press = .panning(start: start, lastX: point.x, lastTime: time, velocity: newVelocity)
            pageOffset = Paging.resisted(offset: point.x - start.x, current: currentPage, pageCount: pageCount)
        case .dragging:
            updateDrag(to: point)
        case .cancelled, nil:
            break
        }
    }

    func mouseUp(at point: CGPoint, time: TimeInterval = .infinity) {
        let finished = press
        press = nil
        pressedItemID = nil
        switch finished {
        case .item(.grid(_, let item), _):
            activate(item)
        case .item(.folder(_, let appID, _), _):
            launch(appID)
        case .background(let hit, _):
            click(hit)
        case .panning(_, _, let lastTime, let velocity):
            snapPage(velocity: time - lastTime > Self.flingTimeout ? 0 : velocity)
        case .dragging:
            endDrag()
        case .cancelled, nil:
            break
        }
    }

    private func click(_ hit: Hit) {
        switch hit {
        case .dot(let page): goToPage(page)
        case .folderDot(let page): goToFolderPage(page)
        case .outsideFolder: closeFolder()
        case .background: requestDismiss()
        default: break
        }
    }

    private func snapPage(velocity: CGFloat) {
        goToPage(Paging.targetPage(
            current: currentPage, offset: pageOffset, width: containerSize.width,
            velocity: velocity, pageCount: pageCount
        ))
    }

    // MARK: 触控板 / 滚轮

    func scroll(_ input: ScrollInput) {
        guard drag == nil, !input.isMomentum else { return }
        let delta = abs(input.deltaX) >= abs(input.deltaY) ? input.deltaX : input.deltaY
        if let folder = displayedFolder {
            scrollFolder(folder, delta: delta, input: input)
            return
        }
        guard input.isPrecise, input.phase != .none else {
            if let step = wheelStep(delta, time: input.time) { goToPage(currentPage + step) }
            return
        }
        switch input.phase {
        case .began:
            scrollState.lastTime = input.time
            scrollState.velocity = 0
            scrollState.rawOffset = 0
            pageOffset = 0
        case .changed:
            let dt = input.time - scrollState.lastTime
            if dt > 0 { scrollState.velocity = delta / dt }
            scrollState.lastTime = input.time
            scrollState.rawOffset += delta
            pageOffset = Paging.resisted(offset: scrollState.rawOffset, current: currentPage, pageCount: pageCount)
        case .ended:
            snapPage(velocity: input.time - scrollState.lastTime > Self.flingTimeout ? 0 : scrollState.velocity)
        case .none:
            break
        }
    }

    /// 普通鼠标滚轮:一格翻一页,带冷却。返回翻页方向。
    private func wheelStep(_ delta: CGFloat, time: TimeInterval) -> Int? {
        guard abs(delta) >= 0.5, time - scrollState.lastWheelFlip > Self.wheelCooldown else { return nil }
        scrollState.lastWheelFlip = time
        return delta < 0 ? 1 : -1
    }

    private func scrollFolder(_ folder: Folder, delta: CGFloat, input: ScrollInput) {
        let folderMetrics = folderMetrics(for: folder)
        guard folderMetrics.pageCount > 1 else {
            folderPageOffset = 0
            return
        }
        guard input.isPrecise, input.phase != .none else {
            if let step = wheelStep(delta, time: input.time) { goToFolderPage(folderPage + step) }
            return
        }
        // 与主网格一样跟手:累计原始位移,阻尼只施加一次
        switch input.phase {
        case .began:
            scrollState.folderOffset = 0
            folderPageOffset = 0
        case .changed:
            scrollState.folderOffset += delta
            folderPageOffset = Paging.resisted(offset: scrollState.folderOffset, current: folderPage, pageCount: folderMetrics.pageCount)
        case .ended:
            goToFolderPage(Paging.targetPage(
                current: folderPage, offset: scrollState.folderOffset, width: folderMetrics.panelRect.width,
                velocity: 0, pageCount: folderMetrics.pageCount
            ))
            scrollState.folderOffset = 0
        case .none:
            break
        }
    }
}
