import XCTest
import AppKit
@testable import Niche

final class DragSemanticsTests: XCTestCase {
    func testSameVolumeDefaultsToMove() {
        XCTAssertEqual(DragSemantics.resolve(sameVolume: true, modifiers: []), .move)
    }

    func testCrossVolumeDefaultsToCopy() {
        XCTAssertEqual(DragSemantics.resolve(sameVolume: false, modifiers: []), .copy)
    }

    func testOptionForcesCopyEvenSameVolume() {
        XCTAssertEqual(DragSemantics.resolve(sameVolume: true, modifiers: [.option]), .copy)
    }

    func testCommandForcesMoveEvenCrossVolume() {
        XCTAssertEqual(DragSemantics.resolve(sameVolume: false, modifiers: [.command]), .move)
    }

    func testOptionWinsOverCommandWhenBothHeld() {
        XCTAssertEqual(DragSemantics.resolve(sameVolume: true, modifiers: [.option, .command]), .copy)
    }

    func testUnknownVolumeIsConservativeCopy() {
        XCTAssertEqual(DragSemantics.resolve(sameVolume: nil, modifiers: []), .copy)
    }

    func testSameVolumeHelperOnRealTempDir() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.cleanup(dir) }
        let a = try TestSupport.touch(dir.appendingPathComponent("a"))
        let b = try TestSupport.touch(dir.appendingPathComponent("b"))
        XCTAssertEqual(DragSemantics.isSameVolume(a, b), true)
    }
}
