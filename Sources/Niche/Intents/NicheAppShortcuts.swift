import AppIntents

/// 系统 App Shortcuts 暴露面:Shortcuts 动作列表 / Spotlight 建议 / Siri 短语。
/// 短语必须包含 `\(.applicationName)`,这是 App Intents 的硬性校验。
struct NicheAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenNicheIntent(),
            phrases: [
                "打开 \(.applicationName)",
                "呼出 \(.applicationName)",
            ],
            shortTitle: "打开 Niche 面板",
            systemImageName: "rectangle.topthird.inset.filled"
        )
        AppShortcut(
            intent: OpenFolderIntent(),
            phrases: [
                "在 \(.applicationName) 中打开 \(\.$folder)",
            ],
            shortTitle: "打开固定文件夹",
            systemImageName: "folder"
        )
    }
}