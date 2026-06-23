import XCTest
@testable import Niche

final class DirectorySnapshotTests: XCTestCase {
    func testDiffDetectsAddedRemovedChanged() {
        let a = TestSupport.item("a.txt", size: 1)
        let bOld = TestSupport.item("b.txt", size: 1)
        let bNew = TestSupport.item("b.txt", size: 999)   // 同 URL,大小变化 → changed
        let c = TestSupport.item("c.txt", size: 1)

        let old = DirectorySnapshot(items: [a, bOld])
        let new = DirectorySnapshot(items: [a, bNew, c])

        let diff = SnapshotDiff.between(old: old, new: new)
        XCTAssertEqual(diff.added.map(\.name), ["c.txt"])
        XCTAssertEqual(diff.changed.map(\.name), ["b.txt"])
        XCTAssertTrue(diff.removed.isEmpty)
    }

    func testRenameShowsAsRemovedPlusAdded() {
        let old = DirectorySnapshot(items: [TestSupport.item("old.txt")])
        let new = DirectorySnapshot(items: [TestSupport.item("new.txt")])
        let diff = SnapshotDiff.between(old: old, new: new)
        XCTAssertEqual(diff.added.map(\.name), ["new.txt"])
        XCTAssertEqual(diff.removed.map(\.name), ["old.txt"])
    }

    func testEmptyToNonEmpty() {
        let diff = SnapshotDiff.between(
            old: DirectorySnapshot(items: []),
            new: DirectorySnapshot(items: [TestSupport.item("x")])
        )
        XCTAssertEqual(diff.added.count, 1)
        XCTAssertFalse(diff.isEmpty)
    }

    func testIdenticalSnapshotsProduceEmptyDiff() {
        let items = [TestSupport.item("a"), TestSupport.item("b")]
        let diff = SnapshotDiff.between(
            old: DirectorySnapshot(items: items),
            new: DirectorySnapshot(items: items)
        )
        XCTAssertTrue(diff.isEmpty)
    }

    func testCaptureRealDirectoryRespectsHiddenToggle() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.cleanup(dir) }
        try TestSupport.touch(dir.appendingPathComponent("visible.txt"))
        try TestSupport.touch(dir.appendingPathComponent(".hidden"))

        let shown = try DirectorySnapshot.capture(directory: dir, showHidden: false)
        XCTAssertEqual(shown.fileItems.map(\.name).sorted(), ["visible.txt"])

        let all = try DirectorySnapshot.capture(directory: dir, showHidden: true)
        XCTAssertEqual(all.fileItems.map(\.name).sorted(), [".hidden", "visible.txt"])
    }

    /// 指向目录的软链:URL 版 contentsOfDirectory 不跟随(报 256,非权限错),capture 须解析真实
    /// 目录列举、子项 URL 重建回软链路径体系 —— 否则软链文件夹进去就「列目录失败」被误判 TCC。
    func testCaptureFollowsDirectorySymlink() throws {
        let root = try TestSupport.makeTempDir()
        defer { TestSupport.cleanup(root) }

        let realDir = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: false)
        try TestSupport.touch(realDir.appendingPathComponent("a.txt"))
        try FileManager.default.createDirectory(
            at: realDir.appendingPathComponent("subdir"), withIntermediateDirectories: false)

        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realDir)

        let snap = try DirectorySnapshot.capture(directory: link.standardizedFileURL, showHidden: false)
        XCTAssertEqual(Set(snap.fileItems.map(\.name)), ["a.txt", "subdir"])

        // 子项 URL 必须重建回软链路径体系(在 link 之下),保证下钻坐标一致、不越界。
        let linkPrefix = link.standardizedFileURL.path
        for item in snap.fileItems {
            XCTAssertTrue(item.url.standardizedFileURL.path.hasPrefix(linkPrefix),
                          "子项 \(item.url.path) 应在软链路径 \(linkPrefix) 之下,而非真实路径")
        }
    }
}
