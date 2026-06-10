import XCTest
@testable import Niche

final class TypeAheadTests: XCTestCase {
    func testAppendAccumulatesWithinTimeout() {
        var buf = TypeAheadBuffer()
        let t0 = Date()
        XCTAssertEqual(buf.append("r", at: t0), "r")
        XCTAssertEqual(buf.append("e", at: t0.addingTimeInterval(0.3)), "re")
        XCTAssertEqual(buf.append("p", at: t0.addingTimeInterval(0.6)), "rep")
    }

    func testAppendRestartsAfterTimeout() {
        var buf = TypeAheadBuffer()
        let t0 = Date()
        _ = buf.append("re", at: t0)
        XCTAssertEqual(buf.append("x", at: t0.addingTimeInterval(1.5)), "x")   // 停顿超时 → 新一轮
    }

    func testResetClearsBuffer() {
        var buf = TypeAheadBuffer()
        _ = buf.append("abc", at: Date())
        buf.reset()
        XCTAssertEqual(buf.buffer, "")
    }

    func testIsTypeAheadInputFiltersNonVisible() {
        XCTAssertTrue(TypeAheadBuffer.isTypeAheadInput("r"))
        XCTAssertTrue(TypeAheadBuffer.isTypeAheadInput("报"))
        XCTAssertTrue(TypeAheadBuffer.isTypeAheadInput("."))
        XCTAssertFalse(TypeAheadBuffer.isTypeAheadInput(" "))      // 空格 = Quick Look
        XCTAssertFalse(TypeAheadBuffer.isTypeAheadInput("\t"))     // 控制字符
        XCTAssertFalse(TypeAheadBuffer.isTypeAheadInput("\u{F700}"))  // 功能键私有区(↑)
        XCTAssertFalse(TypeAheadBuffer.isTypeAheadInput(nil))
        XCTAssertFalse(TypeAheadBuffer.isTypeAheadInput(""))
    }

    func testFirstMatchIsCaseAndDiacriticInsensitivePrefix() {
        let names = ["btmp", "Report.pdf", "résumé.txt", "report-2.pdf"]
        XCTAssertEqual(TypeAheadBuffer.firstMatch(prefix: "rep", in: names), 1)   // 忽略大小写,取首个
        XCTAssertEqual(TypeAheadBuffer.firstMatch(prefix: "resume", in: names), 2) // 忽略音调
        XCTAssertEqual(TypeAheadBuffer.firstMatch(prefix: "port", in: names), nil) // 前缀锚定,非子串
        XCTAssertNil(TypeAheadBuffer.firstMatch(prefix: "", in: names))
    }
}
