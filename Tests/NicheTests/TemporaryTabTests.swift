import XCTest
@testable import Niche

/// 临时 tab(路径输入「前往」)状态机:单槽替换、rebuild 保留、钉住让位、关闭回落。
@MainActor
final class TemporaryTabTests: XCTestCase {
    private var dirA: URL!
    private var dirB: URL!
    private var model: PanelModel!

    override func setUp() async throws {
        dirA = try TestSupport.makeTempDir()
        dirB = try TestSupport.makeTempDir()
        model = PanelModel()
        model.rebuildMirrors(from: [FolderBinding(path: dirA.path)])
    }

    override func tearDown() {
        TestSupport.cleanup(dirA)
        TestSupport.cleanup(dirB)
    }

    func testOpenTemporaryAppendsSingleSlotAndSelects() {
        model.openTemporary(dirB)
        XCTAssertEqual(model.mirrors.count, 2)
        XCTAssertTrue(model.currentMirror?.isTemporary ?? false)
        XCTAssertEqual(model.currentMirror?.rootURL.standardizedFileURL, dirB.standardizedFileURL)

        // 单槽:再次前往即替换,不增 tab。
        model.openTemporary(dirA.appendingPathComponent(""))
        XCTAssertEqual(model.mirrors.count, 2)
        XCTAssertEqual(model.mirrors.filter(\.isTemporary).count, 1)
    }

    func testRebuildPreservesTemporaryTab() {
        model.openTemporary(dirB)
        // 模拟设置页改绑定触发重建:临时 tab 不来自绑定列表,必须原样保留。
        model.rebuildMirrors(from: [FolderBinding(path: dirA.path)])
        XCTAssertEqual(model.mirrors.filter(\.isTemporary).count, 1)
        XCTAssertEqual(model.temporaryMirror?.rootURL.standardizedFileURL, dirB.standardizedFileURL)
    }

    func testPinnedPathEvictsTemporarySlot() {
        model.openTemporary(dirB)
        // 钉住 = 同路径进入绑定列表 → 重建时临时槽让位(避免同一文件夹双 tab)。
        let pinned = FolderBinding(path: dirB.path)
        model.rebuildMirrors(from: [FolderBinding(path: dirA.path), pinned], selecting: pinned.id)
        XCTAssertNil(model.temporaryMirror)
        XCTAssertEqual(model.currentMirror?.binding.id, pinned.id)
    }

    func testCloseTemporaryFallsBackToFormalTab() {
        model.openTemporary(dirB)
        model.closeTemporary()
        XCTAssertNil(model.temporaryMirror)
        XCTAssertEqual(model.mirrors.count, 1)
        XCTAssertFalse(model.currentMirror?.isTemporary ?? true)
    }

    func testPathInputStateLifecycle() {
        XCTAssertFalse(model.pathInputVisible)
        model.beginPathInput(initial: "/")
        XCTAssertTrue(model.pathInputVisible)
        XCTAssertEqual(model.pathInputInitial, "/")
        let token = model.pathInputFocusToken
        model.beginPathInput(initial: "~")          // 再次触发 → 聚焦代次自增
        XCTAssertGreaterThan(model.pathInputFocusToken, token)
        model.endPathInput()
        XCTAssertFalse(model.pathInputVisible)
        XCTAssertEqual(model.pathInputInitial, "")
    }
}
