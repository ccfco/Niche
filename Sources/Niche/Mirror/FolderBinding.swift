import Foundation

/// 一个绑定的真实文件夹。
///
/// 持久化策略(spec §4.1 / §7):本 app 不沙盒、有完整磁盘访问,**不用 security-scoped
/// bookmark**(那是沙盒专属机制)。这里存普通 bookmark(用于追踪重命名/移动)+ 当前解析
/// 出的路径。bookmark 解析失败时回退到路径。
struct FolderBinding: Identifiable, Codable, Equatable {
    let id: UUID
    /// 普通 bookmark 数据(非 security-scoped);可为空时退化为纯路径。
    var bookmarkData: Data?
    /// 最近一次解析出的 POSIX 路径(展示/回退用)。
    var path: String
    /// tab 显示名(默认取最后一段路径,用户可改)。
    var displayName: String

    init(id: UUID = UUID(), bookmarkData: Data? = nil, path: String, displayName: String? = nil) {
        self.id = id
        self.bookmarkData = bookmarkData
        self.path = path
        self.displayName = displayName ?? (path as NSString).lastPathComponent
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}
