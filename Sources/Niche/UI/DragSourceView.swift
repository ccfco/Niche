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

    func makeNSView(context: Context) -> DragSourceNSView {
        let v = DragSourceNSView()
        v.configure(url: url, onClick: onClick, onActivate: onActivate,
                    onDragBegin: onDragBegin, onDragEnd: onDragEnd, dragURLs: dragURLs)
        return v
    }

    func updateNSView(_ nsView: DragSourceNSView, context: Context) {
        nsView.configure(url: url, onClick: onClick, onActivate: onActivate,
                         onDragBegin: onDragBegin, onDragEnd: onDragEnd, dragURLs: dragURLs)
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

    private var mouseDownPoint: NSPoint?
    private var didStartDrag = false
    /// 拖拽是否进行中(willBegin 到 ended 之间)。用于 view 被移除时兜底解除 auto-hide 抑制。
    private var dragInProgress = false

    func configure(url: URL, onClick: @escaping (NSEvent.ModifierFlags) -> Void, onActivate: @escaping () -> Void,
                   onDragBegin: @escaping () -> Void, onDragEnd: @escaping () -> Void,
                   dragURLs: @escaping () -> [URL] = { [] }) {
        self.url = url
        self.onClick = onClick
        self.onActivate = onActivate
        self.onDragBegin = onDragBegin
        self.onDragEnd = onDragEnd
        self.dragURLs = dragURLs
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
        // 双击激活;单击带修饰键交回上层(⌘ 离散 / ⇧ 区间 / 普通单选)。
        if event.clickCount >= 2 { onActivate() } else { onClick(event.modifierFlags) }
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
        guard dragInProgress else { return }
        dragInProgress = false
        onDragEnd()
    }
}
