import XCTest
import AppKit
@testable import Niche

@MainActor
final class AutoHideCoordinatorTests: XCTestCase {
    func testResignKeyWithNoSuppressionHides() {
        let c = AutoHideCoordinator()
        var hid = false
        c.onShouldHide = { hid = true }
        c.handleResignKey(newKeyWindow: nil)
        XCTAssertTrue(hid)
    }

    func testResignKeyWhileSuppressedDefersThenHidesOnRelease() {
        let c = AutoHideCoordinator()
        var hideCount = 0
        c.onShouldHide = { hideCount += 1 }

        c.begin(.quickLook)           // Quick Look 活跃
        c.handleResignKey(newKeyWindow: nil)
        XCTAssertEqual(hideCount, 0)  // 被抑制,不隐藏

        c.end(.quickLook)             // 抑制解除 → 下一拍补隐(给后继抑制留接棒窗口)
        XCTAssertEqual(hideCount, 0)
        drainMainQueue()
        XCTAssertEqual(hideCount, 1)
    }

    func testMultipleSuppressorsAllMustReleaseBeforeDeferredHide() {
        let c = AutoHideCoordinator()
        var hideCount = 0
        c.onShouldHide = { hideCount += 1 }

        c.begin(.dragging)
        c.begin(.contextMenu)
        c.handleResignKey(newKeyWindow: nil)
        c.end(.dragging)
        drainMainQueue()
        XCTAssertEqual(hideCount, 0)  // 还有 contextMenu 抑制
        c.end(.contextMenu)
        drainMainQueue()
        XCTAssertEqual(hideCount, 1)
    }

    func testFocusToOwnedAuxiliaryWindowDoesNotHide() {
        let c = AutoHideCoordinator()
        let aux = NSWindow()
        c.ownedWindows = { [aux] }
        var hid = false
        c.onShouldHide = { hid = true }

        c.handleResignKey(newKeyWindow: aux)  // 焦点转到自己的辅助窗口
        XCTAssertFalse(hid)
    }

    func testEndingSuppressorWithoutPendingHideDoesNothing() {
        let c = AutoHideCoordinator()
        var hideCount = 0
        c.onShouldHide = { hideCount += 1 }
        c.begin(.renaming)
        c.end(.renaming)              // 没有 pending 失焦 → 不该补隐
        XCTAssertEqual(hideCount, 0)
        XCTAssertFalse(c.isSuppressed)
    }

    /// 拖出(面板作 drag 源)期间抑制隐藏;拖出结束且焦点已离开 → 补隐("拖出即走")。
    func testDraggingOutSuppressesThenHidesOnEnd() {
        let c = AutoHideCoordinator()
        var hideCount = 0
        c.onShouldHide = { hideCount += 1 }

        c.begin(.draggingOut)                  // 拖出开始
        c.handleResignKey(newKeyWindow: nil)   // 拖到别的 app,面板失焦
        XCTAssertEqual(hideCount, 0)           // 拖出中,抑制
        c.end(.draggingOut)                    // 拖出结束
        drainMainQueue()
        XCTAssertEqual(hideCount, 1)           // 补隐:拖出即走
    }

    /// 同名抑制源重入:嵌套 begin(集中式 withModalContext 内再调 presentFailure)须 begin/end 平衡
    /// 配对,内层 end 不得抹掉外层仍需的抑制。Set 实现会在内层 end 处误判 active 空 → 模态期间收回。
    func testReentrantSuppressorRequiresBalancedRelease() {
        let c = AutoHideCoordinator()
        var hideCount = 0
        c.onShouldHide = { hideCount += 1 }

        c.begin(.modalDialog)                  // 外层(doMoveTo 的 presentModal)
        c.begin(.modalDialog)                  // 嵌套(catch 里 presentFailure 又一层)
        c.handleResignKey(newKeyWindow: nil)   // 模态成 key,面板失焦
        c.end(.modalDialog)                    // 内层结束 —— 外层仍持有
        drainMainQueue()
        XCTAssertEqual(hideCount, 0)           // 仍被抑制(Set 实现此处会误隐)
        c.end(.modalDialog)                    // 外层结束
        drainMainQueue()
        XCTAssertEqual(hideCount, 1)           // 全部解除 → 补隐
    }

    /// 补隐兑现推迟一拍(NSMenu 的 didClose 先于 action 派发,给后继抑制留接棒窗口)。
    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }
}
