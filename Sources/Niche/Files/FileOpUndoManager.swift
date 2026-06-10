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

/// 重做记录(⇧⌘Z)。**不是 FileOperationRecord 的镜像**:撤销「复制」把副本移进了废纸篓,
/// 重做需要副本在废纸篓里的位置(撤销执行时才得到);重做「移废纸篓」会产生全新的废纸篓
/// URL(需写回 undo 栈)。所以 redo 栈携带撤销时产生的位置信息,自成一型。
enum FileOperationRedoRecord: Equatable {
    case trash(original: URL)                     // 重做 = 再移废纸篓(新废纸篓 URL 重做时取得)
    case move(from: URL, to: URL)                 // 重做 = 再移动
    case copyRestore(created: URL, trashed: URL)  // 重做 = 把副本从废纸篓挪回原位
    case rename(from: URL, to: URL)               // 重做 = 再改名
}

/// 撤销执行所需的最小文件能力(便于单测注入)。
protocol UndoFileService {
    func moveItem(at: URL, to: URL) throws
    /// 移废纸篓并返回落点(redo 需要该位置才能恢复)。
    func trashItemReturningURL(at: URL) throws -> URL
}

extension FileManager: UndoFileService {
    // `moveItem(at:to:)` 由 FileManager 原生提供,直接满足协议要求。
    func trashItemReturningURL(at url: URL) throws -> URL {
        var result: NSURL?
        try trashItem(at: url, resultingItemURL: &result)
        guard let trashed = result as URL? else { throw CocoaError(.fileNoSuchFile) }
        return trashed
    }
}

@MainActor
final class FileOpUndoManager {
    private(set) var stack: [FileOperationRecord] = []
    private(set) var redoStack: [FileOperationRedoRecord] = []
    private let service: UndoFileService
    /// 栈深上限:MVP 只承诺最近一次,但留少量历史更友好。
    private let limit: Int

    init(service: UndoFileService = FileManager.default, limit: Int = 20) {
        self.service = service
        self.limit = limit
    }

    var canUndo: Bool { !stack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func record(_ record: FileOperationRecord) {
        stack.append(record)
        if stack.count > limit { stack.removeFirst(stack.count - limit) }
        // 新操作作废重做分支(标准 undo/redo 语义:历史不是树)。
        redoStack.removeAll()
    }

    /// 撤销最近一次操作。返回被撤销的记录(nil 表示栈空)。
    /// **先执行后出栈**:恢复动作抛错(目标被占用/卷未挂载等)时记录留在栈顶,
    /// 用户修正外部条件后可重试 —— 先 popLast 会把记录弄丢,撤销机会一次性蒸发。
    @discardableResult
    func undoLast() throws -> FileOperationRecord? {
        guard let record = stack.last else { return nil }
        let redo: FileOperationRedoRecord
        switch record.kind {
        case let .trash(original, trashed):
            // 从废纸篓挪回原位。
            try service.moveItem(at: trashed, to: original)
            redo = .trash(original: original)
        case let .move(from, to):
            try service.moveItem(at: to, to: from)
            redo = .move(from: from, to: to)
        case let .copy(created):
            // 撤销复制 = 把副本扔进废纸篓(可恢复,不真删);落点供重做恢复。
            let trashed = try service.trashItemReturningURL(at: created)
            redo = .copyRestore(created: created, trashed: trashed)
        case let .rename(from, to):
            try service.moveItem(at: to, to: from)
            redo = .rename(from: from, to: to)
        }
        stack.removeLast()
        redoStack.append(redo)
        return record
    }

    /// 重做最近一次撤销。返回被重做的记录(nil 表示栈空)。
    /// 与 undo 同款先执行后出栈;成功后把(更新过位置的)记录推回 undo 栈,可再次撤销。
    @discardableResult
    func redoLast() throws -> FileOperationRedoRecord? {
        guard let redo = redoStack.last else { return nil }
        switch redo {
        case let .trash(original):
            let trashed = try service.trashItemReturningURL(at: original)
            stack.append(.init(kind: .trash(original: original, trashed: trashed)))
        case let .move(from, to):
            try service.moveItem(at: from, to: to)
            stack.append(.init(kind: .move(from: from, to: to)))
        case let .copyRestore(created, trashed):
            try service.moveItem(at: trashed, to: created)
            stack.append(.init(kind: .copy(created: created)))
        case let .rename(from, to):
            try service.moveItem(at: from, to: to)
            stack.append(.init(kind: .rename(from: from, to: to)))
        }
        redoStack.removeLast()
        return redo
    }
}
