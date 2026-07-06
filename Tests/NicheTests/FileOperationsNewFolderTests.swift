import XCTest
@testable import Niche

/// 新建文件夹返回 URL 与镜像 id 同构(踩坑回归):
/// `appendingPathComponent(name)` 在目标尚不存在时产出**无尾斜杠** URL,而
/// `DirectorySnapshot.capture`(contentsOfDirectory)对目录产出**带尾斜杠** URL —— 二者
/// `URL ==` 不相等。FileItem.id 就是 URL,`beginRenameSafely` 用 newFolder 返回值做
/// selectSingle/beginRename,id 不同构 → 选中失效 + 重命名框永不出现(⌘⇧N 新建后没有
/// 就地重命名,实测踩过)。
@MainActor
final class FileOperationsNewFolderTests: XCTestCase {
    func testNewFolderURLMatchesSnapshotItemID() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.cleanup(dir) }
        let ops = FileOperations(undo: FileOpUndoManager())

        let created = try ops.newFolder(in: dir)

        let snapshot = try DirectorySnapshot.capture(directory: dir, showHidden: false)
        let ids = snapshot.fileItems.map(\.id)
        XCTAssertEqual(ids.count, 1)
        XCTAssertTrue(ids.contains(created),
                      "newFolder 返回 \(created.absoluteString) 不在快照 id 中:\(ids.map(\.absoluteString))")
    }

    func testNewFolderConflictURLAlsoMatchesSnapshotItemID() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.cleanup(dir) }
        let ops = FileOperations(undo: FileOpUndoManager())

        let first = try ops.newFolder(in: dir)
        let second = try ops.newFolder(in: dir)   // 同名冲突 → 「… 2」,同样要同构

        let ids = try DirectorySnapshot.capture(directory: dir, showHidden: false).fileItems.map(\.id)
        XCTAssertTrue(ids.contains(first))
        XCTAssertTrue(ids.contains(second),
                      "冲突递增名 \(second.absoluteString) 不在快照 id 中:\(ids.map(\.absoluteString))")
    }
}
