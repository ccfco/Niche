import AppKit
import SwiftUI

/// 统一面板宿主:瞬态(hover 用完即走)与常驻(Pin)是**同一个** `NichePanel` 的两种行为,
/// 不是两套窗口、也不是两套代码 —— Pin 只翻 `WindowMode`(焦点/监听策略),**frame 一字节不动**。
///
/// 替代了旧的 NotchExpansion(DNK 黑底刘海板,吞玻璃)+ PinnedPanelController(另一个 titled 窗)。
///
/// - 尺寸:单一**标准尺寸**(宽恰容 5 列单元格,派生自网格;两模式共用,Pin 不改、不可 resize)。
/// - 瞬态:从刘海下方"长出来"(frame 动画)+ 鼠标离开"面板↔刘海"走廊即收。
/// - 常驻:就地变 floating、可激活、可拖动(detach);不长出、不改尺寸。
@MainActor
final class PanelController {
    private(set) var panel: NichePanel?
    private let model: PanelModel
    private let motion: MotionPreferences
    private let actions: PanelActions
    private let edge = EdgeMetrics.standard

    /// 瞬态下鼠标离开"面板↔刘海"走廊(宿主据此过 AutoHideCoordinator 抑制判定后收回)。
    var onMouseExitedTransient: (() -> Void)?

    private var mouseMonitors: [Any] = []
    private var leaveWorkItem: DispatchWorkItem?
    /// 瞬态 keep-alive 区域基准(面板 frame ∪ 此矩形);防 hover-收-再 hover 闪烁。
    /// 贴刘海时=刘海矩形(连成走廊);脱离刘海(unpin)时=面板自身。
    private var anchorRect: CGRect = .zero
    /// 淡出竞态守卫:每次显示自增;hide 淡出回调若被新一次显示抢占(代次不符)则放弃 orderOut。
    private var showGeneration = 0
    private var isHiding = false

    init(model: PanelModel, motion: MotionPreferences, actions: PanelActions) {
        self.model = model
        self.motion = motion
        self.actions = actions
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var mode: WindowMode { panel?.mode ?? .transient }
    var isTransientShown: Bool { isVisible && mode == .transient }

    /// 固定列数:宽度 = 6 列单元格精确和(永不裁切半格,派生自 EdgeMetrics)。两模式共用、Pin 不改。
    private let columns = 6

    private var panelWidth: CGFloat {
        CGFloat(columns) * edge.cellWidth + CGFloat(columns - 1) * edge.itemSpacing + edge.panelPadding * 2
    }

    /// 高度按条目数 + 视图模式自适应:有几行就多高(消灭空白),超出上限滚动。
    /// 列表行矮(~26)、行数=条目数;图标行高(~98)、行数=ceil(条目/列)。chrome 含 tab/工具栏/分隔(列表多表头)。
    private func panelHeight(itemCount: Int) -> CGFloat {
        let count = max(itemCount, 1)
        if model.viewMode == .list {
            let rowHeight: CGFloat = 26
            let chrome: CGFloat = 112        // tab + 表头 + 底栏 + 分隔 + padding
            let rows = max(4, min(12, count))
            return (chrome + CGFloat(rows) * rowHeight).rounded()
        } else {
            let rowHeight: CGFloat = 98
            let chrome: CGFloat = 96
            let rows = max(2, min(5, Int(ceil(Double(count) / Double(columns)))))
            return (chrome + CGFloat(rows) * rowHeight).rounded()
        }
    }

    // MARK: - 显示 / 收起

    /// 呼出瞬态:从刘海/回退区下方"长出来"(nonactivating 取键焦点做导航但不抢前台)+ 起鼠标离开监听。
    func presentTransient(below resolution: NotchGeometry.Resolution, itemCount: Int) {
        let panel = ensurePanel()
        showGeneration += 1
        isHiding = false
        panel.mode = .transient
        let target = standardFrame(below: resolution, itemCount: itemCount)
        anchorRect = resolution.rect
        // 起始:刘海宽的小条,顶边贴刘海底 → 向下+两侧长到标准尺寸。
        let start = NSRect(x: target.midX - resolution.rect.width / 2,
                           y: target.maxY - 6, width: resolution.rect.width, height: 6)
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        let dur = motion.reduceMotion ? 0.16 : 0.3
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = dur
            ctx.timingFunction = CAMediaTimingFunction(name: motion.reduceMotion ? .easeOut : .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
        startMouseLeaveMonitor()
    }

    /// 复现常驻(全局快捷键再次呼出已 pin 的窗):就地 orderFront + 激活,不长出、不改尺寸/位置。
    func revealPinned() {
        let panel = ensurePanel()
        showGeneration += 1
        isHiding = false
        panel.mode = .pinned
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 收起(两模式通用):淡出 + orderOut,停鼠标离开监听。
    func hide() {
        stopMouseLeaveMonitor()
        guard let panel, panel.isVisible, !isHiding else { return }
        isHiding = true
        let gen = showGeneration
        let dur = motion.reduceMotion ? 0.12 : 0.18
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = dur
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, gen == self.showGeneration else { return }   // 被新一次显示抢占 → 不收
            panel.orderOut(nil)
            panel.alphaValue = 1
            self.isHiding = false
        })
    }

    // MARK: - 就地 Pin / Unpin(只翻行为,绝不改 frame)

    /// Pin:停鼠标离开监听、变 .pinned(floating + 可激活 + 可拖动)、激活取键焦点。
    /// Unpin:变回 .transient、keep-alive 区改为面板自身、恢复鼠标离开监听。**两条路径都不动 frame**。
    func setPinned(_ pinned: Bool) {
        guard let panel else { return }
        panel.mode = pinned ? .pinned : .transient
        if pinned {
            stopMouseLeaveMonitor()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            anchorRect = panel.frame   // 脱离刘海:走廊塌缩为面板自身,离开面板即收
            startMouseLeaveMonitor()
        }
    }

    // MARK: - 几何 / 窗口

    /// 标准 frame:刘海/回退区正下方居中,顶边贴刘海底(向下展开)。高度按条目数自适应。
    private func standardFrame(below resolution: NotchGeometry.Resolution, itemCount: Int) -> NSRect {
        let anchor = resolution.rect
        let w = panelWidth
        let h = panelHeight(itemCount: itemCount)
        return NSRect(x: anchor.midX - w / 2,
                      y: anchor.minY - h,   // anchor.minY = 刘海底 = 面板顶
                      width: w, height: h)
    }

    private func ensurePanel() -> NichePanel {
        if let panel { return panel }
        // .titled(而非 borderless)是 Clipin 干净边缘的前提:borderless 窗本身是直角矩形,
        // 玻璃在内圆到 24,四角"圆角外、窗框内"的小三角会露系统阴影 = 尖角灰线。.titled 窗有
        // 系统 frame view,可被 KVC cornerRadius 圆角,与玻璃严丝合缝 → 无三角、无灰线。
        let p = NichePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight(itemCount: 12)),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],   // 自适应高度:不带 .resizable
            backing: .buffered, defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.title = ""
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { p.standardWindowButton($0)?.isHidden = true }
        p.minSize = NSSize(width: 1, height: 1)   // 允许"从刘海长出"动画起始的窄条

