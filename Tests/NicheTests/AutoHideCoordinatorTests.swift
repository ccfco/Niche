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

        c.end(.quickLook)             // 抑制解除 → 补隐
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
        XCTAssertEqual(hideCount, 0)  // 还有 contextMenu 抑制
        c.end(.contextMenu)
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
}
