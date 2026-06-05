import AppKit
import SwiftUI

/// 常驻浮窗(spec §4.6:pin = 普通可激活、可拖动、always-on-top 浮窗,可 detach 到任意位置)。
///
/// 与瞬态(DNK)是两种**窗口模式**,不是布尔开关。本控制器拥有 pinned 态的 NSPanel;
/// 瞬态↔常驻的切换由 NicheController 编排(把同一 PanelModel 交给另一个宿主)。
@MainActor
final class PinnedPanelController {
    private(set) var panel: NichePanel?
    private let model: PanelModel
    private let motion: MotionPreferences
    private let actions: PanelActions
    /// 几何记忆(spec §4.6 Resize:记忆尺寸+位置)。
    private let store: BindingStore
    private var frameObservers: [NSObjectProtocol] = []

    init(model: PanelModel, motion: MotionPreferences, actions: PanelActions, store: BindingStore) {
        self.model = model
        self.motion = motion
        self.actions = actions
        self.store = store
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 在指定 frame 显示常驻浮窗(优先用记忆的尺寸/位置;否则用传入 frame 实现"原地变常驻")。
    func show(at frame: NSRect) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.mode = .pinned
        panel.setFrame(store.loadPanelFrame() ?? frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        observeFrame(panel)
    }

    /// 记忆尺寸+位置:缩放结束(didEndLiveResize)与移动结束(didMove,detach 拖动)都存回。
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

    func hide() {
        if let panel { store.savePanelFrame(panel.frame) }   // 收起前存回几何
        panel?.orderOut(nil)
    }

    func close() {
        teardownFrameObservers()
        panel?.close()
        panel = nil
    }
    // 注:不在 deinit 清理(deinit 是 nonisolated,无法调 @MainActor 方法);本控制器随 app
    // 生命周期存在,observers 由 close() 清理,token 引用的是 panel,panel 释放后回调不再触发。

    private func makePanel() -> NichePanel {
        // pinned 是"可激活 always-on-top 浮窗":**不能**带 .nonactivatingPanel
        // (否则与 WindowMode.pinned.canBecomeMain=true 冲突,面板永远无法成为 main window)。
        let panel = NichePanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.mode = .pinned
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true   // detach:拖背景即可移动
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let root = ContentPanelView(model: model, motion: motion, actions: actions)
        panel.contentView = NSHostingView(rootView: root)
        return panel
    }
}

/// 受 WindowMode 状态机驱动的 NSPanel:`canBecomeKey/Main` 随模式变化(spec §4.6)。
final class NichePanel: NSPanel {
    var mode: WindowMode = .pinned {
        didSet { applyMode() }
    }

    override var canBecomeKey: Bool { mode.canBecomeKey }
    override var canBecomeMain: Bool { mode.canBecomeMain }

    private func applyMode() {
        level = mode.level
        collectionBehavior = mode.collectionBehavior
        hidesOnDeactivate = false  // 隐藏策略统一交给 AutoHideCoordinator,不靠系统 deactivate
    }
}
