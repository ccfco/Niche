import Foundation
import Observation
import Testing
@testable import Niche

/// `@Observable` 迁移后的显式副作用回调契约:视图靠属性级追踪,宿主副作用靠这些回调。
/// 新测试用 Swift Testing(增量迁移;既有 XCTest 保留,待单独一轮再迁)。
@MainActor
@Suite("PanelModel Observation 回调契约")
struct PanelModelObservationTests {
    @Test("排序与切 tab 会通知宿主副作用")
    func sortOrderAndTabSwitchNotifyHost() throws {
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
        #expect(changes > 0, "排序变化必须触发宿主副作用")

        let before = changes
        model.selectTab(1)
        #expect(changes > before, "切 tab 必须触发宿主副作用")
    }

    @Test("只有当前 mirror 的变化汇入宿主")
    func onlyCurrentMirrorNotifiesHost() throws {
        let a = try TestSupport.makeTempDir()
        let b = try TestSupport.makeTempDir()
        defer {
            TestSupport.cleanup(a)
            TestSupport.cleanup(b)
        }
        let model = PanelModel()
        model.rebuildMirrors(from: [FolderBinding(path: a.path), FolderBinding(path: b.path)])

        #expect(model.mirrors[0].onChange != nil)
        #expect(model.mirrors[1].onChange == nil, "后台 tab 不应把变化汇入宿主副作用")

        model.selectTab(1)
        #expect(model.mirrors[0].onChange == nil)
        #expect(model.mirrors[1].onChange != nil)
    }

    @Test("光标回调收到新 id")
    func cursorChangeReceivesNewID() {
        let model = PanelModel()
        var seen: [FileItem.ID?] = []
        model.onCursorChange = { seen.append($0) }
        let url = URL(fileURLWithPath: "/tmp/niche-observation/a.txt")

        model.selectSingle(url)
        #expect(seen.last ?? nil == url)
    }

    @Test("重命名回调只在布尔态翻转时触发")
    func renamingCallbacksOnlyOnTransition() {
        let model = PanelModel()
        var events: [Bool] = []
        model.onRenamingItemChange = { events.append($0) }
        let a = URL(fileURLWithPath: "/tmp/niche-observation/a.txt")
        let b = URL(fileURLWithPath: "/tmp/niche-observation/b.txt")

        model.beginRename(a)
        #expect(events == [true])
        model.beginRename(b)   // A→B 仍是 active,不应重复 begin
        #expect(events == [true])
        model.endRename()
        #expect(events == [true, false])
    }

    @Test("路径输入条显隐回调成对触发")
    func pathInputVisibilityCallback() {
        let model = PanelModel()
        var events: [Bool] = []
        model.onPathInputVisibilityChange = { events.append($0) }

        model.beginPathInput()
        model.endPathInput()
        #expect(events == [true, false])
    }

    /// 回归:`sortedItems` 命中缓存时只读 `itemsVersion`,必须让它参与 Observation,
    /// 否则视图在目录内容变化后收不到失效通知(缓存命中路径没有任何可观察依赖)。
    @Test("sortedItems 缓存命中仍随 mirror 内容失效")
    func sortedItemsTracksMirrorContentThroughCache() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.cleanup(dir) }
        try TestSupport.touch(dir.appendingPathComponent("a.txt"))

        let model = PanelModel()
        model.rebuildMirrors(from: [FolderBinding(path: dir.path)])
        let mirror = try #require(model.currentMirror)
        mirror.arm()
        await TestSupport.waitUntil { mirror.items.count == 1 }

        _ = model.sortedItems   // 预热排序缓存,后续读取走 cache hit
        let flag = ObservationFlag()
        withObservationTracking {
            _ = model.sortedItems
        } onChange: {
            flag.value = true
        }

        try TestSupport.touch(dir.appendingPathComponent("b.txt"))
        mirror.refresh()
        #expect(flag.value, "缓存命中路径也必须登记可观察依赖")
    }
}

/// `withObservationTracking` 的 onChange 是 @Sendable,用最小盒子跨执行器记录命中。
private final class ObservationFlag: @unchecked Sendable {
    var value = false
}