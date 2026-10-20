import XCTest
@testable import Niche

/// 后台 tab 暂停扫描的契约:非活跃 mirror 只记脏,切回补扫;避免 N 个 tab = N 份后台全量扫描。
@MainActor
final class DirectoryMirrorActivityTests: XCTestCase {
    /// 非活跃时改 showHidden 只置脏,不立即重扫;切回 active 才把新开关反映到 items。
    func testInactiveMirrorDefersRescanUntilActivated() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.cleanup(dir) }
        try TestSupport.touch(dir.appendingPathComponent("visible.txt"))
        try TestSupport.touch(dir.appendingPathComponent(".hidden"))

        let mirror = DirectoryMirror(binding: FolderBinding(path: dir.path), showHidden: false)
        mirror.arm()
        await TestSupport.waitUntil { mirror.state == .ready }
        XCTAssertEqual(mirror.state, .ready)
        XCTAssertEqual(mirror.items.count, 1, "showHidden=false 只应看到 visible.txt")

        mirror.setActive(false)
        mirror.showHidden = true   // 非活跃:只置 needsRescan,不得立即扫描
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(mirror.items.count, 1, "非活跃 tab 不应在后台重扫")

        mirror.setActive(true)     // 切回:补扫一次
        await TestSupport.waitUntil { mirror.items.count == 2 }
        XCTAssertEqual(mirror.items.count, 2, "切回活跃后应把隐藏文件补入")
    }

    /// 切 tab 只让当前 mirror 活跃;其余保留流但暂停扫描。
    func testPanelModelMarksOnlyCurrentMirrorActive() async throws {
        let a = try TestSupport.makeTempDir()
        let b = try TestSupport.makeTempDir()
        let c = try TestSupport.makeTempDir()
        defer {
            TestSupport.cleanup(a)
            TestSupport.cleanup(b)
            TestSupport.cleanup(c)
        }

        let model = PanelModel()
        model.rebuildMirrors(from: [
            FolderBinding(path: a.path),
            FolderBinding(path: b.path),
            FolderBinding(path: c.path),
        ])
        XCTAssertEqual(model.mirrors.map(\.isActive), [true, false, false])

        model.selectTab(1)
        XCTAssertEqual(model.mirrors.map(\.isActive), [false, true, false])

        model.selectTab(2)
        XCTAssertEqual(model.mirrors.map(\.isActive), [false, false, true])
    }
}