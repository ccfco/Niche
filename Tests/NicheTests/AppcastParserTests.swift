import XCTest
@testable import Niche

/// 回归钉住 appcast 解析与候选挑选的两次真实事故:
/// ① didEndElement 不清 currentElement → 标签间换行缩进混入版本号("0.1.3\n            ");
/// ② 候选按 marketing version 而非 build number 排序 → "同 marketing、不同 build"的重发被丢。
@MainActor
final class AppcastParserTests: XCTestCase {
    private func parse(_ xml: String) -> [AppcastParser.Item] {
        let parser = AppcastParser()
        let xmlParser = XMLParser(data: Data(xml.utf8))
        xmlParser.delegate = parser
        XCTAssertTrue(xmlParser.parse(), "appcast XML 应能解析")
        return parser.items
    }

    private func item(version: String, build: String, url: String = "https://example.com/Niche.app.zip",
                      pubDate: String = "Sat, 04 Jul 2026 12:00:00 +0000") -> String {
        """
        <item>
            <title>\(version)</title>
            <pubDate>\(pubDate)</pubDate>
            <sparkle:version>\(build)</sparkle:version>
            <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
            <enclosure url="\(url)" sparkle:edSignature="sig" length="1" type="application/octet-stream"/>
        </item>
        """
    }

    private func appcast(_ items: String...) -> String {
        """
        <?xml version="1.0" standalone="yes"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
            <channel>
                <title>Niche</title>
        \(items.joined(separator: "\n"))
            </channel>
        </rss>
        """
    }

    /// 事故①:generate_appcast 输出带缩进换行,字段值不得混入空白。
    func testIndentedXMLDoesNotPolluteFields() {
        let items = parse(appcast(item(version: "0.1.3", build: "144")))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].version, "0.1.3")
        XCTAssertEqual(items[0].buildNumber, 144)
        XCTAssertNotNil(items[0].pubDate)
        XCTAssertEqual(items[0].downloadURL?.absoluteString, "https://example.com/Niche.app.zip")
    }

    /// 事故②:候选必须按 build number 最大挑,不按 marketing version、也不按条目顺序。
    /// 0.1.10(build 156)语义上新于 0.2.0-回滚重发(build 20),字符串/版本号比较都会选错。
    func testBestCandidatePicksMaxBuildNumber() {
        let items = parse(appcast(
            item(version: "0.2.0", build: "20"),
            item(version: "0.1.10", build: "156"),
            item(version: "0.1.9", build: "150")
        ))
        let best = UpdateChecker.bestCandidate(from: items)
        XCTAssertEqual(best?.version, "0.1.10")
        XCTAssertEqual(best?.buildNumber, 156)
    }

    /// 容错:手改 appcast 塞入带小数点的 build("144.0")按浮点截断,不整条丢弃。
    func testDecimalBuildNumberTolerated() {
        let items = parse(appcast(item(version: "0.1.4", build: "144.0")))
        XCTAssertEqual(items[0].buildNumber, 144)
    }

    /// 脏条目过滤:非数字 marketing version(beta/rc)与缺 enclosure 的条目不得成为候选。
    func testDirtyItemsFilteredFromCandidates() {
        let noEnclosure = """
        <item>
            <pubDate>Sat, 04 Jul 2026 12:00:00 +0000</pubDate>
            <sparkle:version>999</sparkle:version>
            <sparkle:shortVersionString>9.9.9</sparkle:shortVersionString>
        </item>
        """
        let items = parse(appcast(
            item(version: "0.2.0-beta", build: "200"),
            noEnclosure,
            item(version: "0.1.7", build: "156")
        ))
        let best = UpdateChecker.bestCandidate(from: items)
        XCTAssertEqual(best?.version, "0.1.7", "beta 版本与缺下载地址的条目应被过滤")
        XCTAssertEqual(best?.buildNumber, 156)
    }

    func testEmptyAppcastYieldsNoCandidate() {
        let items = parse(appcast())
        XCTAssertTrue(items.isEmpty)
        XCTAssertNil(UpdateChecker.bestCandidate(from: items))
    }
}
