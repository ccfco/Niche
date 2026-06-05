import Foundation

/// 排序规则(spec §4.4:名称 / 修改日期 / 大小 / 类型)。
struct FileSortOrder: Equatable, Codable {
    enum Key: String, Codable, CaseIterable {
        case name, date, size, kind
    }
    enum Direction: String, Codable {
        case ascending, descending
    }

    var key: Key = .name
    var direction: Direction = .ascending
    /// 目录恒排在文件之前(与 Finder 同款,不受 key 影响)。
    var directoriesFirst: Bool = true

    static let `default` = FileSortOrder()

    /// 生成可直接喂给 `sorted(by:)` 的比较器。同序值用名称做稳定 tiebreaker。
    func comparator() -> (FileItem, FileItem) -> Bool {
        let ascending = direction == .ascending
        let dirsFirst = directoriesFirst

        return { lhs, rhs in
            if dirsFirst, lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory  // 目录在前,且不随升降序翻转
            }

            let ordered: Bool
            switch key {
            case .name:
                ordered = Self.compareName(lhs, rhs) == .orderedAscending
            case .date:
                if lhs.modificationDate == rhs.modificationDate {
                    return Self.compareName(lhs, rhs) == .orderedAscending
                }
                ordered = lhs.modificationDate < rhs.modificationDate
            case .size:
                if lhs.size == rhs.size {
                    return Self.compareName(lhs, rhs) == .orderedAscending
                }
                ordered = lhs.size < rhs.size
            case .kind:
                let lk = lhs.contentType?.identifier ?? ""
                let rk = rhs.contentType?.identifier ?? ""
                if lk == rk {
                    return Self.compareName(lhs, rhs) == .orderedAscending
                }
                ordered = lk.localizedCaseInsensitiveCompare(rk) == .orderedAscending
            }
            return ascending ? ordered : !ordered
        }
    }

    /// 文件名比较走 Finder 风格的本地化数字感知比较(file2 < file10)。
    private static func compareName(_ lhs: FileItem, _ rhs: FileItem) -> ComparisonResult {
        lhs.name.localizedStandardCompare(rhs.name)
    }
}
