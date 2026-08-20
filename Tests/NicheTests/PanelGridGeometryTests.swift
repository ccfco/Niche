import XCTest
@testable import Niche

final class PanelGridGeometryTests: XCTestCase {
    private let edge = EdgeMetrics.standard

    func testPreferredWidthFitsSixReadableCellsExactly() {
        let width = PanelGridGeometry.preferredPanelWidth(edge: edge)

        XCTAssertEqual(width, 736, accuracy: 0.001)
        XCTAssertEqual(PanelGridGeometry.columnCount(panelWidth: width, iconSize: 52, edge: edge), 6)
    }

    func testLegacyWidthDropsColumnsInsteadOfCompressingNames() {
        XCTAssertEqual(PanelGridGeometry.columnCount(panelWidth: 568, iconSize: 52, edge: edge), 4)
    }

    func testLargerIconsReduceColumnsWithoutChangingReadableFloor() {
        let width = PanelGridGeometry.preferredPanelWidth(edge: edge)

        XCTAssertEqual(PanelGridGeometry.columnCount(panelWidth: width, iconSize: 96, edge: edge), 5)
        XCTAssertEqual(PanelGridGeometry.columnCount(panelWidth: width, iconSize: 128, edge: edge), 4)
    }

    func testNarrowScreenClampsPanelAndKeepsItInsideVisibleWidth() {
        let width = PanelGridGeometry.panelWidth(preferredWidth: 900, visibleWidth: 620, edge: edge)

        XCTAssertEqual(width, 588, accuracy: 0.001)
        XCTAssertLessThan(width, 620)
        XCTAssertEqual(PanelGridGeometry.columnCount(panelWidth: width, iconSize: 52, edge: edge), 4)
    }

    func testPreferredWidthIsIndependentFromColumnTargets() {
        let width = PanelGridGeometry.panelWidth(preferredWidth: 843, visibleWidth: 1512, edge: edge)

        XCTAssertEqual(width, 843, accuracy: 0.001)
        XCTAssertEqual(PanelGridGeometry.columnCount(panelWidth: width, iconSize: 52, edge: edge), 6)
    }

    func testPreferredHeightOnlyClampsToVisibleScreen() {
        XCTAssertEqual(PanelGridGeometry.panelHeight(preferredHeight: 537, visibleHeight: 900, edge: edge),
                       537, accuracy: 0.001)
        XCTAssertEqual(PanelGridGeometry.panelHeight(preferredHeight: 900, visibleHeight: 620, edge: edge),
                       588, accuracy: 0.001)
    }
}
