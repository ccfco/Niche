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

    private static let storageKey = "niche.sortOrder"

    /// 持久化(仿 FileViewMode):重启保留排序。解码失败回退默认(让问题显式,不静默)。
    static func load() -> FileSortOrder {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(FileSortOrder.self, from: data) else {
            return .default
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    // MARK: - SwiftUI Table 表头桥接(单一真相源 ↔ KeyPathComparator)

    /// 当前排序态对应的 Table 排序描述子(驱动表头排序指示箭头)。
    var tableComparator: KeyPathComparator<FileItem> {
        let order: SortOrder = direction == .ascending ? .forward : .reverse
        switch key {
        case .name: return KeyPathComparator(\FileItem.name, order: order)
        case .date: return KeyPathComparator(\FileItem.modificationDate, order: order)
        case .size: return KeyPathComparator(\FileItem.size, order: order)
        case .kind: return KeyPathComparator(\FileItem.kindSortKey, order: order)
        }
    }

    /// 把用户点表头产生的 comparator 写回真相源(key/direction)。
    /// 先把 keyPath 映射到 Key,**命中才同时写 key+direction**;未知 keyPath 整体忽略,
    /// 避免「只翻转方向但 key 不变」的箭头与状态错位(Codex review)。
    mutating func apply(_ comparator: KeyPathComparator<FileItem>) {
        let keyPath = comparator.keyPath
        let matched: Key?
        if keyPath == \FileItem.name as PartialKeyPath<FileItem> { matched = .name }
        else if keyPath == \FileItem.modificationDate as PartialKeyPath<FileItem> { matched = .date }
        else if keyPath == \FileItem.size as PartialKeyPath<FileItem> { matched = .size }
        else if keyPath == \FileItem.kindSortKey as PartialKeyPath<FileItem> { matched = .kind }
        else { matched = nil }
        guard let matched else { return }
        key = matched
        direction = comparator.order == .forward ? .ascending : .descending
    }

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
