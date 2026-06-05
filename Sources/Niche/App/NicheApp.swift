import SwiftUI

/// Niche 入口。menu bar accessory(`LSUIElement=true`),不进 Dock、平时无主窗口。
///
/// 用 `Settings` scene 作为唯一 SwiftUI scene —— 它不会在启动时开窗,仅在用户从菜单选
/// "设置…"或按 ⌘, 时出现,符合"用完即走、平时无窗口"的形态。所有呼出窗口由 AppKit
/// 侧(`PanelController` / `HotZoneWindow`)在运行时按需创建,不走 SwiftUI WindowGroup。
@main
struct NicheApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.environment)
        }
    }
}
