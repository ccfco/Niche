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

    var id: URL { url }

    /// 「种类」排序键(与 FileSortOrder.kind 分支同源:用 contentType identifier)。
    /// Table 表头排序只用它来生成 KeyPathComparator,真实顺序仍由 FileSortOrder.comparator 决定。
    var kindSortKey: String { contentType?.identifier ?? "" }

    /// 资源键集合 —— 一次性批量取,喂给 `load(url:)`。
    static let resourceKeys: Set<URLResourceKey> = [
        .nameKey,
        .isDirectoryKey,
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
        tags: [String]
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
    }

    /// 从磁盘 URL 加载(批量 resourceValues)。读取失败的字段退化为安全默认,不抛——
    /// 镜像要容忍外部随时改/删文件(spec §4.1)。
    static func load(url: URL) -> FileItem {
        let values = try? url.resourceValues(forKeys: resourceKeys)

        // Finder 标签必须清缓存后单独读:`contentsOfDirectory(includingPropertiesForKeys:)` 批量
        // 预取的 `tagNamesKey` 在返回 URL 的缓存里**不可靠、返回空**(实测 app 内枚举 URL 读到空、
        // 清缓存重读才得到真实标签)。其余字段(名/大小/日期)预取可靠,照用 values。
        var tagURL = url
        tagURL.removeAllCachedResourceValues()
        let tags = (try? tagURL.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []

        let isUbiquitous = values?.isUbiquitousItem ?? false
        let downloadingStatus = values?.ubiquitousItemDownloadingStatus
        // dataless = 是 iCloud 项且下载状态不是 .current(尚未下到本地)。
        let isDataless = isUbiquitous && downloadingStatus != nil && downloadingStatus != .current

        return FileItem(
            url: url,
            name: values?.name ?? url.lastPathComponent,
            isDirectory: values?.isDirectory ?? false,
            isHidden: values?.isHidden ?? false,
            size: Int64(values?.totalFileSize ?? values?.fileSize ?? 0),
            modificationDate: values?.contentModificationDate ?? .distantPast,
            contentType: values?.contentType,
            isDataless: isDataless,
            tags: tags
        )
    }
}
