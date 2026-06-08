import AppKit

/// 覆盖刘海热区的极小透明常驻窗口,只承载**拖着文件迎上**这一条触发路径。
///
/// LSUIElement app 平时无窗口,不会凭空收到 notch 区域的 drag 事件 —— 需常驻一个透明 ordered
/// window 注册为 `NSDraggingDestination`:系统拖拽时 AppKit 把拖拽路由给已注册 pasteboard
/// 类型的窗口,`draggingEntered` 进入即触发展开。
///
/// **空手 hover 不走这里**:它改由 `HotZoneController` 的全局鼠标位置监听 + 几何判断处理
/// (透明窗口的 NSTrackingArea 在 statusBar 层易被系统菜单栏窗口盖住、收不到 mouseEntered,
/// 是 hover 失效的根因)。
///
/// 窗口透明、不挡视觉、不抢焦点;collectionBehavior 适配 Spaces / 全屏。
@MainActor
final class HotZoneWindow: NSPanel {
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

/// 热区内容视图:只承载 NSDraggingDestination(拖着文件迎上)。透明、不绘制。
private final class HotZoneView: NSView {
    private weak var owner: HotZoneWindow?

    init(owner: HotZoneWindow) {
        self.owner = owner
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        owner?.onDragEntered?()
        // 仅作"触发展开"的落点;真正 drop 执行在展开后的网格(spec §4.5 注②)。
        return []
    }
}
