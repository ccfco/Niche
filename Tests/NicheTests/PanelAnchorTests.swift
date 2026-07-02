import XCTest
import CoreGraphics
@testable import Niche

final class PanelAnchorTests: XCTestCase {
    // 模拟 1920×1080 外接屏,菜单栏 24、Dock 70(可视区 y ∈ [70, 1056])。
    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let visible = CGRect(x: 0, y: 70, width: 1920, height: 986)
    private let size = CGSize(width: 600, height: 400)

    func testTopAnchorMatchesLegacyStandardFrame() {
        let notch = CGRect(x: 860, y: 1043, width: 200, height: 37)
        let target = PanelAnchor.top(notch).targetFrame(panelSize: size, visible: visible)
        XCTAssertEqual(target.midX, notch.midX, accuracy: 0.001)
        XCTAssertEqual(target.maxY, notch.minY, accuracy: 0.001)   // 顶边贴刘海底
    }

    func testCornerTargetsFlushWithVisibleCorners() {
        let rect = CGRect.zero
        let br = PanelAnchor.corner(.bottomRight, rect).targetFrame(panelSize: size, visible: visible)
        XCTAssertEqual(br.maxX, visible.maxX, accuracy: 0.001)
        XCTAssertEqual(br.minY, visible.minY, accuracy: 0.001)     // 贴可视区,自动避开 Dock
        let tl = PanelAnchor.corner(.topLeft, rect).targetFrame(panelSize: size, visible: visible)
        XCTAssertEqual(tl.minX, visible.minX, accuracy: 0.001)
        XCTAssertEqual(tl.maxY, visible.maxY, accuracy: 0.001)
    }

    func testSideTargetFollowsMouseAndClamps() {
        // 左边缘,鼠标居中:面板贴左、垂直居中于鼠标。
        let mid = PanelAnchor.side(.left, mouse: CGPoint(x: 0, y: 500))
            .targetFrame(panelSize: size, visible: visible)
        XCTAssertEqual(mid.minX, visible.minX, accuracy: 0.001)
        XCTAssertEqual(mid.midY, 500, accuracy: 0.001)
        // 下边缘,鼠标贴屏幕最右:面板夹回可视区内不越界。
        let clamped = PanelAnchor.side(.bottom, mouse: CGPoint(x: 1919, y: 0))
            .targetFrame(panelSize: size, visible: visible)
        XCTAssertEqual(clamped.maxX, visible.maxX, accuracy: 0.001)
        XCTAssertEqual(clamped.minY, visible.minY, accuracy: 0.001)
    }

    func testCollapsedFrameHugsAnchorSide() {
        let target = CGRect(x: 100, y: 70, width: 600, height: 400)
        let bottom = PanelAnchor.side(.bottom, mouse: .zero).collapsedFrame(target: target)
        XCTAssertEqual(bottom.minY, target.minY, accuracy: 0.001)
        XCTAssertEqual(bottom.width, target.width, accuracy: 0.001)
        XCTAssertLessThan(bottom.height, 10)
        let right = PanelAnchor.side(.right, mouse: .zero).collapsedFrame(target: target)
        XCTAssertEqual(right.maxX, target.maxX, accuracy: 0.001)
        XCTAssertLessThan(right.width, 10)
    }

    func testCorridorFillsGapBetweenPanelAndPhysicalEdge() {
        // 下边缘触发,面板贴可视区下沿(Dock 上方):走廊须从物理屏底一直铺到面板底。
        let target = CGRect(x: 100, y: 70, width: 600, height: 400)
        let corridor = PanelAnchor.side(.bottom, mouse: .zero)
            .corridorRect(target: target, screenFrame: screen)
        XCTAssertEqual(corridor.minY, screen.minY, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(corridor.maxY, target.minY - 0.001)
    }

    func testGrowsUpwardOnlyForBottomAnchors() {
        XCTAssertTrue(PanelAnchor.side(.bottom, mouse: .zero).growsUpward)
        XCTAssertTrue(PanelAnchor.corner(.bottomLeft, .zero).growsUpward)
        XCTAssertFalse(PanelAnchor.top(.zero).growsUpward)
        XCTAssertFalse(PanelAnchor.side(.left, mouse: .zero).growsUpward)
        XCTAssertFalse(PanelAnchor.corner(.topRight, .zero).growsUpward)
    }
}
