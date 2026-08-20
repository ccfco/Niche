import XCTest
import AppKit
@testable import Niche

@MainActor
final class WindowModeTests: XCTestCase {
    func testToggleSwitchesBetweenModes() {
        XCTAssertEqual(WindowMode.transient.toggled, .pinned)
        XCTAssertEqual(WindowMode.pinned.toggled, .transient)
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

    func testDraggingFilePresentationIsFasterThanHoverPresentation() {
        let hover = PanelController.presentationAnimation(source: .standard, reduceMotion: false)
        let drag = PanelController.presentationAnimation(source: .draggingFile, reduceMotion: false)
        XCTAssertTrue(hover.animatesFrame)
        XCTAssertTrue(drag.animatesFrame)
        XCTAssertLessThan(drag.duration, hover.duration)
    }

    func testReduceMotionPresentationAndDismissalNeverAnimateFrame() {
        let present = PanelController.presentationAnimation(source: .standard, reduceMotion: true)
        let dismiss = PanelController.dismissalAnimation(reduceMotion: true)
        XCTAssertFalse(present.animatesFrame)
        XCTAssertFalse(dismiss.animatesFrame)
    }
}
