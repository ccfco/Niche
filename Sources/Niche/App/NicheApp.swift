import AppKit

/// Niche 入口。menu bar accessory(`LSUIElement=true`),不进 Dock、平时无主窗口。
///
/// **纯 AppKit 启动,不用 SwiftUI App**:此前用 `Settings` scene 承载设置页,但 accessory app
/// 没有公开 API 能从 AppKit 侧编程打开它 —— `showSettingsWindow:` 私有选择子在 macOS 14+ 被
/// 系统封禁(要求 SettingsLink,只能放在 SwiftUI 菜单里),菜单栏「设置…」点了没反应。
/// 设置窗口改为自管(SettingsWindowController);SwiftUI App 自动生成的主菜单由
/// AppDelegate.makeMainMenu 显式重建(Edit 菜单是重命名输入框 ⌘C/V/A 的路由,不能丢)。
@main
@MainActor
enum NicheMain {
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        // NSApp.delegate 是 unsafe-unretained:静态持有,防 delegate 被提前释放。
        app.delegate = delegate
        app.run()
    }
}
