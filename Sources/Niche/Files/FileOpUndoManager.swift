import Foundation

/// 文件操作撤销栈(spec §4.5 注④)。
///
/// `NSWorkspace.recycle` 不挂 Finder 的 ⌘Z undo 栈 —— 它只返回"原 URL → 废纸篓 URL"映射。
/// 所以"⌘Z 撤销删除/移动/重命名"必须 Niche 自建。MVP 至少撤销最近一次;"从废纸篓恢复"
/// 不依赖本栈(始终可用)。
struct FileOperationRecord: Equatable {
    enum Kind: Equatable {
        case trash(original: URL, trashed: URL)   // recycle 返回的映射
        case move(from: URL, to: URL)
        case copy(created: URL)                   // 撤销 = 删除副本(进废纸篓)
        case rename(from: URL, to: URL)
    }
    let kind: Kind
}

/// 撤销执行所需的最小文件能力(便于单测注入)。
protocol UndoFileService {
    func moveItem(at: URL, to: URL) throws
    func trashItem(at: URL) throws
}

extension FileManager: UndoFileService {
    // `moveItem(at:to:)` 由 FileManager 原生提供,直接满足协议要求。
    // 这里只补一个丢弃返回值的 `trashItem(at:)` 便捷重载。
    func trashItem(at url: URL) throws {
        try trashItem(at: url, resultingItemURL: nil)
    }
}

@MainActor
final class FileOpUndoManager {
    private(set) var stack: [FileOperationRecord] = []
    private let service: UndoFileService
    /// 栈深上限:MVP 只承诺最近一次,但留少量历史更友好。
    private let limit: Int

    init(service: UndoFileService = FileManager.default, limit: Int = 20) {
        self.service = service
        self.limit = limit
    }

    var canUndo: Bool { !stack.isEmpty }

    func record(_ record: FileOperationRecord) {
        stack.append(record)
        if stack.count > limit { stack.removeFirst(stack.count - limit) }
    }

    /// 撤销最近一次操作。返回被撤销的记录(nil 表示栈空)。
    @discardableResult
    func undoLast() throws -> FileOperationRecord? {
        guard let record = stack.popLast() else { return nil }
        switch record.kind {
        case let .trash(original, trashed):
            // 从废纸篓挪回原位。
            try service.moveItem(at: trashed, to: original)
        case let .move(from, to):
            try service.moveItem(at: to, to: from)
        case let .copy(created):
            // 撤销复制 = 把副本扔进废纸篓(可恢复,不真删)。
            try service.trashItem(at: created)
        case let .rename(from, to):
            try service.moveItem(at: to, to: from)
        }
        return record
    }
}
