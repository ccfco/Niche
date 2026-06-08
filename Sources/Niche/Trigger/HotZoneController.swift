import AppKit

/// 触发热区控制器:把"空手 hover"与"拖着文件迎上"两条路径归一成"请求呼出"信号。
///
/// **hover 命中改用全局鼠标位置监听 + 几何判断**(不再依赖透明热区窗口的 NSTrackingArea ——
/// 它在 statusBar 层易被系统菜单栏窗口盖住、收不到 mouseEntered,是 hover 失效的根因)。
/// 全局监听不受窗口层级/遮挡影响,是 Dock 自动隐藏等的稳妥做法。
///
/// **热区实时跟随鼠标所在屏**(spec §4.2「多屏在鼠标活跃屏触发」):全局监听每次鼠标移动都跑,
/// 据此在鼠标跨屏时把命中矩形换到新屏、并把拖拽窗口挪过去 —— 不再"钉死在启动那一刻的屏"。
/// 拖拽迎上仍走热区窗口的 NSDraggingDestination(全局鼠标监听拿不到拖拽 session)。
@MainActor
final class HotZoneController {
    private let window = HotZoneWindow()
    private let hoverIntent: HoverIntent

    /// 确认呼出。`draggingFile=true` 表示拖拽迎上(宿主可用更快 spring)。
    var onTrigger: ((_ draggingFile: Bool) -> Void)?

    /// 给定屏 → 该屏的热区命中矩形(全局坐标,原点左下)。宿主注入(ScreenObserver + NotchGeometry)。
    /// 鼠标进入新屏时用它重算 rect。
    var resolveRect: ((NSScreen) -> CGRect?)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// 当前命中矩形(全局坐标,原点左下)。鼠标进入即起 hover intent。
    private var hotZoneRect: CGRect = .zero
    /// 已解析热区的那块屏的 frame;鼠标离开它才重新搜屏(快路径,避免每次移动都遍历屏幕列表)。
    private var trackedScreenFrame: CGRect = .zero
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

    /// 屏幕参数变化(接拔显示器/分辨率/菜单栏隐藏)后强制按当前鼠标位置重新落位。
    /// 平时跟随由鼠标移动驱动;此方法覆盖"屏变了但鼠标没动"的情形。
    func refreshPlacement() {
        trackedScreenFrame = .zero   // 作废缓存,下面立即重解析
        evaluateMouse()
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

    /// 轻量:跨屏时换几何,否则只读全局坐标 + 矩形包含判断,只在跨边界时动作。
    private func evaluateMouse() {
        let mouse = NSEvent.mouseLocation
        syncScreenIfNeeded(mouse: mouse)
        guard hotZoneRect != .zero else { return }
        let inside = hotZoneRect.contains(mouse)
        guard inside != insideHotZone else { return }
        insideHotZone = inside
        if inside {
            hoverIntent.enter()
        } else {
            hoverIntent.exit()
        }
    }

    /// 鼠标跨屏时把热区几何换到新屏并重定位拖拽窗口。仍在已跟踪屏内走快路径直接返回。
    private func syncScreenIfNeeded(mouse: CGPoint) {
        if trackedScreenFrame.contains(mouse) { return }
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        trackedScreenFrame = screen.frame
        // 换屏即作废旧屏的进出态:显式 exit 取消可能在跑的 hover intent timer,
        // 避免旧屏 enter 未配对 exit 导致防抖卡住(跨屏不保证落点仍在热区会触发 exit)。
        insideHotZone = false
        hoverIntent.exit()
        guard let rect = resolveRect?(screen) else { hotZoneRect = .zero; return }
        hotZoneRect = rect
        window.place(at: rect)
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}
