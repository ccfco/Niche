import XCTest
@testable import Niche

@MainActor
final class DirectoryMirrorStateTests: XCTestCase {
    /// 列目录失败时镜像必须进错误态,绝不被 .ready 覆盖(armAttempt 末尾旧 bug 的核心契约)。
    /// 注:probe 通过但 capture 失败是极窄竞态、无法直接单测;此处守护 captureAndPublish 的
    /// 失败契约(失败设错误态、不设 ready),即修复依赖的核心机制。
    func testCaptureFailureSetsErrorStateNotReady() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("niche-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
            try? FileManager.default.removeItem(at: tmp)
        }
        FileManager.default.createFile(atPath: tmp.appendingPathComponent("a.txt").path, contents: Data())

        let binding = FolderBinding(bookmarkData: nil, path: tmp.path)
        let mirror = DirectoryMirror(binding: binding, showHidden: false)

        mirror.arm()
        XCTAssertEqual(mirror.state, .ready, "可读目录 arm 后应 ready")

        // 撤销读权限,重扫 → capture 失败
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: tmp.path)
        mirror.refresh()

        XCTAssertEqual(mirror.state, .permissionDenied, "列目录失败必须进错误态,不得显示 ready")
    }
}
