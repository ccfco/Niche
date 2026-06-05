import AppKit

/// 菜单栏图标 + 下拉菜单。提供"呼出 Niche / 设置… / 退出"等入口,并作为全局快捷键兜底
/// 之外的常驻可见触发点(spec §4.2:菜单栏图标是可选触发位置之一)。
@MainActor
final class MenuBarController {
    private let environment: AppEnvironment
    private let statusItem: NSStatusItem

    init(environment: AppEnvironment) {
        self.environment = environment
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()
        statusItem.menu = makeMenu()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled",
                               accessibilityDescription: "Niche")
        button.image?.isTemplate = true
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "呼出 Niche", action: #selector(togglePanel), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Niche", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func togglePanel() {
        // M1 接入 PanelController 后,这里切换瞬态面板显隐。
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
