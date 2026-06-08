import AppKit

/// 触发热区控制器:把"空手 hover"与"拖着文件迎上"两条路径归一成"请求呼出"信号。
///
/// **hover 命中改用全局鼠标位置监听 + 几何判断**(不再依赖透明热区窗口的 NSTrackingArea ——
/// 它在 statusBar 层易被系统菜单栏窗口盖住、收不到 mouseEntered,是 hover 失效的根因)。
/// 全局监听不受窗口层级/遮挡影响,是 Dock 自动隐藏等的稳妥做法。
/// 拖拽迎上仍走热区窗口的 NSDraggingDestination(全局鼠标监听拿不到拖拽 session)。
@MainActor
final class HotZoneController {
    private let window = HotZoneWindow()
    private let hoverIntent: HoverIntent

    /// 确认呼出。`draggingFile=true` 表示拖拽迎上(宿主可用更快 spring)。
    var onTrigger: ((_ draggingFile: Bool) -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// 命中矩形(全局坐标,原点左下)。鼠标进入即起 hover intent。
    private var hotZoneRect: CGRect = .zero
    private var insideHotZone = false

    init(hoverDelay: TimeInterval = 0.18) {
        hoverIntent = HoverIntent(delay: hoverDelay)
        hoverIntent.onConfirmed = { [weak self] in
            self?.onTrigger?(false)
        }
        // 拖拽迎上:窗口的 NSDraggingDestination 立即触发(不等防抖)。
        window.onDragEntered = { [weak self] in
            self?.hoverIntent.exit()
            self?.onTrigger?(true)
        }
        startMouseMonitor()
    }

    /// 把热区贴到给定屏的刘海/回退几何上。窗口仍承载拖拽迎上;hover 命中用同一矩形几何判断。
    func place(on resolution: NotchGeometry.Resolution) {
        let rect = NotchGeometry.hotZoneRect(from: resolution)
        hotZoneRect = rect
        window.place(at: rect)
    }

    private func startMouseMonitor() {
        // 全局 monitor:鼠标在其它 app 上时;本地 monitor:在自己窗口上时。两者覆盖全屏。
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.evaluateMouse()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.evaluateMouse()
            return event
        }
    }

    /// 轻量:只读全局坐标 + 矩形包含判断,只在跨边界时动作(避免高频抖动/重复 enter)。
    private func evaluateMouse() {
        guard hotZoneRect != .zero else { return }
        let inside = hotZoneRect.contains(NSEvent.mouseLocation)
        guard inside != insideHotZone else { return }
        insideHotZone = inside
        if inside {
            hoverIntent.enter()
        } else {
            hoverIntent.exit()
        }
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}
