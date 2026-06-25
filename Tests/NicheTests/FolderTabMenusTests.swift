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

    /// tab(根段)菜单:文件夹引用三项 + 分隔 + 书签身份两项;各动作派发正确载荷。
    func testTabMenuStructureAndDispatch() {
        let binding = FolderBinding(path: "/tmp")
        let url = URL(fileURLWithPath: "/tmp")
        var copied: [URL]?, revealed: [URL]?, info: [URL]?
        var renamed: FolderBinding.ID?, removed: FolderBinding.ID?
        let presenter = PathContextMenu(
            autoHide: AutoHideCoordinator(),
            onCopyPath: { copied = $0 },
            onReveal: { revealed = $0 },
            onShowInfo: { info = $0 },
            onRenameTab: { renamed = $0 },
            onRemove: { removed = $0 }
        )
        let menu = presenter.makeTabMenu(id: binding.id, url: url)

        XCTAssertEqual(menu.items.map(\.title),
                       ["在 Finder 中显示", "复制路径", "显示简介", "", "重命名标签…", "移除此文件夹"])
        dispatchAll(menu)
        XCTAssertEqual(revealed, [url])
        XCTAssertEqual(copied, [url])
        XCTAssertEqual(info, [url])
        XCTAssertEqual(renamed, binding.id)
        XCTAssertEqual(removed, binding.id)
    }

    /// 面包屑(子级段)菜单:仅文件夹引用三项,无书签身份操作(它不是书签)。
    func testSegmentMenuHasOnlyFolderRefItems() {
        let url = URL(fileURLWithPath: "/tmp/sub")
        var copied: [URL]?, revealed: [URL]?, info: [URL]?
        let presenter = PathContextMenu(
            autoHide: AutoHideCoordinator(),
            onCopyPath: { copied = $0 },
            onReveal: { revealed = $0 },
            onShowInfo: { info = $0 },
            onRenameTab: { _ in XCTFail("段菜单不应含「重命名标签」") },
            onRemove: { _ in XCTFail("段菜单不应含「移除此文件夹」") }
        )
        let menu = presenter.makeSegmentMenu(url: url)

        XCTAssertEqual(menu.items.map(\.title), ["在 Finder 中显示", "复制路径", "显示简介"])
        dispatchAll(menu)
        XCTAssertEqual(revealed, [url])
        XCTAssertEqual(copied, [url])
        XCTAssertEqual(info, [url])
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

    /// 派发菜单里所有非分隔项的 action(分隔项 action==nil 自动跳过)。target 是 weak,
    /// 故调用方须自留 presenter 强引用,否则 target 已释放、sendAction 静默无效。
    private func dispatchAll(_ menu: NSMenu) {
        for item in menu.items where item.action != nil {
            _ = item.target.map { NSApp.sendAction(item.action!, to: $0, from: item) }
        }
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }
}
