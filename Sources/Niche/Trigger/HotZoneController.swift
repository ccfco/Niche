import AppKit

/// 触发热区控制器:把 HotZoneWindow 的两条路径(hover / drag)归一成"请求呼出"信号。
///
/// - 空手 hover 经 HoverIntent 延迟防误触后才确认(spec §4.2)。
/// - 拖着文件 draggingEntered 立即确认(用户在等它接住,spec §4.2:更快 spring 迎上)。
@MainActor
final class HotZoneController {
    private let window = HotZoneWindow()
    private let hoverIntent: HoverIntent

    /// 确认呼出。`draggingFile=true` 表示是拖拽迎上(宿主可用更快 spring)。
    var onTrigger: ((_ draggingFile: Bool) -> Void)?

    init(hoverDelay: TimeInterval = 0.18) {
        hoverIntent = HoverIntent(delay: hoverDelay)
        hoverIntent.onConfirmed = { [weak self] in self?.onTrigger?(false) }

        window.onHoverEnter = { [weak self] in self?.hoverIntent.enter() }
        window.onHoverExit = { [weak self] in self?.hoverIntent.exit() }
        window.onDragEntered = { [weak self] in
            self?.hoverIntent.exit()       // 拖拽优先,取消正在计时的空手 hover
            self?.onTrigger?(true)
        }
    }

    /// 把热区贴到给定屏的刘海/回退几何上。
    func place(on resolution: NotchGeometry.Resolution) {
        window.place(at: NotchGeometry.hotZoneRect(from: resolution))
    }
}
