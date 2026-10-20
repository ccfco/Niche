import AppIntents

/// 从 Shortcuts / Spotlight 呼出面板。`show()` 只保证可见(Pin 态则把常驻窗叫回来),
/// 不做 toggle —— 与菜单栏「呼出 Niche」同一语义。
struct OpenNicheIntent: AppIntent {
    static let title: LocalizedStringResource = "打开 Niche"
    static let description = IntentDescription("呼出刘海面板。")
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let controller = IntentBridge.shared.controller else {
            throw NicheIntentError.notReady
        }
        controller.show()
        return .result()
    }
}

/// 直接打开某个固定文件夹:切到对应 tab 再确保面板可见。文件夹已在设置里被移除时明确报错,
/// 而不是静默打开一个无关 tab。
struct OpenFolderIntent: AppIntent {
    static let title: LocalizedStringResource = "在 Niche 中打开文件夹"
    static let description = IntentDescription("在刘海面板中打开固定的文件夹。")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "文件夹")
    var folder: FolderEntity

    static var parameterSummary: some ParameterSummary {
        Summary("在 Niche 中打开 \(\.$folder)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let controller = IntentBridge.shared.controller else {
            throw NicheIntentError.notReady
        }
        guard let id = UUID(uuidString: folder.id), controller.showFolder(id) else {
            throw NicheIntentError.folderUnavailable(folder.name)
        }
        return .result()
    }
}