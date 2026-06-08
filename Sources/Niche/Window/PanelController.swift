import AppKit
import SwiftUI

/// 统一面板宿主:瞬态(hover 用完即走)与常驻(Pin)共用**同一个** `NichePanel` + 同一套玻璃外壳。
///
/// Pin 不是换窗口,而是同一窗口切 `WindowMode` —— 原地留下、变可激活/可拖动,**不销毁、不瞬移**。
/// 这替代了旧的两套割裂窗口:NotchExpansion(DNK 的 .notch 黑底刘海板,吞掉液态玻璃)+
/// PinnedPanelController(另一个 titled 玻璃浮窗,外观/动画/位置全不同)。两套窗口对象天然割裂,
/// 无法"统一一套";改由本控制器一个窗口、一套外壳承载两种模式。
///
/// - 瞬态:从刘海/回退区正下方"长出来"(frame 动画,玻璃全程在);nonactivating 不抢前台;
///   鼠标离开面板↔刘海走廊即收(收回的抑制判定交给宿主的 AutoHideCoordinator)。
/// - 常驻:同一窗口变 floating、可激活、可拖动/缩放;记忆尺寸+位置。
@MainActor
final class PanelController {
    private(set) var panel: NichePanel?
    private let model: PanelModel
    private let motion: MotionPreferences
    private let actions: PanelActions
    private let store: BindingStore

    /// 瞬态下鼠标离开"面板↔刘海"走廊(宿主据此过 AutoHideCoordinator 抑制判定后收回)。
    var onMouseExitedTransient: (() -> Void)?

    private var frameObservers: [NSObjectProtocol] = []
    private var mouseMonitors: [Any] = []
    private var leaveWorkItem: DispatchWorkItem?
    /// 瞬态 keep-alive 区域(面板 frame ∪ 刘海锚区);鼠标在内不收,防 hover-收-再 hover 闪烁。
    private var anchorRect: CGRect = .zero
    /// 淡出竞态守卫:每次 present 自增;hide 的淡出完成回调若被新 present 抢占(代次不符)则放弃 orderOut。
    private var showGeneration = 0
    private var isHiding = false

    /// 瞬态默认尺寸(常驻另用记忆几何)。
    private let transientSize = CGSize(width: 480, height: 360)

