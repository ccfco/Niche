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
}
