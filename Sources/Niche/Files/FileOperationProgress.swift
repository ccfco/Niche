import Foundation

/// 文件操作进度(UI 用值类型):按「项」推进,不伪造字节级进度。
///
/// 大目录 copy/move 的耗时主要在逐项 I/O;单文件内部不 chunked copy(那会滑向自研文件引擎),
/// 因此单项操作显示 indeterminate,多项操作显示「已完成/总数」。macOS 27 的 `ProgressManager`
/// 可在此之上叠字节级进度,但当前 UI 不需要它也能给出准确的操作级反馈。
struct FileOperationProgress: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case copy
        case move
        case compress

        var title: String {
            switch self {
            case .copy: String(localized: "正在复制")
            case .move: String(localized: "正在移动")
            case .compress: String(localized: "正在压缩")
            }
        }
    }

    let kind: Kind
    let completed: Int
    let total: Int
    /// 当前正在处理的条目名(仅展示;取消/完成时可为空)。
    let currentName: String?

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(completed) / Double(total), 0), 1)
    }

    /// 单项操作无法给出有意义的比例,让 UI 显示 spinner 而不是 0%。
    var isIndeterminate: Bool { total <= 1 }
}

/// 文件操作并发保护:同一时刻只允许一个批量操作,避免两个 copy/move 在目标目录互相踩。
enum FileOperationError: LocalizedError, Equatable {
    case busy

    var errorDescription: String? {
        switch self {
        case .busy: String(localized: "另一个文件操作正在进行")
        }
    }
}