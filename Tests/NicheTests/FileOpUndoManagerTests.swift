import XCTest
@testable import Niche

@MainActor
final class FileOpUndoManagerTests: XCTestCase {
    /// 记录被调用的搬运/废纸篓动作,验证 undo 走对了路径。
    final class SpyService: UndoFileService {
        var moves: [(from: URL, to: URL)] = []
        var trashed: [URL] = []
        func moveItem(at src: URL, to dst: URL) throws { moves.append((src, dst)) }
        func trashItem(at url: URL) throws { trashed.append(url) }
    }

    private func url(_ p: String) -> URL { URL(fileURLWithPath: p) }

    func testUndoTrashMovesBackFromTrash() throws {
        let spy = SpyService()
        let mgr = FileOpUndoManager(service: spy)
        let original = url("/tmp/a.txt"), trashed = url("/tmp/.Trash/a.txt")
        mgr.record(.init(kind: .trash(original: original, trashed: trashed)))

        let undone = try mgr.undoLast()
        XCTAssertEqual(undone?.kind, .trash(original: original, trashed: trashed))
        XCTAssertEqual(spy.moves.count, 1)
        XCTAssertEqual(spy.moves[0].from, trashed)
        XCTAssertEqual(spy.moves[0].to, original)
    }

    func testUndoMoveReverses() throws {
        let spy = SpyService()
        let mgr = FileOpUndoManager(service: spy)
        mgr.record(.init(kind: .move(from: url("/a/x"), to: url("/b/x"))))
        try mgr.undoLast()
        XCTAssertEqual(spy.moves[0].from, url("/b/x"))
        XCTAssertEqual(spy.moves[0].to, url("/a/x"))
    }

    func testUndoCopyTrashesTheCopy() throws {
        let spy = SpyService()
        let mgr = FileOpUndoManager(service: spy)
        mgr.record(.init(kind: .copy(created: url("/b/x"))))
        try mgr.undoLast()
        XCTAssertEqual(spy.trashed, [url("/b/x")])
        XCTAssertTrue(spy.moves.isEmpty)
    }

    func testUndoRenameReverses() throws {
        let spy = SpyService()
        let mgr = FileOpUndoManager(service: spy)
        mgr.record(.init(kind: .rename(from: url("/a/old"), to: url("/a/new"))))
        try mgr.undoLast()
        XCTAssertEqual(spy.moves[0].from, url("/a/new"))
        XCTAssertEqual(spy.moves[0].to, url("/a/old"))
    }

    func testUndoEmptyStackReturnsNil() throws {
        let mgr = FileOpUndoManager(service: SpyService())
        XCTAssertFalse(mgr.canUndo)
        XCTAssertNil(try mgr.undoLast())
    }

    func testStackHonorsLimit() {
        let mgr = FileOpUndoManager(service: SpyService(), limit: 2)
        for i in 0..<5 { mgr.record(.init(kind: .copy(created: url("/x/\(i)")))) }
        XCTAssertEqual(mgr.stack.count, 2)
    }

    /// 恢复动作可被注入失败的 service,验证"先执行后出栈"的可重试语义。
    final class FlakyService: UndoFileService {
        var failNext = true
        var moves: [(from: URL, to: URL)] = []
        func moveItem(at src: URL, to dst: URL) throws {
            if failNext { failNext = false; throw CocoaError(.fileWriteNoPermission) }
            moves.append((src, dst))
        }
        func trashItem(at url: URL) throws {}
    }

    func testFailedUndoKeepsRecordForRetry() {
        let flaky = FlakyService()
        let mgr = FileOpUndoManager(service: flaky)
        mgr.record(.init(kind: .move(from: url("/a/x"), to: url("/b/x"))))

        XCTAssertThrowsError(try mgr.undoLast())   // 首次恢复失败
        XCTAssertTrue(mgr.canUndo)                 // 记录必须留在栈顶(先执行后出栈)
        XCTAssertNoThrow(try mgr.undoLast())       // 外部条件修复后可重试
        XCTAssertFalse(mgr.canUndo)
        XCTAssertEqual(flaky.moves.count, 1)
    }
}
