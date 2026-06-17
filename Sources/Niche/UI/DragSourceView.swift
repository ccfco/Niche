import SwiftUI
import AppKit

/// 拖出源 + cell 左键接管(spec §4.5)。
///
/// SwiftUI `.onDrag` 拿不到 `NSDraggingSession` 的 willBegin/ended 回调,无法在拖出期间抑制
/// auto-hide、也无法实现"拖出即走"。改用 AppKit `NSDraggingSource`。
///
/// 关键约束:要接 `mouseDragged` 发起拖拽,必须认领 `mouseDown` —— 这会吞掉 SwiftUI 的
/// `.onTapGesture`。所以本视图**接管 cell 的整个左键**(单击选中 / 双击激活 / 拖拽),右键(及
/// control-左键)`hitTest` 返回 nil 透给下层 `RightClickCatcher`。拖真实 file URL(不用 promise)。
struct DragSourceView: NSViewRepresentable {
    let url: URL
    var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onActivate: () -> Void = {}
    var onDragBegin: () -> Void = {}
    var onDragEnd: () -> Void = {}
    /// 拖出时实际携带的 URL 集合(多选:拖已选中项 → 拖整组;拖未选中项 → 仅该项)。
    /// 闭包延迟到拖拽发起时求值,读最新选中态(#5 多选拖出)。空则回退 [url]。
    var dragURLs: () -> [URL] = { [] }
    /// 本项当前是否为唯一选中项 —— 慢速单击重命名的前置条件(Finder:点已选中项才进重命名)。
    var isSoleSelection: () -> Bool = { false }
    /// 慢速单击触发就地重命名(点中唯一选中项,且双击间隔内无第二击)。
    var onBeginRename: () -> Void = {}
    /// 文件名文字在本格坐标系(左上原点)内的 frame —— 慢速单击只在命中此区域才进重命名
    /// (Finder:点图标图片只选中,点文字才改名)。`.zero` = 整格不触发。
    var renameHitRect: () -> CGRect = { .zero }
    /// 待触发重命名代次(model.renameArmToken):schedule 时捕获,触发前比对 —— 不等(面板已收起)
    /// 即放弃,防延迟回调在面板收起后置 renamingItemID 泄漏 .renaming 抑制(Codex review)。
    var armToken: () -> Int = { 0 }

    func makeNSView(context: Context) -> DragSourceNSView {
        let v = DragSourceNSView()
        v.configure(url: url, onClick: onClick, onActivate: onActivate,
                    onDragBegin: onDragBegin, onDragEnd: onDragEnd, dragURLs: dragURLs,
                    isSoleSelection: isSoleSelection, onBeginRename: onBeginRename,
                    renameHitRect: renameHitRect, armToken: armToken)
        return v
    }

    func updateNSView(_ nsView: DragSourceNSView, context: Context) {
        nsView.configure(url: url, onClick: onClick, onActivate: onActivate,
                         onDragBegin: onDragBegin, onDragEnd: onDragEnd, dragURLs: dragURLs,
                         isSoleSelection: isSoleSelection, onBeginRename: onBeginRename,
                         renameHitRect: renameHitRect, armToken: armToken)
    }

    /// view 被移除时兜底:若拖拽仍在进行,解除 auto-hide 抑制(防 endedAt 不触达导致泄漏)。
    static func dismantleNSView(_ nsView: DragSourceNSView, coordinator: Coordinator) {
        nsView.cleanupIfDragging()
    }
}

final class DragSourceNSView: NSView, NSDraggingSource {
    private var url: URL?
    private var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
    private var onActivate: () -> Void = {}
    private var onDragBegin: () -> Void = {}
    private var onDragEnd: () -> Void = {}
    private var dragURLs: () -> [URL] = { [] }
    private var isSoleSelection: () -> Bool = { false }
    private var onBeginRename: () -> Void = {}
    private var renameHitRect: () -> CGRect = { .zero }
    private var armToken: () -> Int = { 0 }
    /// scheduleRename 时捕获的代次,timer 触发时比对(不等=面板已收起→放弃)。
    private var scheduledArmToken = 0

    private var mouseDownPoint: NSPoint?
    private var didStartDrag = false
    /// 拖拽是否进行中(willBegin 到 ended 之间)。用于 view 被移除时兜底解除 auto-hide 抑制。
    private var dragInProgress = false
    /// 慢速单击重命名的延迟计时器:点中唯一选中项后等一个双击间隔,期间无第二击(双击打开)/
    /// 无 mouseDown(拖拽)才触发重命名。任何后续点击/拖拽/移除都会取消它。
    private var renameTimer: Timer?

    func configure(url: URL, onClick: @escaping (NSEvent.ModifierFlags) -> Void, onActivate: @escaping () -> Void,
                   onDragBegin: @escaping () -> Void, onDragEnd: @escaping () -> Void,
                   dragURLs: @escaping () -> [URL] = { [] },
                   isSoleSelection: @escaping () -> Bool = { false },
                   onBeginRename: @escaping () -> Void = {},
                   renameHitRect: @escaping () -> CGRect = { .zero },
                   armToken: @escaping () -> Int = { 0 }) {
        self.url = url
        self.onClick = onClick
        self.onActivate = onActivate
        self.onDragBegin = onDragBegin
        self.onDragEnd = onDragEnd
        self.dragURLs = dragURLs
        self.isSoleSelection = isSoleSelection
        self.onBeginRename = onBeginRename
        self.renameHitRect = renameHitRect
        self.armToken = armToken
    }

