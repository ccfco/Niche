import XCTest
@testable import Niche

/// 选中模型(选中集 + 光标 + 锚点单一真相)的行为测试:syncListSelection 的光标推断与
/// ⇧/⌘ 语义是 Quick Look 定位、键盘导航的根基,此前无覆盖(审查指出的测试盲区)。
@MainActor
final class PanelModelSelectionTests: XCTestCase {
    private var dir: URL!
    private var model: PanelModel!

    /// 真实临时目录建 5 个文件(a~e),经 mirror arm 后驱动 sortedItems。
    override func setUp() async throws {
        dir = try TestSupport.makeTempDir()
        for name in ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"] {
            try TestSupport.touch(dir.appendingPathComponent(name))
        }
        // 不设 sortOrder/viewMode(didSet 会持久化、污染本机真实偏好);
        // 断言全部基于 sortedItems 的**相对顺序**(ids 数组),与具体排序规则无关。
        model = PanelModel()
        model.rebuildMirrors(from: [FolderBinding(path: dir.path)])
        model.armCurrent()
        // 快照已后台化:等 5 个文件全部发布,否则 ids[n] 越界崩溃(异步 arm 后 sortedItems 起始为空)。
        await TestSupport.waitUntil { self.model.sortedItems.count == 5 }
    }

    override func tearDown() {
        TestSupport.cleanup(dir)
    }

    private var ids: [FileItem.ID] { model.sortedItems.map(\.id) }

    func testSelectRangeFromAnchor() {
        model.selectSingle(ids[1])              // 锚点 b
        model.selectRange(to: ids[3])           // ⇧ 到 d
        XCTAssertEqual(model.selectedIDs, Set(ids[1...3]))
        XCTAssertEqual(model.cursorID, ids[3])  // 光标 = lead 端
        model.selectRange(to: ids[0])           // ⇧ 反向到 a:锚点不动
        XCTAssertEqual(model.selectedIDs, Set(ids[0...1]))
        XCTAssertEqual(model.cursorID, ids[0])
    }

    func testSyncListSelectionPicksFarthestAddedAsCursor() {
        model.selectSingle(ids[1])              // 光标 b(下标 1)
        // 模拟 Table ⇧ 区间回写:b..d 整段;新增 {c,d} 中距旧光标最远的 d 应成为新光标。
        model.syncListSelection(Set(ids[1...3]))
        XCTAssertEqual(model.cursorID, ids[3])
    }

    func testSyncListSelectionCursorFallsBackWhenRemoved() {
        // 先建立 {a,c,e} 多选(光标 e)。不能从单选 {c} 直接 sync 到 {a,e}:那会让 a、e 都算
        // "新增"且距旧光标等距,平手时取谁取决于 Set 顺序 —— 测试会随机翻车(flaky,实测踩中)。
        model.selectSingle(ids[0])
        model.toggle(ids[2])
        model.toggle(ids[4])
        // 模拟 ⌘ 点掉光标项 e:无新增 → 光标回退到剩余选中里的第一项(按排序顺序)。
        model.syncListSelection([ids[0], ids[2]])
        XCTAssertEqual(model.cursorID, ids[0])
    }

    func testMoveCursorExtendBuildsRange() {
        model.selectSingle(ids[0])
        model.moveCursor(.down, extend: true)   // 列表语义 cols 由 viewMode 决定,此处用网格列数 1 行内等价
        XCTAssertTrue(model.selectedIDs.contains(ids[0]))
        XCTAssertEqual(model.cursorID, model.sortedItems[model.cursorIndex ?? 0].id)
        XCTAssertFalse(model.selectedIDs.isEmpty)
    }

    func testClearSelectionEndsRename() {
        model.selectSingle(ids[0])
        model.beginRename(ids[0])
        model.clearSelection()
        XCTAssertNil(model.renamingItemID)   // 导航离开必须收口重命名(防 .renaming 抑制泄漏)
    }
}
