import XCTest
@testable import Niche

/// 批量 copy/move 的后台执行契约:结果正确、撤销记录在完成项上、进度按项推进并收尾清空。
@MainActor
final class FileOperationsAsyncTests: XCTestCase {
    func testCopyCreatesFileAndRecordsUndo() async throws {
        let src = try TestSupport.makeTempDir()
        let dst = try TestSupport.makeTempDir()
        defer {
            TestSupport.cleanup(src)
            TestSupport.cleanup(dst)
        }
        let file = try TestSupport.touch(src.appendingPathComponent("a.txt"))
        let undo = FileOpUndoManager()
        let ops = FileOperations(undo: undo)

        try await ops.copy([file], to: dst, resolve: { _ in .replace })

        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("a.txt").path))
        XCTAssertEqual(undo.stack.count, 1, "成功复制应留下一条撤销记录")
        XCTAssertFalse(ops.isBusy)
    }

    func testCopyConflictKeepBothCreatesNumberedFile() async throws {
        let src = try TestSupport.makeTempDir()
        let dst = try TestSupport.makeTempDir()
        defer {
            TestSupport.cleanup(src)
            TestSupport.cleanup(dst)
        }
        let file = try TestSupport.touch(src.appendingPathComponent("a.txt"))
        try TestSupport.touch(dst.appendingPathComponent("a.txt"), contents: "old")
        let ops = FileOperations(undo: FileOpUndoManager())

        try await ops.copy([file], to: dst, resolve: { _ in .keepBoth })

        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("a 2.txt").path))
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("a.txt"), encoding: .utf8), "old",
                       "keepBoth 不得覆盖目标")
    }

    func testMoveRemovesSourceAndRecordsUndo() async throws {
        let src = try TestSupport.makeTempDir()
        let dst = try TestSupport.makeTempDir()
        defer {
            TestSupport.cleanup(src)
            TestSupport.cleanup(dst)
        }
        let file = try TestSupport.touch(src.appendingPathComponent("a.txt"))
        let undo = FileOpUndoManager()
        let ops = FileOperations(undo: undo)

        try await ops.move([file], to: dst, resolve: { _ in .replace })

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("a.txt").path))
        XCTAssertEqual(undo.stack.count, 1)
        XCTAssertFalse(ops.isBusy)
    }

    func testProgressReportsEachItemAndClearsAtEnd() async throws {
        let src = try TestSupport.makeTempDir()
        let dst = try TestSupport.makeTempDir()
        defer {
            TestSupport.cleanup(src)
            TestSupport.cleanup(dst)
        }
        let a = try TestSupport.touch(src.appendingPathComponent("a.txt"))
        let b = try TestSupport.touch(src.appendingPathComponent("b.txt"))
        let ops = FileOperations(undo: FileOpUndoManager())

        var events: [FileOperationProgress?] = []
        ops.onProgress = { events.append($0) }
        try await ops.copy([a, b], to: dst, resolve: { _ in .replace })

        XCTAssertEqual(events.compactMap { $0 }.first?.total, 2)
        XCTAssertEqual(events.compactMap { $0 }.last?.completed, 2)
        XCTAssertNil(events.last ?? nil, "操作结束必须清空进度行")
    }

    func testBusyGuardRejectsSecondConcurrentOperation() async throws {
        let src = try TestSupport.makeTempDir()
        let dst = try TestSupport.makeTempDir()
        defer {
            TestSupport.cleanup(src)
            TestSupport.cleanup(dst)
        }
        // 用够多的文件让首个操作在第二项之前仍在途;守卫本身是同步的,直接并发调用即可。
        let files = try (0..<200).map { i in
            try TestSupport.touch(src.appendingPathComponent("f\(i).txt"))
        }
        let ops = FileOperations(undo: FileOpUndoManager())
        let first = Task { try await ops.copy(files, to: dst, resolve: { _ in .replace }) }
        // 让首个任务先拿到 activeTask(不能等待它完成)。
        try await Task.sleep(nanoseconds: 20_000_000)
        do {
            try await ops.copy(files, to: dst, resolve: { _ in .replace })
            XCTFail("第二个操作应被 busy 守卫拒绝")
        } catch let error as FileOperationError {
            XCTAssertEqual(error, .busy)
        } catch {
            XCTFail("错误类型不符: \(error)")
        }
        _ = try? await first.value
    }
}