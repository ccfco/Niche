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

    /// 确认呼出。screen 是**本次热区实际命中的屏幕**,呈现层必须沿用它,不能在 dwell 到点后
    /// 再读鼠标位置猜一次屏幕:多显示器共享边界 / 全屏 Space 切换时两次解析可能选到不同屏。
    /// `draggingFile=true` 表示拖拽迎上(只可能来自 .primary)。
    var onTrigger: ((_ kind: Zone.Kind, _ draggingFile: Bool, _ screen: NSScreen) -> Void)?

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

    /// 面板收起后由宿主调:复位热区进出状态,消除「一次性 dwell」死区。
    ///
    /// dwell 只在鼠标**进入**热区的瞬间起计时;面板在「鼠标仍停在热区里」时被关掉(hover 呼出后
    /// 按 Esc / 快捷键 toggle / 点顶部菜单栏失焦收回),insideHotZone 仍为 true,区内再怎么移动
    /// 都不会有第二发——热区成死区,必须把鼠标拉出再回来。修 maxY 边界前这个缺口被「贴顶每事件
    /// 强制重置」的 bug 歪打正着掩盖(晃一下就重新武装),修掉后首次暴露(实报「更难呼出了」)。
    /// 复位后**不立即 enter**:下一次区内 mouseMoved 走正常 false→true 转移重新起 dwell——
    /// 「关掉后原地一晃即可再呼出」,鼠标不动则不会自动重开(尊重用户刚做的关闭动作)。
    func rearmAfterDismiss() {
        guard insideHotZone else { return }
        Log.trigger.info("面板收起时鼠标仍在热区内,复位进出状态等待下一次移动重新武装")
        insideHotZone = false
        activeKind = nil
        hoverIntent.exit()
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// 当前屏所有生效热区(主热区 + 热角 + 边缘)。鼠标进入任一个即起 hover intent。
    private var zones: [Zone] = []
    /// 鼠标当前所在区的身份(hover intent 确认时回传给宿主;离开置 nil)。
    private var activeKind: Zone.Kind?
    /// 已解析热区的那块屏的 frame;鼠标离开它才重新搜屏(快路径,避免每次移动都遍历屏幕列表)。
    private var trackedScreenFrame: CGRect = .zero
    /// 与 trackedScreenFrame 同代的真实 NSScreen。触发回调把它作为本次呈现的屏幕 authority。
    private weak var trackedScreen: NSScreen?
    private var insideHotZone = false

    init(hoverDelay: TimeInterval = 0.18) {
        hoverIntent = HoverIntent(delay: hoverDelay)
        hoverIntent.onConfirmed = { [weak self] in
            guard let self, let screen = self.trackedScreen else { return }
            Log.trigger.info("dwell 到点,发出呼出信号 kind=\(String(describing: self.activeKind), privacy: .public)")
            self.onTrigger?(self.activeKind ?? .primary, false, screen)
        }
        // 拖拽迎上:窗口的 NSDraggingDestination 立即触发(不等防抖)。窗口只在主热区,身份必为 .primary。
        window.onDragEntered = { [weak self] in
            guard let self, self.isEnabled else { return }
            self.hoverIntent.exit()
            // 拖拽期间普通 mouseMoved 不可靠,优先取真正接到 draggingEntered 的热区窗口所在屏;
            // trackedScreen 仅作窗口尚未归属屏幕时的同代兜底。
            guard let screen = self.window.screen ?? self.trackedScreen else { return }
            self.onTrigger?(.primary, true, screen)
        }
        startMouseMonitor()
    }

    /// 屏幕参数变化(接拔显示器/分辨率/菜单栏隐藏)后强制按当前鼠标位置重新落位。
    /// 平时跟随由鼠标移动驱动;此方法覆盖"屏变了但鼠标没动"的情形。
    func refreshPlacement() {
        trackedScreenFrame = .zero   // 作废缓存,下面立即重解析
        trackedScreen = nil
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

    /// 命中判定(纯函数,回归测试钉住):按数组顺序取第一个包含鼠标的区(热角在边缘之前,
    /// 重叠处热角赢)。含 max 边界:CGRect.contains 排除 maxX/maxY,鼠标顶到屏幕最顶
    /// (y=maxY=屏高)恰落在被排除的上边界 → 贴边呼不出(热角/边缘同理贴屏幕最右/最下边)。
    static func hitZone(in zones: [Zone], mouse: CGPoint) -> Zone? {
        zones.first { zone in
            mouse.x >= zone.rect.minX && mouse.x <= zone.rect.maxX
                && mouse.y >= zone.rect.minY && mouse.y <= zone.rect.maxY
        }
    }

    /// 鼠标是否仍在给定屏 frame 内(纯函数,回归测试钉住):贴屏幕顶/右边时 mouseLocation 恰落在
    /// frame 的 max 边上,`CGRect.contains` 排除 max 边会把「贴顶」误判成「跨屏」——每个 mouseMoved
    /// 都走慢路径重置 insideHotZone/dwell,贴顶滑动期间计时永远到不了点,呼出偶发失灵
    /// (与 hitZone 含 max 边是同一类坑)。故四边全含;空 frame(.zero 缓存初值)不含任何点。
    static func screenContainsMouse(frame: CGRect, mouse: CGPoint) -> Bool {
        !frame.isEmpty
            && mouse.x >= frame.minX && mouse.x <= frame.maxX
            && mouse.y >= frame.minY && mouse.y <= frame.maxY
    }

    /// 跨区滑动是否重起 dwell 计时(纯函数,回归测试钉住):在区内滑进**另一个**区(如角落→
    /// 相邻边缘重叠带)要重计时,不沿用旧区已积累的停留时间,否则新区会被旧区的计时提前触发
    /// (Codex review);同一区内滑动身份不变、计时不动;从区外初进不算"跨区"(走 enter 路径)。
    static func shouldRestartDwell(wasInside: Bool, previousKind: Zone.Kind?, hitKind: Zone.Kind) -> Bool {
        wasInside && previousKind != hitKind
    }

    /// 轻量:跨屏时换几何,否则只读全局坐标 + 矩形包含判断,只在跨边界时动作。
    private func evaluateMouse() {
        guard isEnabled else { return }
        let mouse = NSEvent.mouseLocation
        syncScreenIfNeeded(mouse: mouse)
        guard !zones.isEmpty else { return }
        let hit = Self.hitZone(in: zones, mouse: mouse)
        let inside = hit != nil
        if let hit {
            if Self.shouldRestartDwell(wasInside: insideHotZone, previousKind: activeKind, hitKind: hit.kind) {
                hoverIntent.exit()
                hoverIntent.enter()
            }
            activeKind = hit.kind
        }
        guard inside != insideHotZone else { return }
        insideHotZone = inside
        // 只在进出转移时打点(不逐事件),排障「呼不出」时对表:有进入无 dwell 到点=计时被打断,
        // 连进入都没有=命中判定/监听层问题,有信号无面板=present 侧被吞。
        if inside {
            Log.trigger.info("进入热区 kind=\(String(describing: hit?.kind), privacy: .public),起 dwell 计时")
            hoverIntent.enter()
        } else {
            Log.trigger.info("离开热区")
            activeKind = nil
            hoverIntent.exit()
        }
    }

    /// 鼠标跨屏时把热区几何换到新屏并重定位拖拽窗口。仍在已跟踪屏内走快路径直接返回。
    private func syncScreenIfNeeded(mouse: CGPoint) {
        // 判「仍在原屏」与找屏共用同一含 max 边谓词:贴顶(y=maxY)是热区常态位置,不能被判成跨屏。
        if Self.screenContainsMouse(frame: trackedScreenFrame, mouse: mouse) { return }
        guard let screen = NSScreen.screens.first(where: { Self.screenContainsMouse(frame: $0.frame, mouse: mouse) }) ?? NSScreen.main else { return }
        trackedScreenFrame = screen.frame
        trackedScreen = screen
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
