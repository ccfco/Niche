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

    /// 标准尺寸:宽 = 5 列单元格精确和(永不裁切半格,派生自 EdgeMetrics);高取略扁的格式比例。
    /// 两模式共用、Pin 不改。
    private var standardSize: CGSize {
        let columns: CGFloat = 6
        let width = columns * edge.cellWidth + (columns - 1) * edge.itemSpacing + edge.panelPadding * 2
        return CGSize(width: width, height: (width * 0.8).rounded())
    }

    // MARK: - 显示 / 收起

    /// 呼出瞬态:从刘海/回退区下方"长出来"(nonactivating 取键焦点做导航但不抢前台)+ 起鼠标离开监听。
    func presentTransient(below resolution: NotchGeometry.Resolution) {
        let panel = ensurePanel()
        showGeneration += 1
        isHiding = false
        panel.mode = .transient
        let target = standardFrame(below: resolution)
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

    /// 标准 frame:刘海/回退区正下方居中,顶边贴刘海底(向下展开)。
    private func standardFrame(below resolution: NotchGeometry.Resolution) -> NSRect {
        let anchor = resolution.rect
        let size = standardSize
        return NSRect(x: anchor.midX - size.width / 2,
                      y: anchor.minY - size.height,   // anchor.minY = 刘海底 = 面板顶
                      width: size.width, height: size.height)
    }

    private func ensurePanel() -> NichePanel {
        if let panel { return panel }
        let p = NichePanel(
            contentRect: NSRect(origin: .zero, size: standardSize),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],   // 固定尺寸:不带 .resizable
            backing: .buffered, defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.contentView = NSHostingView(rootView: ContentPanelView(model: model, motion: motion, actions: actions))
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
