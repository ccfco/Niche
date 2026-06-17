import XCTest
@testable import Niche

/// 缩略图/图标缓存键的不变量。两类产出各自独立键,且各只对相关变化敏感。
final class ThumbnailCacheKeyTests: XCTestCase {
    // MARK: 图标键(QL .icon)

    /// 核心坑:打 Finder 标签不改 mtime,图标键必须含 tags,否则换标签后命中旧(无色)缓存。
    func testIconKeyVariesWithTags() {
        let untagged = TestSupport.item("Nexus", dir: true, tags: [])
        let tagged = TestSupport.item("Nexus", dir: true, tags: ["红色"])
        XCTAssertNotEqual(
            ThumbnailCache.iconCacheKey(for: untagged, maxPixel: 96),
            ThumbnailCache.iconCacheKey(for: tagged, maxPixel: 96)
        )
    }

    /// 图标只随类型/标签变,**与内容 mtime 无关** —— 编辑文件内容不该让红文件夹白白重生成。
    func testIconKeyIgnoresMtime() {
        let early = TestSupport.item("Nexus", dir: true, date: Date(timeIntervalSince1970: 0), tags: ["红色"])
        let late = TestSupport.item("Nexus", dir: true, date: Date(timeIntervalSince1970: 9999), tags: ["红色"])
        XCTAssertEqual(
            ThumbnailCache.iconCacheKey(for: early, maxPixel: 96),
            ThumbnailCache.iconCacheKey(for: late, maxPixel: 96)
        )
    }

    /// 分隔符碰撞:["a","b"] 与 ["a,b"] 不能产同键(标签名可能含逗号)。
    func testIconKeyNoSeparatorCollision() {
        let two = TestSupport.item("f", tags: ["a", "b"])
        let one = TestSupport.item("f", tags: ["a,b"])
        XCTAssertNotEqual(
            ThumbnailCache.iconCacheKey(for: two, maxPixel: 96),
            ThumbnailCache.iconCacheKey(for: one, maxPixel: 96)
        )
    }

    func testIconKeyVariesWithMaxPixel() {
        let i = TestSupport.item("f.png", tags: ["蓝色"])
        XCTAssertNotEqual(
            ThumbnailCache.iconCacheKey(for: i, maxPixel: 96),
            ThumbnailCache.iconCacheKey(for: i, maxPixel: 32)
        )
    }

    // MARK: 图片内容缩略图键(ImageIO)

    /// 图片缩略图随内容 mtime 失效。
    func testImageKeyVariesWithMtime() {
        let early = TestSupport.item("f.png", date: Date(timeIntervalSince1970: 0))
        let late = TestSupport.item("f.png", date: Date(timeIntervalSince1970: 9999))
        XCTAssertNotEqual(
            ThumbnailCache.imageCacheKey(for: early, maxPixel: 96),
            ThumbnailCache.imageCacheKey(for: late, maxPixel: 96)
        )
    }

    /// 图标键与图片键前缀不同,绝不碰撞。
    func testIconAndImageKeysNeverCollide() {
        let i = TestSupport.item("f.png", tags: ["蓝色"])
        XCTAssertNotEqual(
            ThumbnailCache.iconCacheKey(for: i, maxPixel: 96),
            ThumbnailCache.imageCacheKey(for: i, maxPixel: 96)
        )
    }
}
