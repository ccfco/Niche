import AppKit

/// AppKit 侧入口:持有依赖容器、菜单栏图标控制器、触发热区与面板控制器,并重建主菜单。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let environment = AppEnvironment()
    private var menuBarController: MenuBarController?
    private var controller: NicheController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement app 默认就是 accessory;显式声明以防被其它配置改写。
        NSApp.setActivationPolicy(.accessory)
        // 不再用 SwiftUI App → 自动主菜单没了,必须显式重建:Edit 菜单是重命名输入框 / 设置页
        // 文本框 ⌘C/V/X/A/Z 的 key equivalent 路由,缺了这些快捷键会静默失效。
        NSApp.mainMenu = makeMainMenu()
        let controller = NicheController(environment: environment)
        self.controller = controller
        UpdateChecker.shared.start()
        menuBarController = MenuBarController(
            environment: environment,
            onToggle: { [weak controller] in controller?.toggle() },
            onOpenSettings: { [weak controller] in controller?.openSettings() }
        )
    }

    /// 最小主菜单:App(设置/退出)+ 编辑(标准选择子,target 留空走响应链)。
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Niche", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        return main
    }

    @objc private func openSettingsFromMenu() {
        controller?.openSettings()
    }
}
