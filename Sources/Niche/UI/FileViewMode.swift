import Foundation

/// 内容区视图模式(spec:迷你访达,列表/图标可切)。列表=原生 `Table`(NSTableView),图标=网格。
enum FileViewMode: String, CaseIterable {
    case list   // 默认:像访达的列表(名称/大小/种类,表头排序)
    case icon   // 网格

    private static let key = "niche.viewMode"

    static func load() -> FileViewMode {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return .list }
        return FileViewMode(rawValue: raw) ?? .list
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.key)
    }
}
