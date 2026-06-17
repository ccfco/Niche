import AppKit
import ImageIO
import UniformTypeIdentifiers
import QuickLookThumbnailing

/// 缩略图/图标缓存(spec §4.4:后台解码 + 缓存上限,**禁止 row 渲染路径同步解码**;
/// 解码前先判 iCloud dataless 跳过,避免无意触发下载 §4.1.2)。
///
/// 两类产出,各自独立缓存键(不共键,防静默返回错误产物):
/// - **图片内容缩略图**(`img:` 键,含 mtime):ImageIO 降采样,内容变即失效。
/// - **Finder 彩色图标**(`icon:` 键,含 tags、**不含 mtime**):`QLThumbnailGenerator .icon`
///   —— Finder 给文件/文件夹画图标的同一渲染器,原生带**标签色**(文件夹整体染色 / 文件右下角
///   圆点)、自定义图标、角标。公开的 `NSWorkspace.icon(forFile:)` / `effectiveIconKey` 都
///   **不带**标签色(实测均返回蓝文件夹),只有 QL `.icon` 拿得到 Finder 那个红文件夹。图标只取决于
///   类型/标签/自定义图标,**与内容 mtime 无关** → 键不含 mtime(编辑文件内容不白白重生成图标)。
///   仅"有标签"项才走 QL(无标签项保持即时系统图标,不为零收益做异步开销;突发量天然被"有标签"
///   这一闸限制得很小,故不引 in-flight 合并/并发上限,守「不过度工程化」)。
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "com.ccfco.Niche.thumbnail", qos: .utility, attributes: .concurrent)

    init(countLimit: Int = 512) {
        cache.countLimit = countLimit
    }

    /// 图标键:路径 + **标签** + dataless + 尺寸。**标签必须进键** —— 打 Finder 标签不改 mtime
    /// (标签写在扩展属性,非内容修改时间),不含 tags 会在换标签后命中旧(无色)缓存。
    /// **不含 mtime**:图标只随类型/标签/自定义图标变,内容编辑不该使其失效。
    /// 标签用控制字符 `\u{1F}`(Unit Separator,Finder 标签名不含它)分隔,避免 "a,b" vs "a","b" 碰撞。
    static func iconCacheKey(for item: FileItem, maxPixel: CGFloat) -> String {
        "icon:\(item.url.path)\u{1F}\(item.tags.joined(separator: "\u{1F}"))\u{1F}\(item.isDataless)\u{1F}\(Int(maxPixel))"
    }

    /// 图片内容缩略图键:路径 + **mtime** + 尺寸 → 内容被改即失效。与图标键前缀不同,二者不碰撞。
    static func imageCacheKey(for item: FileItem, maxPixel: CGFloat) -> String {
        "img:\(item.url.path)\u{1F}\(item.modificationDate.timeIntervalSince1970)\u{1F}\(Int(maxPixel))"
    }

    /// 网格单元美术:有标签 → QL `.icon`(访达彩色:文件夹染色 / 图片带圆点 / 文档带圆点);
    /// 无标签图片 → ImageIO 内容缩略图;其余 → nil(调用方退系统图标)。dataless 一律 nil。
    func thumbnail(for item: FileItem, maxPixel: CGFloat) async -> NSImage? {
        guard !item.isDataless else { return nil }
        // 有标签:整项交给 Finder 渲染器(图片也走它 → 缩略图自带圆点,与 Finder 一致)。
        if !item.tags.isEmpty { return await finderIcon(for: item, maxPixel: maxPixel) }
        // 无标签:仅图片走 ImageIO 内容缩略图,其余退系统图标。
        guard item.contentType?.conforms(to: .image) == true else { return nil }
        return await imageThumbnail(for: item, maxPixel: maxPixel)
    }

    /// 小图标 / 列表用:仅"有标签"返回 QL `.icon`(访达彩色图标);否则 nil(退系统类型图标,
    /// 不给列表引入内容缩略图,保持列表"类型图标"现状不变)。dataless 一律 nil。
    func taggedIcon(for item: FileItem, maxPixel: CGFloat) async -> NSImage? {
        guard !item.isDataless, !item.tags.isEmpty else { return nil }
        return await finderIcon(for: item, maxPixel: maxPixel)
    }

    // MARK: - 私有

    private func imageThumbnail(for item: FileItem, maxPixel: CGFloat) async -> NSImage? {
        let cacheKey = Self.imageCacheKey(for: item, maxPixel: maxPixel) as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }
        let url = item.url
        let image: NSImage? = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.decode(url: url, maxPixel: maxPixel))
            }
        }
        if let image { cache.setObject(image, forKey: cacheKey) }
        return image
    }

    /// QL `.icon` = Finder 图标渲染器,原生含标签色 / 圆点 / 自定义图标。异步生成,结果按
    /// icon 键缓存。失败返回 nil → 调用方退系统图标。
    private func finderIcon(for item: FileItem, maxPixel: CGFloat) async -> NSImage? {
        let cacheKey = Self.iconCacheKey(for: item, maxPixel: maxPixel) as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }
        let points = max(1, maxPixel / 2)   // size 为 points,scale 2 → 输出 ~maxPixel 像素
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: points, height: points),
            scale: 2,
            representationTypes: .icon
        )
        let image: NSImage? = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                continuation.resume(returning: rep?.nsImage)
            }
        }
        if let image { cache.setObject(image, forKey: cacheKey) }
        return image
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
