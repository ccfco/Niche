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