    /// 只认领左键;右键 / control-左键返回 nil,透给下层 RightClickCatcher 弹自拼菜单。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            if event.modifierFlags.contains(.control) { return nil }   // control-左键当右键
            return super.hitTest(point)
        default:
            return nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        cancelRenameTimer()   // 新一轮按下:取消上一次单击挂起的重命名(双击第二击 / 拖拽起手都经此)
        mouseDownPoint = event.locationInWindow
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag, let url, let start = mouseDownPoint else { return }
        let dx = event.locationInWindow.x - start.x
        let dy = event.locationInWindow.y - start.y
        guard (dx * dx + dy * dy) > 16 else { return }   // 阈值 ~4pt,区分点击与拖拽
        didStartDrag = true

        // 多选拖出:拖整组(本项在选中集内时)。空回退本项。各 URL 一个 NSDraggingItem,
        // 本项的角标在原 bounds,其余略微错位堆叠(Finder 拖多文件的层叠观感)。
        let urls = { let u = dragURLs(); return u.isEmpty ? [url] : u }()
        let items: [NSDraggingItem] = urls.enumerated().map { offset, dragURL in
            let item = NSDraggingItem(pasteboardWriter: dragURL as NSURL)
            let frame = dragURL == url
                ? bounds
                : bounds.offsetBy(dx: CGFloat(offset) * 4, dy: CGFloat(offset) * -4)
            item.setDraggingFrame(frame, contents: NSWorkspace.shared.icon(forFile: dragURL.path))
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard !didStartDrag else { return }   // 拖拽过就不是点击
        cancelRenameTimer()                   // 双击的第二击经此取消第一击挂起的重命名
        // 双击激活;单击带修饰键交回上层(⌘ 离散 / ⇧ 区间 / 普通单选)。
        if event.clickCount >= 2 {
            onActivate()
        } else if event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty
                    && isSoleSelection() && pointInNameLabel(event) {
            // 慢速单击重命名(Finder 语义):点中已是唯一选中项、且落在文件名文字上的无修饰单击 →
            // 等一个双击间隔,期间无双击/拖拽则进就地重命名。系统已用 clickCount 把"快(打开)/慢
            //(重命名)"分开,这里只补"延迟兜底",避免点已选中项想双击打开时被抢成重命名。
            scheduleRename()
        } else {
            onClick(event.modifierFlags)
        }
    }

    /// 点击是否落在文件名文字区域。renameHitRect 是 SwiftUI 本格坐标(左上原点);事件点经
    /// `convert(from: nil)` 得 AppKit 本视图坐标(默认左下原点),按视图高翻转 y 再比对。
    /// overlay 填满整格,故本视图 bounds 与本格坐标系同原点同尺寸。
    private func pointInNameLabel(_ event: NSEvent) -> Bool {
        let rect = renameHitRect()
        guard !rect.isEmpty else { return false }
        let local = convert(event.locationInWindow, from: nil)
        let topLeft = CGPoint(x: local.x, y: bounds.height - local.y)
        return rect.contains(topLeft)
    }

    private func scheduleRename() {
        scheduledArmToken = armToken()   // 捕获当前代次:面板若在延迟内收起会自增,触发时比对失效
        renameTimer = Timer.scheduledTimer(withTimeInterval: NSEvent.doubleClickInterval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.renameTimer = nil
            // 触发时二次确认仍是唯一选中本项:延迟期内若点了别的项,那项是另一个 view、取消不了本
            // timer(各 view 只取消自己的),靠这里兜住——选中已变 → 放弃重命名。
            guard self.isSoleSelection() else { return }
            // 面板已收起(代次自增)→ 放弃:否则会在隐藏后置 renamingItemID,泄漏 .renaming 抑制。
            guard self.armToken() == self.scheduledArmToken else { return }
            self.onBeginRename()
        }
    }

    private func cancelRenameTimer() {
        renameTimer?.invalidate()
        renameTimer = nil
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // 拖出到其它 app:复制/移动由目标与修饰键决定;拖回自身无操作。
        context == .outsideApplication ? [.copy, .move] : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        dragInProgress = true
        onDragBegin()
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        dragInProgress = false
        onDragEnd()
    }

    /// view 被 SwiftUI 移除时(拖拽中 cell 因目录刷新/重命名态切换被回收),endedAt 可能不触达 →
    /// 兜底解除 .draggingOut 抑制,防 auto-hide 永久泄漏(end 幂等,重复调用安全)。
    func cleanupIfDragging() {
        cancelRenameTimer()   // view 被回收(目录刷新/切重命名态):挂起的重命名计时器一并作废
        guard dragInProgress else { return }
        dragInProgress = false
        onDragEnd()
    }
}
