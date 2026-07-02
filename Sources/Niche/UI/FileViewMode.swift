import Foundation

/// 内容区视图模式(spec:迷你访达,列表/图标可切)。列表=原生 `Table`(NSTableView),图标=网格。
enum FileViewMode: String, CaseIterable {
    case list   // 像访达的列表(名称/大小/种类,表头排序)
    case icon   // 默认:网格,更贴近"随手取用"的直觉

    private static let key = "niche.viewMode"

    static func load() -> FileViewMode {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return .icon }
        return FileViewMode(rawValue: raw) ?? .icon
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.key)
    }
}
