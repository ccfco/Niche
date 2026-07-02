import XCTest
import CoreGraphics
@testable import Niche

final class NotchGeometryTests: XCTestCase {
    // 模拟 14" MBP:1512×982,刘海高 ~37,两侧各 ~580 可用。
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testNotchResolvedAndCentered() {
        let res = NotchGeometry.resolve(
            screenFrame: screen,
            safeAreaTop: 37,
            auxiliaryLeftWidth: 580,
            auxiliaryRightWidth: 580,
            menubarHeight: 37
        )
        XCTAssertTrue(res.hasNotch)
        let r = res.rect
        XCTAssertEqual(r.width, 1512 - 580 - 580, accuracy: 0.001)   // 352
        XCTAssertEqual(r.height, 37, accuracy: 0.001)
        XCTAssertEqual(r.midX, screen.midX, accuracy: 0.001)         // 水平居中
        XCTAssertEqual(r.maxY, screen.maxY, accuracy: 0.001)         // 贴顶
    }

    func testNoNotchFallsBackToTopCenter() {
        // 1920 宽屏:16% = 307.2,落在 [160,480] 夹取范围内,不触发夹取。
        let res = NotchGeometry.resolve(
            screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            safeAreaTop: 0,
            auxiliaryLeftWidth: nil,
            auxiliaryRightWidth: nil,
            menubarHeight: 24
        )
        XCTAssertFalse(res.hasNotch)
        let r = res.rect
        XCTAssertEqual(r.width, 307.2, accuracy: 0.001)
        XCTAssertEqual(r.height, 24, accuracy: 0.001)
        XCTAssertEqual(r.midX, 960, accuracy: 0.001)
        XCTAssertEqual(r.maxY, 1080, accuracy: 0.001)
    }

    func testFallbackWidthClampedOnSmallAndHugeScreens() {
        // 极小屏:16% 低于 160 下限,夹到 160。
        let small = NotchGeometry.resolve(
            screenFrame: CGRect(x: 0, y: 0, width: 600, height: 400),
            safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, menubarHeight: 24
        )
        XCTAssertEqual(small.rect.width, 160, accuracy: 0.001)

        // 超宽屏:16% 高于 480 上限,夹到 480。
        let huge = NotchGeometry.resolve(
            screenFrame: CGRect(x: 0, y: 0, width: 5120, height: 1440),
            safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, menubarHeight: 24
        )
        XCTAssertEqual(huge.rect.width, 480, accuracy: 0.001)
    }

    func testFallbackWidthScaleMultipliesBaseWidth() {
        let res = NotchGeometry.resolve(
            screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, menubarHeight: 24,
            widthScale: 1.5
        )
        XCTAssertEqual(res.rect.width, 307.2 * 1.5, accuracy: 0.001)
    }

    func testExternalDisplayWithMenubarButNoAuxIsFallback() {
        // safeAreaTop>0 但缺 aux 宽度(非刘海全面屏场景)→ 回退。
        let res = NotchGeometry.resolve(
            screenFrame: screen, safeAreaTop: 0,
            auxiliaryLeftWidth: nil, auxiliaryRightWidth: 580, menubarHeight: 24
        )
        XCTAssertFalse(res.hasNotch)
    }

    func testFallbackHeightNeverZero() {
        let res = NotchGeometry.resolve(
            screenFrame: screen, safeAreaTop: 0,
            auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, menubarHeight: 0
        )
        XCTAssertGreaterThanOrEqual(res.rect.height, 1)
    }

    func testHotZoneWidensHorizontallyOnly() {
        let res = NotchGeometry.resolve(
            screenFrame: screen, safeAreaTop: 37,
            auxiliaryLeftWidth: 580, auxiliaryRightWidth: 580, menubarHeight: 37
        )
        let hot = NotchGeometry.hotZoneRect(from: res, horizontalPadding: 12)
        XCTAssertEqual(hot.width, res.rect.width + 24, accuracy: 0.001)
        XCTAssertEqual(hot.height, res.rect.height, accuracy: 0.001)
        XCTAssertEqual(hot.midX, res.rect.midX, accuracy: 0.001)
    }
}
