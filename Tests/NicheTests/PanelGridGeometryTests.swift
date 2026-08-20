import XCTest
@testable import Niche

@MainActor
final class PanelGridGeometryTests: XCTestCase {
    private let edge = EdgeMetrics.standard

    func testNewUserDefaultWidthKeepsReadableCellsWithoutEncodingAColumnTarget() {
        let width = PanelModel.defaultPanelWidth

        XCTAssertEqual(width, 680, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(
            (width - edge.panelPadding * 2 - edge.itemSpacing * 4) / 5,
            PanelGridGeometry.minimumCellWidth(edge: edge)
        )
    }

    func testLegacyWidthDropsColumnsInsteadOfCompressingNames() {
        XCTAssertEqual(PanelGridGeometry.columnCount(panelWidth: 568, iconSize: 52, edge: edge), 4)
    }

    func testLargerIconsReduceColumnsWithoutChangingReadableFloor() {
        let width = PanelModel.defaultPanelWidth

        XCTAssertEqual(PanelGridGeometry.columnCount(panelWidth: width, iconSize: 96, edge: edge), 4)
        XCTAssertEqual(PanelGridGeometry.columnCount(panelWidth: width, iconSize: 128, edge: edge), 3)
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
