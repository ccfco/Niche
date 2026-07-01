import AppKit
import Sparkle

/// AppKit 侧入口:持有依赖容器、菜单栏图标控制器、触发热区与面板控制器,并重建主菜单。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let environment = AppEnvironment()
    private var menuBarController: MenuBarController?
    private var controller: NicheController?
    /// Sparkle 更新器(安装层)。强持有,startingUpdater:false + 手动 start,
    /// 确保 automaticallyChecksForUpdates 在 updater 真正跑起来前就已关闭(消除时序疑虑)。
    private var sparkleUpdater: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement app 默认就是 accessory;显式声明以防被其它配置改写。
        NSApp.setActivationPolicy(.accessory)
        // 不再用 SwiftUI App → 自动主菜单没了,必须显式重建:Edit 菜单是重命名输入框 / 设置页
        // 文本框 ⌘C/V/X/A/Z 的 key equivalent 路由,缺了这些快捷键会静默失效。
        NSApp.mainMenu = makeMainMenu()
        let controller = NicheController(environment: environment)
        self.controller = controller
        // 先注入 Sparkle 安装闭包，再 start 检测层（start 5s 后才首检，顺序保险）。
        setupSparkle()
        UpdateChecker.shared.start()
        menuBarController = MenuBarController(
            environment: environment,
            onToggle: { [weak controller] in controller?.toggle() },
            onOpenSettings: { [weak controller] in controller?.openSettings() }
        )
    }

    /// 装配 Sparkle：检测交给 UpdateChecker（GitHub API），Sparkle 只做安装器，
    /// 故关掉它自己的定时检查；把「触发安装」闭包注入 UpdateChecker。
    private func setupSparkle() {
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.automaticallyChecksForUpdates = false
        do {
            try controller.updater.start()
        } catch {
            Log.updates.error("Sparkle updater 启动失败: \(error.localizedDescription, privacy: .public)")
        }
        sparkleUpdater = controller
        UpdateChecker.shared.installHandler = { [weak self] in
            self?.sparkleUpdater?.updater.checkForUpdates()
        }
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
