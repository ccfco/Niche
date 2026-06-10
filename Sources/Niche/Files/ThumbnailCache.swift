import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 缩略图缓存(spec §4.4:后台 ImageIO 解码 + 缓存上限,**禁止 row 渲染路径同步解码**;
/// 解码前先判 iCloud dataless 跳过,避免无意触发下载 §4.1.2)。
///
/// 只对图片类文件做 ImageIO 降采样解码;非图片/占位文件返回 nil → cell 退回系统图标。
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "com.ccfco.Niche.thumbnail", qos: .utility, attributes: .concurrent)

    init(countLimit: Int = 512) {
        cache.countLimit = countLimit
    }

    /// 缓存键:路径 + 修改时间 + 目标尺寸 → 文件被改后自动失效;不同 maxPixel 各占一格,
    /// 防将来两模式用不同缩略图尺寸时低清覆盖高清(或反之)互相污染。
    private func key(for item: FileItem, maxPixel: CGFloat) -> NSString {
        "\(item.url.path):\(item.modificationDate.timeIntervalSince1970):\(Int(maxPixel))" as NSString
    }

    /// 异步取缩略图。dataless / 非图片 / 解码失败 → nil(调用方退回系统图标)。
    func thumbnail(for item: FileItem, maxPixel: CGFloat) async -> NSImage? {
        // dataless:绝不触发下载(spec §4.1.2)。
        guard !item.isDataless else { return nil }
        // 仅图片类型走 ImageIO;其余交给系统图标。
        guard item.contentType?.conforms(to: .image) == true else { return nil }

        let cacheKey = key(for: item, maxPixel: maxPixel)
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
