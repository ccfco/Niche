import AppKit
import SwiftUI

/// 自管设置窗口(替代 SwiftUI `Settings` scene)。
///
/// accessory app 没有公开 API 能从 AppKit 侧打开 Settings scene(`showSettingsWindow:` 私有
/// 选择子在 macOS 14+ 被封禁,SettingsLink 只能活在 SwiftUI 菜单里)。自管一个普通 NSWindow
/// 反而简单可靠:菜单栏「设置…」、面板 ⌘, 都能直达,且可注入 PanelModel(showHidden 单真相源)。
@MainActor
final class SettingsWindowController {
    private let environment: AppEnvironment
    private let model: PanelModel
    private let triggerPrefs: TriggerPreferences
    private let onAddFolder: () -> Void
    private var window: NSWindow?

    init(environment: AppEnvironment, model: PanelModel, triggerPrefs: TriggerPreferences,
         onAddFolder: @escaping () -> Void) {
        self.environment = environment
        self.model = model
        self.triggerPrefs = triggerPrefs
        self.onAddFolder = onAddFolder
    }

    /// 显示(懒建,关闭后复用同一窗口,保留 tab 选择等窗内状态)。
    func show() {
        let window = ensureWindow()
        NSApp.activate(ignoringOtherApps: true)   // accessory app 需显式激活,否则窗口不前置
        window.makeKeyAndOrderFront(nil)
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let host = NSHostingController(
            rootView: SettingsView(model: model, triggerPrefs: triggerPrefs, onAddFolder: onAddFolder)
                .environmentObject(environment)
        )
        let w = NSWindow(contentViewController: host)
        w.title = "Niche 设置"
        w.styleMask = [.titled, .closable, .miniaturizable]   // 设置页固定尺寸,不可 resize
        w.isReleasedWhenClosed = false   // 关闭只是 orderOut,实例复用
        w.center()
        window = w
        return w
    }
}
