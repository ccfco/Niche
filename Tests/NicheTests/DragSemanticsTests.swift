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

    /// 多源聚合:角标与执行共用此决策,混合来源必须整体一致(任一跨卷 → 整体 copy)。
    func testAggregateSameVolume() {
        XCTAssertEqual(DragSemantics.aggregateSameVolume([true, true]), true)
        XCTAssertEqual(DragSemantics.aggregateSameVolume([true, false]), false)   // 混合 → 整体 copy
        XCTAssertEqual(DragSemantics.aggregateSameVolume([false, nil]), false)
        XCTAssertNil(DragSemantics.aggregateSameVolume([true, nil]))              // 含未知 → 保守 copy
        XCTAssertNil(DragSemantics.aggregateSameVolume([]))
    }

    func testSameVolumeHelperOnRealTempDir() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.cleanup(dir) }
        let a = try TestSupport.touch(dir.appendingPathComponent("a"))
        let b = try TestSupport.touch(dir.appendingPathComponent("b"))
        XCTAssertEqual(DragSemantics.isSameVolume(a, b), true)
    }
}
