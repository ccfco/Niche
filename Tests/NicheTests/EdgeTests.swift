import XCTest
@testable import Niche

final class EdgeTests: XCTestCase {
    func testAllMetricsDeriveFromBaseProportionally() {
        let a = Edge(base: 8)
        let b = Edge(base: 16)   // base 翻倍

        // 每个派生值都应等比翻倍 —— 证明无组件级硬编码,全由单旋钮派生。
        XCTAssertEqual(b.panelPadding, a.panelPadding * 2, accuracy: 0.001)
        XCTAssertEqual(b.itemSpacing, a.itemSpacing * 2, accuracy: 0.001)
        XCTAssertEqual(b.innerSpacing, a.innerSpacing * 2, accuracy: 0.001)
        XCTAssertEqual(b.sectionSpacing, a.sectionSpacing * 2, accuracy: 0.001)
        XCTAssertEqual(b.panelCornerRadius, a.panelCornerRadius * 2, accuracy: 0.001)
        XCTAssertEqual(b.itemCornerRadius, a.itemCornerRadius * 2, accuracy: 0.001)
        XCTAssertEqual(b.controlCornerRadius, a.controlCornerRadius * 2, accuracy: 0.001)
    }

    func testStandardIsNonZero() {
        XCTAssertGreaterThan(Edge.standard.base, 0)
    }
}
