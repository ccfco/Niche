import XCTest
@testable import Niche

/// 底栏排序菜单(NSMenu):构成、勾选态、动作写回与抑制驱动
/// (popUp 模态追踪测不了,测 makeMenu + delegate 回调)。
///
/// model.sortOrder 的 didSet 会持久化到 UserDefaults —— 测试前后快照/还原,
/// 不污染本机真实排序偏好(同 PanelModelSelectionTests 回避设 sortOrder 的考量)。
@MainActor
final class SortMenuPresenterTests: XCTestCase {
    private var savedPrefs: Data?
    private var model: PanelModel!

    override func setUp() {
        savedPrefs = UserDefaults.standard.data(forKey: FileSortOrder.storageKey)
        model = PanelModel()
    }

    override func tearDown() {
        if let savedPrefs {
            UserDefaults.standard.set(savedPrefs, forKey: FileSortOrder.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: FileSortOrder.storageKey)
        }
    }

    /// 菜单结构 = 4 排序键 + 分隔 + 2 方向 + 分隔 + 文件夹开关。
    func testMenuStructure() {
        model.sortOrder = FileSortOrder(key: .name, direction: .ascending, directoriesFirst: false)
        let menu = SortMenuPresenter(autoHide: AutoHideCoordinator(), model: model).makeMenu()
        XCTAssertEqual(menu.items.map(\.title),
                       ["名称", "修改日期", "大小", "类型", "",
                        "升序", "降序", "",
                        "文件夹保持在最前"])
    }

    /// 勾选态实时反映当前 sortOrder(每次打开按当前态重建)。
    func testCheckmarksReflectCurrentOrder() {
        model.sortOrder = FileSortOrder(key: .size, direction: .descending, directoriesFirst: true)
        let menu = SortMenuPresenter(autoHide: AutoHideCoordinator(), model: model).makeMenu()
        func item(_ title: String) -> NSMenuItem { menu.items.first { $0.title == title }! }
        XCTAssertEqual(item("大小").state, .on)
        XCTAssertEqual(item("名称").state, .off)
        XCTAssertEqual(item("降序").state, .on)
        XCTAssertEqual(item("升序").state, .off)
        XCTAssertEqual(item("文件夹保持在最前").state, .on)
    }

    /// 点排序键 / 方向 / 开关 → 写回 model.sortOrder。
    func testActionsWriteBackToModel() {
        model.sortOrder = FileSortOrder(key: .name, direction: .ascending, directoriesFirst: false)
        let presenter = SortMenuPresenter(autoHide: AutoHideCoordinator(), model: model)
        func fire(_ title: String) {
            let item = presenter.makeMenu().items.first { $0.title == title }!
            _ = item.target.map { NSApp.sendAction(item.action!, to: $0, from: item) }
        }
        fire("大小")
        XCTAssertEqual(model.sortOrder.key, .size)
        fire("降序")
        XCTAssertEqual(model.sortOrder.direction, .descending)
        fire("文件夹保持在最前")
        XCTAssertTrue(model.sortOrder.directoriesFirst)
        fire("文件夹保持在最前")          // 再点一次 = toggle 回去
        XCTAssertFalse(model.sortOrder.directoriesFirst)
    }

    /// menuWillOpen/DidClose 驱动 .contextMenu 抑制(菜单开着鼠标移出走廊面板不收)。
    func testMenuDelegateDrivesSuppression() {
        let autoHide = AutoHideCoordinator()
        var hidden = false
        autoHide.onShouldHide = { hidden = true }
        let presenter = SortMenuPresenter(autoHide: autoHide, model: model)
        let menu = presenter.makeMenu()

        presenter.menuWillOpen(menu)
        autoHide.handleMouseLeave()          // 菜单开着,移出走廊不收
        XCTAssertFalse(hidden)
        XCTAssertTrue(autoHide.isSuppressed)
        presenter.menuDidClose(menu)
        XCTAssertFalse(autoHide.isSuppressed)
    }
}
