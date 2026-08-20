import XCTest
@testable import Niche

/// 回归钉住热区命中与跨区 dwell 的两条踩坑逻辑:
/// ① 命中必须含 max 边界(CGRect.contains 排除 maxY,鼠标顶到屏幕最顶恰在被排除的上边界 → 贴边呼不出);
/// ② 跨区滑动(角落→相邻边缘重叠带)必须重起 dwell 计时,否则新区被旧区已积累的计时提前触发(Codex review)。
@MainActor
final class HotZoneHitTests: XCTestCase {
    private typealias Zone = HotZoneController.Zone

    private let corner = Zone(kind: .corner(.topLeft), rect: CGRect(x: 0, y: 900, width: 20, height: 100))
    private let side = Zone(kind: .side(.left), rect: CGRect(x: 0, y: 0, width: 4, height: 1000))
    private let primary = Zone(kind: .primary, rect: CGRect(x: 700, y: 968, width: 200, height: 32))

    // MARK: - 命中判定

    /// 鼠标顶到屏幕最顶(y == rect.maxY)必须算命中——贴边是热区的常态位置。
    func testHitIncludesMaxEdges() {
        let zones = [primary]
        XCTAssertNotNil(HotZoneController.hitZone(in: zones, mouse: CGPoint(x: 800, y: 1000)), "上边界(y=maxY)应命中")
        XCTAssertNotNil(HotZoneController.hitZone(in: zones, mouse: CGPoint(x: 900, y: 980)), "右边界(x=maxX)应命中")
        XCTAssertNil(HotZoneController.hitZone(in: zones, mouse: CGPoint(x: 800, y: 1000.5)), "越过上边界不应命中")
    }

    /// 热角在数组中排在边缘之前,角落重叠带热角赢。
    func testOverlapPrefersEarlierZone() {
        let zones = [corner, side]
        let hit = HotZoneController.hitZone(in: zones, mouse: CGPoint(x: 2, y: 950))
        XCTAssertEqual(hit?.kind, .corner(.topLeft), "热角与边缘重叠处应命中热角")
    }

    func testMissOutsideAllZones() {
        XCTAssertNil(HotZoneController.hitZone(in: [corner, side, primary], mouse: CGPoint(x: 500, y: 500)))
    }

    func testPrimaryCanExposeDifferentHoverAndDragRects() {
        let hover = CGRect(x: 700, y: 970, width: 200, height: 30)
        let drag = CGRect(x: 688, y: 963, width: 224, height: 37)
        let zone = Zone(kind: .primary, rect: hover, dragRect: drag)

        XCTAssertEqual(zone.rect, hover)
        XCTAssertEqual(zone.dragRect, drag)
        XCTAssertNil(HotZoneController.hitZone(in: [zone], mouse: CGPoint(x: 690, y: 980)))
    }

    // MARK: - 已跟踪屏包含判定(跨屏快路径)

    /// 贴屏幕顶(y == frame.maxY)必须算"仍在已跟踪屏"——CGRect.contains 排除 max 边,
    /// 曾把贴顶滑动误判成跨屏,每个 mouseMoved 都重置 dwell,呼出偶发失灵。
    func testTrackedScreenIncludesMaxEdges() {
        let frame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        XCTAssertTrue(HotZoneController.screenContainsMouse(frame: frame, mouse: CGPoint(x: 800, y: 1000)), "贴顶(y=maxY)仍在本屏")
        XCTAssertTrue(HotZoneController.screenContainsMouse(frame: frame, mouse: CGPoint(x: 1600, y: 500)), "贴右边(x=maxX)仍在本屏")
        XCTAssertFalse(HotZoneController.screenContainsMouse(frame: frame, mouse: CGPoint(x: 1601, y: 500)), "屏外不算")
    }

    /// 初始 .zero 缓存(refreshPlacement 作废后)不得包含任何点,否则鼠标恰在 (0,0) 时跳过重解析。
    func testZeroTrackedFrameContainsNothing() {
        XCTAssertFalse(HotZoneController.screenContainsMouse(frame: .zero, mouse: .zero))
    }

    // MARK: - 跨区 dwell 重置

    /// 区内滑进另一个区:重起计时,不沿用旧区已积累的停留时间。
    func testCrossZoneRestartsDwell() {
        XCTAssertTrue(HotZoneController.shouldRestartDwell(
            wasInside: true, previousKind: .corner(.topLeft), hitKind: .side(.left)
        ))
    }

    /// 同一区内滑动:身份不变,计时不动。
    func testSameZoneKeepsDwell() {
        XCTAssertFalse(HotZoneController.shouldRestartDwell(
            wasInside: true, previousKind: .side(.left), hitKind: .side(.left)
        ))
    }

    /// 从区外初次进入:走 enter 路径,不算"跨区"(重置由 enter 自身语义承担)。
    func testInitialEntryIsNotCrossZone() {
        XCTAssertFalse(HotZoneController.shouldRestartDwell(
            wasInside: false, previousKind: nil, hitKind: .primary
        ))
    }
}
