import XCTest
import AppKit
@testable import Niche

final class WindowModeTests: XCTestCase {
    func testToggleSwitchesBetweenModes() {
        XCTAssertEqual(WindowMode.transient.toggled, .pinned)
        XCTAssertEqual(WindowMode.pinned.toggled, .transient)
    }

    func testTransientHidesOnResignKeyPinnedDoesNot() {
        XCTAssertTrue(WindowMode.transient.hidesOnResignKey)
        XCTAssertFalse(WindowMode.pinned.hidesOnResignKey)
    }

    func testBothModesCanBecomeKeyForTextEditing() {
        // spec §4.6:nonactivating 瞬态面板也需 canBecomeKey 以承载键盘导航/就地重命名。
        XCTAssertTrue(WindowMode.transient.canBecomeKey)
        XCTAssertTrue(WindowMode.pinned.canBecomeKey)
    }

    func testOnlyPinnedCanBecomeMain() {
        XCTAssertFalse(WindowMode.transient.canBecomeMain)
        XCTAssertTrue(WindowMode.pinned.canBecomeMain)
    }

    func testLevelsDiffer() {
        XCTAssertEqual(WindowMode.transient.level, .statusBar)
        XCTAssertEqual(WindowMode.pinned.level, .floating)
    }

    func testTransientJoinsAllSpacesAndIgnoresCycle() {
        let behavior = WindowMode.transient.collectionBehavior
        XCTAssertTrue(behavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(behavior.contains(.ignoresCycle))
    }
}
