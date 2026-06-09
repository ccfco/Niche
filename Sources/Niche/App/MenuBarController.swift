import AppKit

/// 菜单栏图标 + 下拉菜单。提供"呼出 Niche / 设置… / 退出"等入口,并作为全局快捷键兜底
/// 之外的常驻可见触发点(spec §4.2:菜单栏图标是可选触发位置之一)。
@MainActor
final class MenuBarController {
    private let environment: AppEnvironment
    private let statusItem: NSStatusItem
    private let onToggle: () -> Void

    init(environment: AppEnvironment, onToggle: @escaping () -> Void) {
        self.environment = environment
        self.onToggle = onToggle
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()
        statusItem.menu = makeMenu()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        // rectangle.stack:堆叠的多个面板,呼应 Niche「镜像多个常用文件夹」的差异化定位。
        // (刻意不用 tray/托盘系——那是「暂存盘」心智,与本项目「只做文件夹镜像、不做暂存盘」定位冲突。)
        button.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "Niche")
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
        onToggle()
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
