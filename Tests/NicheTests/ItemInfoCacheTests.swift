import XCTest
@testable import Niche

/// 文件夹项目数口径:访达默认排除隐藏项。`directoryEntryCountKey` 含隐藏项,
/// 因此只用于空目录 O(1) 短路,非空仍按可见项列目录。
final class ItemInfoCacheTests: XCTestCase {
    func testVisibleItemCountExcludesHidden() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.cleanup(dir) }
        try TestSupport.touch(dir.appendingPathComponent("a.txt"))
        try TestSupport.touch(dir.appendingPathComponent("b.txt"))
        try TestSupport.touch(dir.appendingPathComponent(".hidden"))

        XCTAssertEqual(ItemInfoCache.visibleItemCount(of: dir), 2)
        XCTAssertEqual(ItemInfoCache.directoryEntryCount(of: dir), 3,
                       "directoryEntryCountKey 包含隐藏项,不能直接当可见项目数")
    }

    func testEmptyDirectoryShortCircuitsToZero() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.cleanup(dir) }

        XCTAssertEqual(ItemInfoCache.visibleItemCount(of: dir), 0)
        XCTAssertEqual(ItemInfoCache.directoryEntryCount(of: dir), 0)
    }

    func testNonDirectoryReturnsNil() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.cleanup(dir) }
        let file = try TestSupport.touch(dir.appendingPathComponent("file.txt"))

        XCTAssertNil(ItemInfoCache.visibleItemCount(of: file))
        XCTAssertNil(ItemInfoCache.directoryEntryCount(of: file))
    }
}