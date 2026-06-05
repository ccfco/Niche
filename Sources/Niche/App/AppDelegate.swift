import AppKit

/// AppKit 侧入口:持有依赖容器、菜单栏图标控制器,后续挂触发热区与面板控制器。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let environment = AppEnvironment()
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement app 默认就是 accessory;显式声明以防被其它配置改写。
        NSApp.setActivationPolicy(.accessory)
        menuBarController = MenuBarController(environment: environment)
    }
}
