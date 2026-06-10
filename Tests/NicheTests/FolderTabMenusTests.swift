import XCTest
@testable import Niche

/// tab 栏菜单(「+」添加菜单 / tab 右键菜单):构成、动作分发、抑制驱动与时序
/// (popUp 模态追踪测不了,测 makeMenu + delegate 回调)。
@MainActor
final class FolderTabMenusTests: XCTestCase {
    func testAddMenuItemsAndActions() {
        var chose = false
        var wentToPath = false
        let presenter = AddFolderMenuPresenter(
            autoHide: AutoHideCoordinator(),
            onChooseFolder: { chose = true },
            onGoToPath: { wentToPath = true }
        )
        let menu = presenter.makeMenu()

        XCTAssertEqual(menu.items.map(\.title), ["添加文件夹…", "前往路径…"])
        // ⇧⌘G 提示展示在「前往路径…」上(发现入口,派发本体在面板键盘权威)。
        XCTAssertEqual(menu.items[1].keyEquivalent, "g")
        XCTAssertEqual(menu.items[1].keyEquivalentModifierMask, [.command, .shift])

        for item in menu.items {
            _ = item.target.map { NSApp.sendAction(item.action!, to: $0, from: item) }
        }
        XCTAssertTrue(chose)
        XCTAssertTrue(wentToPath)
    }

    func testTabMenuRemovesCorrectBinding() {
        var removed: FolderBinding.ID?
        let binding = FolderBinding(path: "/tmp")
        let presenter = TabContextMenuPresenter(
            autoHide: AutoHideCoordinator(),
            onRemove: { removed = $0 }
        )
        let menu = presenter.makeMenu(for: binding.id)

        XCTAssertEqual(menu.items.map(\.title), ["移除此文件夹"])
        let item = menu.items[0]
        _ = item.target.map { NSApp.sendAction(item.action!, to: $0, from: item) }
        XCTAssertEqual(removed, binding.id)
    }

    /// 关菜单解除抑制 → 补隐推迟一拍兑现(菜单开着移出走廊不收,关了才收)。
    func testMenuDelegateDrivesSuppression() {
        let autoHide = AutoHideCoordinator()
        var hidden = false
        autoHide.onShouldHide = { hidden = true }
        let presenter = AddFolderMenuPresenter(autoHide: autoHide, onChooseFolder: {}, onGoToPath: {})
        let menu = presenter.makeMenu()

        presenter.menuWillOpen(menu)
        autoHide.handleMouseLeave()          // 菜单开着,移出走廊不收(记 pendingHide)
        XCTAssertFalse(hidden)
        presenter.menuDidClose(menu)         // 解除抑制 → 下一拍兑现
        XCTAssertFalse(hidden)               // 同步路径上不收(给 action 派发留出建立新抑制的窗口)
        drainMainQueue()
        XCTAssertTrue(hidden)
        XCTAssertFalse(autoHide.isSuppressed)
    }

    /// 竞态回归(Codex review):menuDidClose 先于菜单项 action 派发 —— action 建立的新抑制
    /// (.modalDialog/.pathInput)必须接棒 pendingHide,面板不能在 NSOpenPanel/路径条出现前收回。
    func testSuppressionHandoffAcrossMenuActionGap() {
        let autoHide = AutoHideCoordinator()
        var hidden = false
        autoHide.onShouldHide = { hidden = true }

        autoHide.begin(.contextMenu)
        autoHide.handleMouseLeave()          // 菜单开着失走廊 → pendingHide
        autoHide.end(.contextMenu)           // menuDidClose
        autoHide.begin(.modalDialog)         // 同一拍内 action 派发(addFolder 挂 .modalDialog)
        drainMainQueue()
        XCTAssertFalse(hidden)               // 新抑制接棒,不得收回

        autoHide.end(.modalDialog)           // NSOpenPanel 关闭
        drainMainQueue()
        XCTAssertTrue(hidden)                // 抑制链全部解除后才兑现
    }

    /// 双发回归(Codex 复核):end() 排队兑现的空隙里 handleMouseLeave 直接收回,
    /// 待隐被消费,排队的兑现块必须短路 —— onShouldHide 只发一次。
    func testImmediateHideInGapConsumesPendingWithoutDoubleFire() {
        let autoHide = AutoHideCoordinator()
        var hideCount = 0
        autoHide.onShouldHide = { hideCount += 1 }

        autoHide.begin(.contextMenu)
        autoHide.handleMouseLeave()          // 抑制中 → pendingHide
        autoHide.end(.contextMenu)           // 排队兑现块
        autoHide.handleMouseLeave()          // 空隙里再离开:无抑制,立即收回并消费待隐
        XCTAssertEqual(hideCount, 1)
        drainMainQueue()
        XCTAssertEqual(hideCount, 1)         // 排队块短路,不双发
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }
}
