import XCTest
@testable import Niche

final class FilenameTruncationTests: XCTestCase {
    func testTruncationUsesRenderedWidthInsteadOfCharacterCount() {
        XCTAssertFalse(FilenameTruncation.isTruncated("短名", width: 120, layout: .list))
        XCTAssertTrue(FilenameTruncation.isTruncated(String(repeating: "W", count: 30),
                                                      width: 60, layout: .list))
        XCTAssertFalse(FilenameTruncation.isTruncated("两行以内", width: 120, layout: .grid))
        XCTAssertTrue(FilenameTruncation.isTruncated(String(repeating: "很长的文件名", count: 12),
                                                     width: 70, layout: .grid))
    }

    func testReadableGridWidthReducesRealisticFilenameTruncation() {
        let names = [
            "USMSSOsetup_arm64.dmg",
            "zhongliang-forecast-latest.tar",
            "中粮 E+_新用户安装操作手册.docx",
            "周报_2026年第31期.docx",
            "Tgent-2.1.3505.dmg",
        ]
        let cramped = names.filter { FilenameTruncation.isTruncated($0, width: 68, layout: .grid) }
        let readable = names.filter { FilenameTruncation.isTruncated($0, width: 96, layout: .grid) }

        XCTAssertLessThan(readable.count, cramped.count)
    }
}