    init(model: PanelModel, motion: MotionPreferences, actions: PanelActions, store: BindingStore) {
        self.model = model
        self.motion = motion
        self.actions = actions
        self.store = store
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var mode: WindowMode { panel?.mode ?? .transient }
    var isTransientShown: Bool { isVisible && mode == .transient }

    // MARK: - 瞬态

    /// 从刘海/回退区下方"长出来"。nonactivating(取键焦点做导航但不激活 app),装鼠标离开监听。
    func presentTransient(below resolution: NotchGeometry.Resolution, draggingFile: Bool) {
        let panel = ensurePanel()
        showGeneration += 1
        isHiding = false
        panel.mode = .transient
        let target = transientFrame(below: resolution)
        anchorRect = resolution.rect
        // 起始:刘海宽的小条,顶边贴刘海底 → 向下+两侧长到全尺寸。
        let start = NSRect(x: target.midX - resolution.rect.width / 2,
                           y: target.maxY - 6, width: resolution.rect.width, height: 6)
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()   // nonactivatingPanel:成为 key 承载键盘导航,但不把 app 拉前台

        let dur = motion.reduceMotion ? 0.16 : (draggingFile ? 0.24 : 0.3)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = dur
            ctx.timingFunction = CAMediaTimingFunction(name: motion.reduceMotion ? .easeOut : .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
        startMouseLeaveMonitor()
    }

    /// 收起当前面板(瞬态淡出 + orderOut)。停鼠标离开监听。
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
            guard let self, gen == self.showGeneration else { return }   // 被新 present 抢占 → 不收
            panel.orderOut(nil)
            panel.alphaValue = 1
            self.isHiding = false
        })
    }

    // MARK: - Pin(瞬态 → 常驻,原地)

    /// 同一窗口原地变常驻:停鼠标离开监听、切 .pinned、记忆 frame(有则恢复,无则保留当前=原地)、
    /// 激活取键焦点、挂 frame 记忆观察。**不新建窗口、不瞬移**。
    func pin() {
        guard let panel else { return }
        stopMouseLeaveMonitor()
        panel.mode = .pinned   // 原地留下:保留当前 frame,不恢复 saved(避免跳帧),saved 仅供 showPinned 复现
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        observeFrame(panel)
    }

    /// 常驻 → 瞬态:存回几何、解除 frame 观察、切回 .transient 并收起(宿主随后重新 presentTransient)。
    func unpin() {
        guard let panel else { return }
        store.savePanelFrame(panel.frame)
        teardownFrameObservers()
        panel.mode = .transient
        panel.orderOut(nil)
    }

    /// 常驻态显隐切换(全局快捷键)。
    func hidePinned() {
        guard let panel else { return }
        stopMouseLeaveMonitor()       // 不变量:任何隐藏路径都清 transient 监听(此处通常已停,防御)
        teardownFrameObservers()
        store.savePanelFrame(panel.frame)
        panel.orderOut(nil)
    }

    func showPinned() {
        let panel = ensurePanel()
        panel.mode = .pinned
        if let saved = store.loadPanelFrame() { panel.setFrame(saved, display: true) }
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        observeFrame(panel)
    }

    // MARK: - 几何

    /// 瞬态全宽 frame:刘海/回退区正下方居中,顶边贴刘海底(向下展开)。
    private func transientFrame(below resolution: NotchGeometry.Resolution) -> NSRect {
        let anchor = resolution.rect
        return NSRect(x: anchor.midX - transientSize.width / 2,
                      y: anchor.minY - transientSize.height,   // anchor.minY = 刘海底 = 面板顶
                      width: transientSize.width, height: transientSize.height)
    }

    private func ensurePanel() -> NichePanel {
        if let panel { return panel }
        let p = NichePanel(
            contentRect: NSRect(origin: .zero, size: transientSize),
            styleMask: [.borderless, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        let root = ContentPanelView(model: model, motion: motion, actions: actions)
        p.contentView = NSHostingView(rootView: root)
        p.mode = .transient
        panel = p
        return p
    }

    // MARK: - 常驻几何记忆(缩放/移动结束存回)

    private func observeFrame(_ panel: NSWindow) {
        guard frameObservers.isEmpty else { return }
        let store = self.store
        let save: (Notification) -> Void = { note in
            if let win = note.object as? NSWindow {
                MainActor.assumeIsolated { store.savePanelFrame(win.frame) }
            }
        }
        for name in [NSWindow.didEndLiveResizeNotification, NSWindow.didMoveNotification] {
            frameObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main, using: save)
            )
        }
    }

    private func teardownFrameObservers() {
        frameObservers.forEach { NotificationCenter.default.removeObserver($0) }
        frameObservers.removeAll()
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

    /// 鼠标在"面板 ∪ 刘海"走廊内 → 取消待收;离开 → 起 0.35s 延时收回(被抑制由宿主拦)。
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

/// 受 WindowMode 状态机驱动的 NSPanel:`canBecomeKey/Main`、层级、可拖动随模式变化(spec §4.6)。
/// 瞬态与常驻共用此一个窗口(见 PanelController)。
final class NichePanel: NSPanel {
    var mode: WindowMode = .transient {
        didSet { applyMode() }
    }

    override var canBecomeKey: Bool { mode.canBecomeKey }
    override var canBecomeMain: Bool { mode.canBecomeMain }

    private func applyMode() {
        // styleMask 随 mode 切:瞬态用 .nonactivatingPanel(成 key 承载键盘导航却不抢前台);
        // 常驻移除它,成为正常可激活窗口(否则与 canBecomeMain=true 冲突,makeKey 可能被静默拒)。
        switch mode {
        case .transient: styleMask.insert(.nonactivatingPanel)
        case .pinned:     styleMask.remove(.nonactivatingPanel)
        }
        level = mode.level
        collectionBehavior = mode.collectionBehavior
        isMovableByWindowBackground = (mode == .pinned)   // 常驻:拖背景移动(detach);瞬态:不可拖
        hidesOnDeactivate = false   // 隐藏策略统一交给 AutoHideCoordinator,不靠系统 deactivate
    }
}
