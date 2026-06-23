import Foundation
import UniformTypeIdentifiers

/// 网格里的一个条目 = 指向磁盘真实文件/目录的入口(镜像语义,非快照拷贝)。
///
/// 字段由一次批量 `resourceValues` 读取填充,避免 row 渲染路径上逐属性 I/O。
/// `isDataless` 用 `ubiquitousItemDownloadingStatusKey` 判定(spec §4.1.2:**不**靠 .icloud
/// 后缀),缩略图/预览路径据此跳过未下载文件,绝不为出缩略图触发下载。
struct FileItem: Identifiable, Equatable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isHidden: Bool
    let size: Int64
    let modificationDate: Date
    let contentType: UTType?
    /// iCloud 占位符:文件未下载到本地(dataless)。非 iCloud 项恒为 false。
    let isDataless: Bool
    /// Finder 彩色标签名(`tagNamesKey`)。
    let tags: [String]

    /// macOS 26 文件夹自定义外观(emoji/符号/颜色)指纹。空串 = 无外观。仅文件夹有值。
    /// 详见 `folderIconSignature(of:)`:外观一变指纹即变 → 穿透 `Equatable`(刷新)与图标缓存键(重渲染)。
    let folderIconSignature: String

    var id: URL { url }

    /// 「种类」排序键(与 FileSortOrder.kind 分支同源:用 contentType identifier)。
    /// Table 表头排序只用它来生成 KeyPathComparator,真实顺序仍由 FileSortOrder.comparator 决定。
    var kindSortKey: String { contentType?.identifier ?? "" }

    /// 字节大小展示串(访达同款 ByteCountFormatter .file)。目录无意义,由调用方决定是否显示。
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }

    /// 读 Finder 彩色标签 —— **必须清缓存**:`contentsOfDirectory(includingPropertiesForKeys:)`
    /// 批量预取的 `tagNamesKey` 在返回 URL 的缓存里**不可靠、返回空**(实测枚举读空、清缓存重读才得
    /// 真实标签)。单一权威:`load` 与右键菜单(ContextMenuBuilder)共用,任一处忘清缓存就读到空 →
    /// toggle 只增不减的 bug 复发。
    static func tags(of url: URL) -> [String] {
        var u = url
        u.removeAllCachedResourceValues()
        return (try? u.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
    }

    /// macOS 26 文件夹自定义外观存于 `com.apple.icon.folder*` 扩展属性(实测 symbol 在
    /// `com.apple.icon.folder#S`,值为 JSON `{"sym":"figure.stand"}`)。**只有 QL `.icon` 渲染得出**
    /// —— `NSWorkspace.icon` 对纯 xattr 外观返回普通文件夹(实测对照,与既有"标签色只有 QL 拿得到"同理)。
    ///
    /// 这里把该前缀下所有 xattr 的「键=值」整体当**黑盒指纹**:不解析 JSON 格式,emoji/符号/颜色
    /// 任何变体、系统未来新增后缀都自动覆盖(守「不硬编码会失效的值」)。打外观不改 mtime
    /// (写在 xattr,非内容修改)→ 必须靠指纹进 `Equatable` 才能让面板察觉变化、穿过空发布拦截。
    /// 区分三态:**有外观**(返回非空指纹)/ **无外观**(返回 "")/ **读失败**——读失败不能
    /// 静默降级成 ""(否则有外观的文件夹会被误判无外观、且不刷新),故对 `ERANGE`(两次
    /// listxattr 间属性表变大)有限次重试拿一致快照;空值属性保留键名以与"属性不存在"区分。
    static func folderIconSignature(of url: URL) -> String {
        let path = url.path
        // ERANGE 重试:属性表在两次调用间变大时重测 size;有限次防极端高频写下死循环。
        var names = [CChar]()
        var resolved = false
        for _ in 0..<4 {
            let listLen = listxattr(path, nil, 0, 0)
            guard listLen > 0 else { return "" }   // 0 = 无任何 xattr;-1 = 文件没了/读失败 → 当无外观
            var buf = [CChar](repeating: 0, count: listLen)
            let got = listxattr(path, &buf, listLen, 0)
            if got >= 0 { names = Array(buf.prefix(got)); resolved = true; break }
            if errno != ERANGE { return "" }       // 非 ERANGE:文件被删等,当无外观
        }
        guard resolved else { return "" }          // 连续 ERANGE 耗尽重试:放弃本次,下次重扫修正
        // 属性名为 null 分隔;筛出 com.apple.icon.folder 前缀并排序(顺序稳定 → 指纹确定)。
        let iconKeys = names
            .split(separator: 0)
            .compactMap { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
            .filter { $0.hasPrefix("com.apple.icon.folder") }
            .sorted()
        guard !iconKeys.isEmpty else { return "" }
        var parts: [String] = []
        for key in iconKeys {
            let vLen = getxattr(path, key, nil, 0, 0, 0)
            guard vLen >= 0 else { continue }       // -1 读失败:跳过该键(不与空值混为一谈)
            guard vLen > 0 else { parts.append("\(key)="); continue }   // 空值:保留键名以区分"无此属性"
            var vBuf = [UInt8](repeating: 0, count: vLen)
            let vGot = getxattr(path, key, &vBuf, vLen, 0, 0)
            guard vGot >= 0 else { continue }
            parts.append("\(key)=\(String(decoding: vBuf.prefix(vGot), as: UTF8.self))")
        }
        return parts.joined(separator: "\u{1F}")
    }

    /// 资源键集合 —— 一次性批量取,喂给 `load(url:)`。
    static let resourceKeys: Set<URLResourceKey> = [
        .nameKey,
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .isHiddenKey,
        .fileSizeKey,
        .totalFileSizeKey,
        .contentModificationDateKey,
        .contentTypeKey,
        .ubiquitousItemDownloadingStatusKey,
        .isUbiquitousItemKey,
        .tagNamesKey,
    ]

    init(
        url: URL,
        name: String,
        isDirectory: Bool,
        isHidden: Bool,
        size: Int64,
        modificationDate: Date,
        contentType: UTType?,
        isDataless: Bool,
        tags: [String],
        folderIconSignature: String
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isHidden = isHidden
        self.size = size
        self.modificationDate = modificationDate
        self.contentType = contentType
        self.isDataless = isDataless
        self.tags = tags
        self.folderIconSignature = folderIconSignature
    }

    /// 从磁盘 URL 加载(批量 resourceValues)。读取失败的字段退化为安全默认,不抛——
    /// 镜像要容忍外部随时改/删文件(spec §4.1)。
    static func load(url: URL) -> FileItem {
        let values = try? url.resourceValues(forKeys: resourceKeys)

        // 标签清缓存单独读(其余字段预取可靠,照用 values);WHY 见 tags(of:)。
        let tags = Self.tags(of: url)
        // 外观仅文件夹有意义:只对目录读 xattr,省去对每个文件的 listxattr 开销。
        // 软链指向文件夹时 .isDirectoryKey 报 false(软链本身不是目录)——按 Finder 语义解析
        // 目标再判:指向文件夹的软链当文件夹(双击下钻 / 排在文件夹组 / 可作拖入目标)。只有软链
        // 才多付一次解析 I/O,普通文件/目录走首两个分支零额外开销(守 row 渲染路径不逐属性 I/O)。
        let isDirectory: Bool = {
            if values?.isDirectory == true { return true }
            guard values?.isSymbolicLink == true else { return false }
            return (try? url.resolvingSymlinksInPath()
                .resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        }()
        let folderIconSignature = isDirectory ? Self.folderIconSignature(of: url) : ""

        let isUbiquitous = values?.isUbiquitousItem ?? false
        let downloadingStatus = values?.ubiquitousItemDownloadingStatus
        // dataless = 是 iCloud 项且下载状态不是 .current(尚未下到本地)。
        let isDataless = isUbiquitous && downloadingStatus != nil && downloadingStatus != .current

        return FileItem(
            url: url,
            name: values?.name ?? url.lastPathComponent,
            isDirectory: isDirectory,
            isHidden: values?.isHidden ?? false,
            size: Int64(values?.totalFileSize ?? values?.fileSize ?? 0),
            modificationDate: values?.contentModificationDate ?? .distantPast,
            contentType: values?.contentType,
            isDataless: isDataless,
            tags: tags,
            folderIconSignature: folderIconSignature
        )
    }
}
