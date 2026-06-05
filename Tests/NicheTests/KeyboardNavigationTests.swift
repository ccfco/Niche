import XCTest
@testable import Niche

final class KeyboardNavigationTests: XCTestCase {
    func testEmptyCollectionNeverCrashesAndStaysNil() {
        let sel = GridSelection(index: nil)
        XCTAssertNil(sel.moved(.down, columns: 4, count: 0).index)
        XCTAssertNil(sel.moved(.up, columns: 4, count: 0).index)
    }

    func testNoSelectionDownGoesToFirst() {
        XCTAssertEqual(GridSelection(index: nil).moved(.down, columns: 4, count: 10).index, 0)
    }

    func testNoSelectionUpGoesToLast() {
        XCTAssertEqual(GridSelection(index: nil).moved(.up, columns: 4, count: 10).index, 9)
    }

    func testRightAndLeftWithinBounds() {
        XCTAssertEqual(GridSelection(index: 2).moved(.right, columns: 4, count: 10).index, 3)
        XCTAssertEqual(GridSelection(index: 2).moved(.left, columns: 4, count: 10).index, 1)
    }

    func testLeftClampsAtZero() {
        XCTAssertEqual(GridSelection(index: 0).moved(.left, columns: 4, count: 10).index, 0)
    }

    func testRightClampsAtLast() {
        XCTAssertEqual(GridSelection(index: 9).moved(.right, columns: 4, count: 10).index, 9)
    }

    func testDownMovesByColumnCount() {
        XCTAssertEqual(GridSelection(index: 1).moved(.down, columns: 4, count: 10).index, 5)
    }

    func testDownStaysWhenNoRowBelow() {
        // index 8 (count 10, cols 4):8+4=12 越界 → 保持 8。
        XCTAssertEqual(GridSelection(index: 8).moved(.down, columns: 4, count: 10).index, 8)
    }

    func testUpMovesByColumnCount() {
        XCTAssertEqual(GridSelection(index: 5).moved(.up, columns: 4, count: 10).index, 1)
    }

    func testUpStaysOnFirstRow() {
        XCTAssertEqual(GridSelection(index: 2).moved(.up, columns: 4, count: 10).index, 2)
    }

    func testFirstAndLastJump() {
        XCTAssertEqual(GridSelection(index: 5).moved(.first, columns: 4, count: 10).index, 0)
        XCTAssertEqual(GridSelection(index: 5).moved(.last, columns: 4, count: 10).index, 9)
    }

    func testSingleColumnFallbackWhenColumnsZero() {
        // columns<=0 时按 1 列处理,down 即下一项。
        XCTAssertEqual(GridSelection(index: 0).moved(.down, columns: 0, count: 3).index, 1)
    }
}
