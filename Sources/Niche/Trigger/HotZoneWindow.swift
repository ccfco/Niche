import AppKit

/// 覆盖刘海热区的极小透明常驻窗口(spec §4.2 关键:LSUIElement app 平时无窗口,不会凭空
/// 收到 notch 区域的 hover/drag 事件 —— 需常驻一个透明 ordered window 承载两类触发)。
///
/// 两条触发路径分离(spec §4.2),都实现在内容视图 HotZoneView(NSView 才是 canonical 的
/// tracking + dragging destination):
/// - **空手 hover** 走 `NSTrackingArea`(经 HoverIntent 延迟防误触)。
/// - **拖着文件迎上** 走 Drag&Drop:系统拖拽时普通 mouse tracking 不可靠,AppKit 把拖拽路由
///   给已注册 pasteboard 类型的 `NSDraggingDestination`,`draggingEntered` 进入即触发。
///
/// 窗口透明、不挡视觉、不抢焦点;collectionBehavior 适配 Spaces / 全屏。
@MainActor
final class HotZoneWindow: NSPanel {
    var onHoverEnter: (() -> Void)?
    var onHoverExit: (() -> Void)?
    var onDragEntered: (() -> Void)?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = HotZoneView(owner: self)
    }

    override var canBecomeKey: Bool { false }   // 热区不抢焦点
    override var canBecomeMain: Bool { false }

    /// 把热区窗口移动/调整到给定矩形并保持可见。
    func place(at rect: NSRect) {
        setFrame(rect, display: true)
        orderFrontRegardless()
    }
}

/// 热区内容视图:承载 NSTrackingArea(空手 hover)+ NSDraggingDestination(拖着文件迎上)。
/// 透明、不绘制。
private final class HotZoneView: NSView {
    private weak var owner: HotZoneWindow?
    private var trackingArea: NSTrackingArea?

    init(owner: HotZoneWindow) {
        self.owner = owner
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { owner?.onHoverEnter?() }
    override func mouseExited(with event: NSEvent) { owner?.onHoverExit?() }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        owner?.onDragEntered?()
        // 仅作"触发展开"的落点;真正 drop 执行在展开后的网格(spec §4.5 注②)。
        return []
    }
}
