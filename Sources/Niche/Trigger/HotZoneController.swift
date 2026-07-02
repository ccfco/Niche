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
    /// 一块生效的触发区:命中矩形 + 触发身份(宿主据此决定面板从哪长出)。
    struct Zone {
        enum Kind: Equatable {
            case primary                 // 刘海/顶部回退(唯一支持拖拽迎上的区)
            case corner(ScreenCorner)    // 热角
            case side(ScreenSide)        // 边缘
        }
        let kind: Kind
        let rect: CGRect
    }

    private let window = HotZoneWindow()
    private let hoverIntent: HoverIntent

    /// 确认呼出。kind 是触发来源;`draggingFile=true` 表示拖拽迎上(只可能来自 .primary)。
    var onTrigger: ((_ kind: Zone.Kind, _ draggingFile: Bool) -> Void)?

    /// 给定屏 → 该屏所有生效热区(全局坐标,原点左下)。宿主注入(ScreenObserver + NotchGeometry +
    /// 热角/边缘)。约定第一个是 .primary(承载拖拽落点识别的 HotZoneWindow);命中按数组顺序取
    /// 第一个包含鼠标的区(热角在边缘之前,角落重叠处热角赢)。鼠标进入新屏时用它重算。
    var resolveZones: ((NSScreen) -> [Zone])?

    /// 监听总开关(宿主按"任一触发区生效"推导;主热区单独关走 resolveZones 不下发 .primary):
    /// 关掉只停 hover 判定,监听保留(开关随时可逆,拖拽迎上也一并停)。
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue, !isEnabled else { return }
            insideHotZone = false
            activeKind = nil
            hoverIntent.exit()
        }
    }

    /// hover 意图延迟随设置调整。
    func setHoverDelay(_ delay: TimeInterval) {
        hoverIntent.delay = delay
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// 当前屏所有生效热区(主热区 + 热角 + 边缘)。鼠标进入任一个即起 hover intent。
    private var zones: [Zone] = []
    /// 鼠标当前所在区的身份(hover intent 确认时回传给宿主;离开置 nil)。
    private var activeKind: Zone.Kind?
    /// 已解析热区的那块屏的 frame;鼠标离开它才重新搜屏(快路径,避免每次移动都遍历屏幕列表)。
    private var trackedScreenFrame: CGRect = .zero
    private var insideHotZone = false

    init(hoverDelay: TimeInterval = 0.18) {
        hoverIntent = HoverIntent(delay: hoverDelay)
        hoverIntent.onConfirmed = { [weak self] in
            guard let self else { return }
            self.onTrigger?(self.activeKind ?? .primary, false)
        }
        // 拖拽迎上:窗口的 NSDraggingDestination 立即触发(不等防抖)。窗口只在主热区,身份必为 .primary。
        window.onDragEntered = { [weak self] in
            guard let self, self.isEnabled else { return }
            self.hoverIntent.exit()
            self.onTrigger?(.primary, true)
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
        guard isEnabled else { return }
        let mouse = NSEvent.mouseLocation
        syncScreenIfNeeded(mouse: mouse)
        guard !zones.isEmpty else { return }
        // 含上边界:CGRect.contains 排除 maxY,鼠标顶到屏幕最顶(y=maxY=屏高)恰落在被排除的
        // 上边界 → 贴边呼不出(热角/边缘同理贴屏幕最右/最下边)。热区贴边,必须显式含 max 边。
        let hit = zones.first { zone in
            mouse.x >= zone.rect.minX && mouse.x <= zone.rect.maxX
                && mouse.y >= zone.rect.minY && mouse.y <= zone.rect.maxY
        }
        let inside = hit != nil
        if let hit {
            // 跨区滑动(如角落→相邻边缘重叠带):重起 dwell 计时,不沿用旧区已积累的停留时间,
            // 否则新区会被旧区的计时提前触发(Codex review)。同一区内滑动身份不变、计时不动。
            if insideHotZone, activeKind != hit.kind {
                hoverIntent.exit()
                hoverIntent.enter()
            }
            activeKind = hit.kind
        }
        guard inside != insideHotZone else { return }
        insideHotZone = inside
        if inside {
            hoverIntent.enter()
        } else {
            activeKind = nil
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
        activeKind = nil
        hoverIntent.exit()
        zones = resolveZones?(screen) ?? []
        // HotZoneWindow 只承载主热区(刘海/回退)的拖拽落点识别;热角/边缘纯 hover 触发,不需要窗口。
        // 主热区被单独关掉(hotZoneEnabled=false,但热角/边缘仍开)时收起窗口,拖拽路径一并停。
        if let primary = zones.first(where: { $0.kind == .primary }) {
            window.place(at: primary.rect)
        } else {
            window.orderOut(nil)
        }
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}
