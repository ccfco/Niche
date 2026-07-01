import Foundation
import CoreServices   // MDItem(Spotlight 元数据)

/// 「项目简介」数据源 —— Finder 图标视图名称下那行副信息:图片/视频尺寸、时长、文件夹项目数、文件大小。
///
/// **尽量取访达同源,不自算**:尺寸/时长读 Spotlight 元数据(`MDItem`),即 Finder 那条简介行的来源,
/// 不解码文件、不重算;只有"文件夹项目数"索引里没有,才 `contentsOfDirectory` 现数。
///
/// **TCC 红线**:文件夹计数 = 列目录,会触发受保护目录(Desktop/Documents/Downloads)授权。本服务只在
/// **cell 渲染**(`.task`)被调 —— 即用户已打开、正浏览的目录内,该保护域此刻已被当前目录的 `arm()`
/// 授权过,列其子文件夹不再弹窗;**绝不**在启动/后台/预取里主动遍历(同 DirectoryMirror.arm 红线)。
///
/// 后台并发计算 + NSCache 缓存(同 ThumbnailCache 纪律:禁 row 同步 I/O,spec §4.4)。
final class ItemInfoCache {
    static let shared = ItemInfoCache()

    private let cache = NSCache<NSString, NSString>()
    private let queue = DispatchQueue(label: "com.ccfco.Niche.iteminfo", qos: .utility, attributes: .concurrent)

    init(countLimit: Int = 1024) {
        cache.countLimit = countLimit
    }

    /// 键:路径 + mtime + size —— 文件夹内容变(mtime 变)即重数;文件尺寸/大小随之失效重取。
    /// `static`(非 private):FileCellView 的 `.task(id:)` 直接复用,避免手拼同一串键导致漂移
    /// (改键忘了改 task id → 开关切换后不刷新)。
    static func cacheKey(for item: FileItem) -> NSString {
        "\(item.url.path)\u{1F}\(item.modificationDate.timeIntervalSince1970)\u{1F}\(item.size)" as NSString
    }

    /// 返回访达式简介串(后台算 + 缓存)。算不出返回 nil(调用方不显副行)。
    func info(for item: FileItem) async -> String? {
        let key = Self.cacheKey(for: item)
        if let cached = cache.object(forKey: key) { return cached as String }
        let computed: (text: String?, cacheable: Bool) = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Self.compute(item)) }
        }
        // 仅缓存"稳定"结果:媒体类型暂未拿到 Spotlight 元数据(索引滞后)时退回大小,但**不缓存** ——
        // 否则索引补齐后仍命中旧大小、尺寸/时长永久缺失。受保护目录跳过的 nil 同理不缓存。
        if let text = computed.text, computed.cacheable {
            cache.setObject(text as NSString, forKey: key)
        }
        return computed.text
    }

    // MARK: - 私有

    private static func compute(_ item: FileItem) -> (text: String?, cacheable: Bool) {
        if item.isDirectory {
            // TCC 红线:列受保护标准目录(Desktop/Documents/Downloads/…)会弹授权;cell 渲染是非用户
            // 动作路径 → 这些目录跳过统计(不显项目数),只在用户 arm 进入后其子项才安全计数。
            if TCCAccess.isProtected(item.url) { return (nil, false) }
            // 项目数:跳隐藏项(对齐访达默认计数口径)。失败(无权限/外部删)→ nil,不兜底假数、不缓存。
            guard let count = try? FileManager.default.contentsOfDirectory(
                at: item.url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).count
            else { return (nil, false) }
            return (String(localized: "\(count) 个项目"), true)
        }
        // 文件:优先 Spotlight 元数据(访达同源)—— 视频/音频显时长,图片显尺寸。
        // CFNumber 在 Swift 侧不保证桥成 Int/Double → 统一过 NSNumber 取值(浮点 CFNumber 也稳)。
        if let md = MDItemCreateWithURL(kCFAllocatorDefault, item.url as CFURL) {
            if let duration = (MDItemCopyAttribute(md, kMDItemDurationSeconds) as? NSNumber)?.doubleValue,
               duration > 0 {
                return (durationLabel(duration), true)
            }
            if let w = (MDItemCopyAttribute(md, kMDItemPixelWidth) as? NSNumber)?.intValue,
               let h = (MDItemCopyAttribute(md, kMDItemPixelHeight) as? NSNumber)?.intValue, w > 0, h > 0 {
                return ("\(grouped(w)) × \(grouped(h))", true)
            }
        }
        // 没拿到元数据:本应有(图片/视频)→ Spotlight 索引滞后,退大小但**不缓存**(待索引补齐重取);
        // 非媒体类型本就只显大小 → 稳定可缓存。
        let isMedia = item.contentType.map {
            $0.conforms(to: .image) || $0.conforms(to: .audiovisualContent)
        } ?? false
        return (item.sizeLabel, !isMedia)
    }

    /// 千分位整数(访达图片尺寸 "1,712 × 896")。formatter 每次新建 —— 后台并发调用,避免共享可变态竞争。
    private static func grouped(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: n as NSNumber) ?? "\(n)"
    }

    /// mm:ss(超 1 小时加时位),四舍五入到秒 —— 对齐访达(68.884s → 01:09)。
    private static func durationLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let s = total % 60, m = (total / 60) % 60, h = total / 3600
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }
}
