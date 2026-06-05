import Foundation

/// 同名冲突处理(spec §4.5 注②:drop 同名冲突要自己出"替换/两者都保留/跳过"提示)。
enum ConflictResolution: String, CaseIterable, Identifiable {
    case replace    // 替换
    case keepBoth   // 两者都保留(目标改名)
    case skip       // 跳过

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .replace: return "替换"
        case .keepBoth: return "两者都保留"
        case .skip: return "跳过"
        }
    }
}

enum ConflictResolver {
    /// 目标目录已存在同名时,为"两者都保留"生成不冲突的新 URL。
    /// 规则与 Finder 一致:`file.txt` → `file 2.txt` → `file 3.txt` …;无扩展名 `dir` → `dir 2`。
    static func uniqueURL(for proposed: URL, in directory: URL,
                          fileManager: FileManager = .default) -> URL {
        let ext = proposed.pathExtension
        let base = proposed.deletingPathExtension().lastPathComponent

        var candidate = proposed
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let newName = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(newName)
            counter += 1
        }
        return candidate
    }

    /// 目标是否已存在同名项(决定是否需要弹冲突提示)。
    static func hasConflict(name: String, in directory: URL,
                            fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: directory.appendingPathComponent(name).path)
    }
}
