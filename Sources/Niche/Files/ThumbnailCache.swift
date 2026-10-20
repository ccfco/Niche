import AppKit
import ImageIO
import Synchronization
import UniformTypeIdentifiers
import QuickLookThumbnailing

/// 缩略图/图标缓存(spec §4.4:后台解码 + 缓存上限,**禁止 row 渲染路径同步解码**;
/// 解码前先判 iCloud dataless 跳过,避免无意触发下载 §4.1.2)。
///
/// 三类产出,各自独立缓存键(不共键,防静默返回错误产物):
/// - **图片内容缩略图**(`img:` 键,含 mtime):ImageIO 降采样,内容变即失效。
/// - **视频/PDF 等内容缩略图**(`ql:` 键,含 mtime):`QLThumbnailGenerator .thumbnail`
///   —— Finder 图标视图同源(视频首帧 / PDF 首页),补上 ImageIO 覆盖不到的媒体类型。
/// - **Finder 彩色图标**(`icon:` 键,含 tags、**不含 mtime**):`QLThumbnailGenerator .icon`
///   —— Finder 给文件/文件夹画图标的同一渲染器,原生带**标签色**(文件夹整体染色 / 文件右下角
///   圆点)、自定义图标、角标。公开的 `NSWorkspace.icon(forFile:)` / `effectiveIconKey` 都
///   **不带**标签色(实测均返回蓝文件夹),只有 QL `.icon` 拿得到 Finder 那个红文件夹。图标只取决于
///   类型/标签/自定义图标,**与内容 mtime 无关** → 键不含 mtime(编辑文件内容不白白重生成图标)。
///
/// 路由规则见 `route(for:)`:媒体优先内容缩略图(标签点由文件名单独呈现),只有文件夹外观/
/// 非媒体文档才退回 QL `.icon`;同一缓存键的并发请求合并成一个生成任务。
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "com.ccfco.Niche.thumbnail", qos: .utility, attributes: .concurrent)
    /// 同一 key 的在途生成任务:快速滚动/重渲染时避免对同一文件重复跑 ImageIO/QL。
    private let inFlight = Mutex<[String: Task<NSImage?, Never>]>([:])

    init(countLimit: Int = 512) {
        cache.countLimit = countLimit
    }

    /// 内容缩略图的路由(单一真相,测试直接钉住):媒体优先内容预览;文件夹外观与非媒体文档
    /// 才用 Finder 图标渲染器(标签色/自定义外观只有它画得出)。
    enum Route: Equatable {
        case none
        case finderIcon
        case image
        case quickLook
    }

    static func route(for item: FileItem) -> Route {
        if item.isDataless { return .none }
        // 文件夹自定义外观(emoji/符号/颜色)只有 QL `.icon` 渲染得出,优先于标签判断。
        if !item.folderIconSignature.isEmpty { return .finderIcon }
        if item.contentType?.conforms(to: .image) == true { return .image }
        if supportsQuickLookThumbnail(item.contentType) { return .quickLook }
        // 非媒体文档/文件夹的标签色依赖 Finder 渲染器;媒体已在上面走内容缩略图,
        // 标签点由 FileCellView 的文件名旁 TagDotsView 承担,不再牺牲内容预览。
        if !item.tags.isEmpty { return .finderIcon }
        return .none
    }

    /// 图标键:路径 + **标签** + **文件夹外观指纹** + dataless + 尺寸。标签/外观都写在 xattr、
    /// **不改 mtime** —— 不进键会在换标签/换外观后命中旧缓存。**不含 mtime**:图标只随
    /// 类型/标签/外观变,内容编辑不该使其失效。用 `\u{1F}`(Unit Separator)分隔,避免拼接碰撞。
    static func iconCacheKey(for item: FileItem, maxPixel: CGFloat) -> String {
        "icon:\(item.url.path)\u{1F}\(item.tags.joined(separator: "\u{1F}"))\u{1F}\(item.folderIconSignature)\u{1F}\(item.isDataless)\u{1F}\(Int(maxPixel))"
    }

    /// 图片内容缩略图键:路径 + **mtime** + 尺寸 → 内容被改即失效。与图标键前缀不同,二者不碰撞。
    static func imageCacheKey(for item: FileItem, maxPixel: CGFloat) -> String {
        "img:\(item.url.path)\u{1F}\(item.modificationDate.timeIntervalSince1970)\u{1F}\(Int(maxPixel))"
    }

    /// QL 内容缩略图键(视频首帧 / PDF 首页):路径 + **mtime** + 尺寸;与 img/icon 前缀隔离。
    static func quickLookCacheKey(for item: FileItem, maxPixel: CGFloat) -> String {
        "ql:\(item.url.path)\u{1F}\(item.modificationDate.timeIntervalSince1970)\u{1F}\(Int(maxPixel))"
    }

    /// 文件专属系统图标键(自定义图标 / 标签色之外的文件本身图标)。不含 mtime:图标不随内容编辑变;
    /// 含文件夹外观指纹,换 emoji/颜色后重取。
    static func systemIconCacheKey(for item: FileItem, maxPixel: CGFloat) -> String {
        "sys:\(item.url.path)\u{1F}\(item.folderIconSignature)\u{1F}\(Int(maxPixel))"
    }

    /// 哪些类型走 QL `.thumbnail`:ImageIO 不覆盖、但 Finder 图标视图会渲染内容预览的媒体类型。
    /// 图片仍走 ImageIO(更快);文档类按需扩展(Office/Pages 的 QL 生成可能依赖第三方插件,先不引入)。
    static func supportsQuickLookThumbnail(_ type: UTType?) -> Bool {
        guard let type else { return false }
        return type.conforms(to: .movie)
            || type.conforms(to: .pdf)
            || type.conforms(to: .audiovisualContent)
    }

    /// 网格单元美术:按 `route(for:)` 走内容缩略图或 Finder 彩色图标。dataless 一律 nil。
    func thumbnail(for item: FileItem, maxPixel: CGFloat) async -> NSImage? {
        switch Self.route(for: item) {
        case .none:       return nil
        case .finderIcon: return await finderIcon(for: item, maxPixel: maxPixel)
        case .image:      return await imageThumbnail(for: item, maxPixel: maxPixel)
        case .quickLook:  return await quickLookThumbnail(for: item, maxPixel: maxPixel)
        }
    }

    /// 小图标 / 列表用:仅"有标签"返回 QL `.icon`(访达彩色图标);否则 nil(退系统类型图标,
    /// 不给列表引入内容缩略图,保持列表"类型图标"现状不变)。dataless 一律 nil。
    func taggedIcon(for item: FileItem, maxPixel: CGFloat) async -> NSImage? {
        guard !item.isDataless, !item.tags.isEmpty || !item.folderIconSignature.isEmpty else { return nil }
        return await finderIcon(for: item, maxPixel: maxPixel)
    }

    /// 文件专属系统图标(自定义图标等):后台取,避免 cell 渲染路径同步调 `NSWorkspace.icon(forFile:)`
    /// 在网络卷/首次访问时卡住 SwiftUI body。字体/尺寸按 maxPixel 缩放。
    func systemIcon(for item: FileItem, maxPixel: CGFloat) async -> NSImage? {
        let url = item.url
        let points = max(1, maxPixel / 2)
        let queue = self.queue
        return await cachedOrGenerate(Self.systemIconCacheKey(for: item, maxPixel: maxPixel)) {
            await withCheckedContinuation { continuation in
                queue.async {
                    let icon = NSWorkspace.shared.icon(forFile: url.path)
                    icon.size = NSSize(width: points, height: points)
                    continuation.resume(returning: icon)
                }
            }
        }
    }

    // MARK: - 私有

    /// 缓存 + 同一 key 的在途合并:并发调用共享一个生成任务,结果统一回写 NSCache。
    /// 锁只保护字典,绝不跨 `await` 持有。
    private func cachedOrGenerate(
        _ key: String,
        generate: @escaping @Sendable () async -> NSImage?
    ) async -> NSImage? {
        if let cached = cache.object(forKey: key as NSString) { return cached }

        let (task, isNew) = inFlight.withLock { state -> (Task<NSImage?, Never>, Bool) in
            if let existing = state[key] { return (existing, false) }
            let task = Task { [self] in
                let image = await generate()
                if let image { cache.setObject(image, forKey: key as NSString) }
                return image
            }
            state[key] = task
            return (task, true)
        }
        let image = await task.value
        // 只由创建者移除,避免第二个等待者把新一轮任务清掉。
        if isNew {
            inFlight.withLock { $0[key] = nil }
        }
        return image
    }

    private func imageThumbnail(for item: FileItem, maxPixel: CGFloat) async -> NSImage? {
        let url = item.url
        let queue = self.queue
        return await cachedOrGenerate(Self.imageCacheKey(for: item, maxPixel: maxPixel)) {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: Self.decode(url: url, maxPixel: maxPixel))
                }
            }
        }
    }

    /// QL `.icon` = Finder 图标渲染器,原生含标签色 / 圆点 / 自定义图标。异步生成,结果按
    /// icon 键缓存。失败返回 nil → 调用方退系统图标。
    private func finderIcon(for item: FileItem, maxPixel: CGFloat) async -> NSImage? {
        let url = item.url
        let points = max(1, maxPixel / 2)   // size 为 points,scale 2 → 输出 ~maxPixel 像素
        return await cachedOrGenerate(Self.iconCacheKey(for: item, maxPixel: maxPixel)) {
            await Self.quickLookImage(url: url, points: points, representation: .icon)
        }
    }

    /// QL `.thumbnail` = Finder 图标视图的内容预览(视频首帧 / PDF 首页)。结果按 ql 键
    /// (含 mtime)缓存。失败返回 nil → 调用方退系统图标。
    private func quickLookThumbnail(for item: FileItem, maxPixel: CGFloat) async -> NSImage? {
        let url = item.url
        let points = max(1, maxPixel / 2)
        return await cachedOrGenerate(Self.quickLookCacheKey(for: item, maxPixel: maxPixel)) {
            await Self.quickLookImage(url: url, points: points, representation: .thumbnail)
        }
    }

    /// 独立静态函数:让 @Sendable 生成闭包只捕获值类型,不在闭包里直接碰 QL 单例。
    private static func quickLookImage(
        url: URL, points: CGFloat,
        representation: QLThumbnailGenerator.Request.RepresentationTypes
    ) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: points, height: points),
            scale: 2,
            representationTypes: representation
        )
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                continuation.resume(returning: rep?.nsImage)
            }
        }
    }

    /// 后台 ImageIO 降采样:只解码到目标尺寸,不整图载入内存。
    private static func decode(url: URL, maxPixel: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
