import XCTest
import CoreGraphics
@testable import Niche

final class ScreenCornerTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    func testFourCornersSitAtPhysicalCorners() {
        let size: CGFloat = 16
        XCTAssertEqual(ScreenCorner.topLeft.rect(in: screen, size: size).origin, CGPoint(x: 0, y: 1080 - size))
        XCTAssertEqual(ScreenCorner.topRight.rect(in: screen, size: size).origin, CGPoint(x: 1920 - size, y: 1080 - size))
        XCTAssertEqual(ScreenCorner.bottomLeft.rect(in: screen, size: size).origin, CGPoint(x: 0, y: 0))
        XCTAssertEqual(ScreenCorner.bottomRight.rect(in: screen, size: size).origin, CGPoint(x: 1920 - size, y: 0))
    }
}