        // 窗面 = macOS 26 原生整窗 Liquid Glass(NSGlassEffectView,Spotlight/访达同款)。
        // 几何绑定 contentView:自带干净圆角裁切 + 锐利系统阴影 —— 根治旧 NSVisualEffectView +
        // masksToBounds 的"边缘发糊发灰"。借鉴姊妹项目 Clipin 已在真机验证的配方。
        let glass = NSGlassEffectView()
        glass.cornerRadius = edge.panelCornerRadius   // 外壳同心圆基准(= 底栏按钮 16 + gap 8)
        let host = NicheGlassHostingView(rootView: ContentPanelView(model: model, motion: motion, actions: actions))
        glass.contentView = host
        p.contentView = glass
        // .titled 窗始终有系统 frame:用 cornerRadius KVC 把 frame 圆角对齐 shell 24,否则四角
        // 露 frame 发丝弧/尖角灰线(Clipin 同款,private _cornerRadius,不手动 masksToBounds)。
        p.setValue(edge.panelCornerRadius, forKey: "cornerRadius")
        p.invalidateShadow()
        p.mode = .transient
        panel = p
        return p
    }

    // MARK: - 瞬态鼠标离开监听

    private func startMouseLeaveMonitor() {
        stopMouseLeaveMonitor()
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.evaluateLeave()
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.evaluateLeave()
            return event
        }
        mouseMonitors = [global, local].compactMap { $0 }
    }

    private func stopMouseLeaveMonitor() {
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseMonitors.removeAll()
        leaveWorkItem?.cancel()
        leaveWorkItem = nil
    }

    /// 鼠标在"面板 ∪ anchorRect"走廊内 → 取消待收;离开 → 起 0.35s 延时收回(被抑制由宿主拦)。
    private func evaluateLeave() {
        guard let panel, panel.mode == .transient, panel.isVisible else { return }
        let region = panel.frame.union(anchorRect).insetBy(dx: -8, dy: -8)
        if region.contains(NSEvent.mouseLocation) {
            leaveWorkItem?.cancel()
            leaveWorkItem = nil
        } else if leaveWorkItem == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.leaveWorkItem = nil
                self?.onMouseExitedTransient?()
            }
            leaveWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }
}

/// 受 WindowMode 状态机驱动的 NSPanel:styleMask(.nonactivatingPanel)、层级、可拖动随模式变化。
/// 瞬态与常驻共用此**一个**窗口(见 PanelController)。
final class NichePanel: NSPanel {
    var mode: WindowMode = .transient {
        didSet { applyMode() }
    }

    override var canBecomeKey: Bool { mode.canBecomeKey }
    override var canBecomeMain: Bool { mode.canBecomeMain }

    private func applyMode() {
        // styleMask 恒定带 .nonactivatingPanel(init 设),不随 mode 切 —— 避免反复改 styleMask
        // 抖掉 firstResponder/键盘焦点。两模式都靠 canBecomeKey=true 成 key 收键盘;常驻另调
        // NSApp.activate 激活 app。nonactivating 只挡 main(附件 app 不需要 main),不挡 key。
        level = mode.level
        collectionBehavior = mode.collectionBehavior
        isMovableByWindowBackground = (mode == .pinned)   // 常驻:拖背景移动(detach);瞬态:不可拖
        hidesOnDeactivate = false   // 隐藏策略统一交给 AutoHideCoordinator,不靠系统 deactivate
    }
}

/// NSGlassEffectView 内的 SwiftUI 宿主:窗面玻璃/圆角/裁切/阴影全交给 AppKit(NSGlassEffectView +
/// 窗口),内容层只需归零 safe area、清空图层、**不 mask** —— 在内容层再画边/裁切会和玻璃叠出
/// 发丝线(借鉴 Clipin ClipinPanelHostingView)。无 borderless 标题栏,故 safe area 本就该为 0。
final class NicheGlassHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
        layer?.borderColor = nil
        layer?.masksToBounds = false
    }
}
