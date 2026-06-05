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
    private let onTogglePin: () -> Void
    private let onOpen: (FileItem) -> Void

    init(model: PanelModel,
         onOpen: @escaping (FileItem) -> Void,
         onTogglePin: @escaping () -> Void) {
        self.model = model
        self.onOpen = onOpen
        self.onTogglePin = onTogglePin
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 在指定 frame 显示常驻浮窗(通常用瞬态面板当前 frame,实现"原地变常驻")。
    func show(at frame: NSRect) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.mode = .pinned
        panel.setFrame(frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func close() {
        panel?.close()
        panel = nil
    }

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

        let root = ContentPanelView(model: model, onOpen: onOpen, onTogglePin: onTogglePin)
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
