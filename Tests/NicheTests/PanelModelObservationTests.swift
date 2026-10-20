import XCTest
@testable import Niche

/// `@Observable` 迁移后的显式副作用回调契约:视图靠属性级追踪,宿主副作用靠这些回调。
@MainActor
final class PanelModelObservationTests: XCTestCase {
    func testOnChangeFiresForSortOrderAndTabSwitch() async throws {
        let a = try TestSupport.makeTempDir()
        let b = try TestSupport.makeTempDir()
        defer {
            TestSupport.cleanup(a)
            TestSupport.cleanup(b)
        }
        let model = PanelModel()
        model.rebuildMirrors(from: [FolderBinding(path: a.path), FolderBinding(path: b.path)])

        var changes = 0
        model.onChange = { changes += 1 }

        model.sortOrder.key = .date
        XCTAssertGreaterThan(changes, 0, "排序变化必须触发宿主副作用")

        let before = changes
        model.selectTab(1)
        XCTAssertGreaterThan(changes, before, "切 tab 必须触发宿主副作用")
    }

    func testOnlyCurrentMirrorGetsChangeCallback() async throws {
        let a = try TestSupport.makeTempDir()
        let b = try TestSupport.makeTempDir()
        defer {
            TestSupport.cleanup(a)
            TestSupport.cleanup(b)
        }
        let model = PanelModel()
        model.rebuildMirrors(from: [FolderBinding(path: a.path), FolderBinding(path: b.path)])

        XCTAssertNotNil(model.mirrors[0].onChange)
        XCTAssertNil(model.mirrors[1].onChange, "后台 tab 不应把变化汇入宿主副作用")

        model.selectTab(1)
        XCTAssertNil(model.mirrors[0].onChange)
        XCTAssertNotNil(model.mirrors[1].onChange)
    }

    func testCursorChangeCallbackReceivesNewID() {
        let model = PanelModel()
        var seen: [FileItem.ID?] = []
        model.onCursorChange = { seen.append($0) }
        let url = URL(fileURLWithPath: "/tmp/niche-observation/a.txt")

        model.selectSingle(url)
        XCTAssertEqual(seen.last ?? nil, url)
    }

    func testRenamingCallbacksFireOnlyOnBoolTransition() {
        let model = PanelModel()
        var events: [Bool] = []
        model.onRenamingItemChange = { events.append($0) }
        let a = URL(fileURLWithPath: "/tmp/niche-observation/a.txt")
        let b = URL(fileURLWithPath: "/tmp/niche-observation/b.txt")

        model.beginRename(a)
        XCTAssertEqual(events, [true])
        model.beginRename(b)   // A→B 仍是 active,不应重复 begin
        XCTAssertEqual(events, [true])
        model.endRename()
        XCTAssertEqual(events, [true, false])
    }

    func testPathInputVisibilityCallback() {
        let model = PanelModel()
        var events: [Bool] = []
        model.onPathInputVisibilityChange = { events.append($0) }

        model.beginPathInput()
        model.endPathInput()
        XCTAssertEqual(events, [true, false])
    }
}