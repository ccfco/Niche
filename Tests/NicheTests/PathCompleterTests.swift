import XCTest
@testable import Niche

final class PathCompleterTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = try TestSupport.makeTempDir()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Reports"),
                                                withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("résumé"),
                                                withIntermediateDirectories: false)
        try TestSupport.touch(dir.appendingPathComponent("readme.txt"))
        try TestSupport.touch(dir.appendingPathComponent(".hidden-file"))
    }

    override func tearDown() {
        TestSupport.cleanup(dir)
    }

    // MARK: - expand

    func testExpandTilde() {
        let home = NSHomeDirectory()
        XCTAssertEqual(PathCompleter.expand("~"), home)
        XCTAssertEqual(PathCompleter.expand("~/Downloads"), home + "/Downloads")
        XCTAssertEqual(PathCompleter.expand("~/Downloads/"), home + "/Downloads/")  // 尾 / 保留(补全语义)
        XCTAssertEqual(PathCompleter.expand("/usr"), "/usr")                        // 非 ~ 原样
    }

    // MARK: - suggest

    func testSuggestPrefersDirectoryAndAppendsSlash() {
        // "re" 同时命中 Reports(目录)/readme.txt(文件)/résumé(目录,音调不敏感):
        // 目录优先,组内 localizedStandard 排序 → Reports。
        let suggestion = PathCompleter.suggest(dir.path + "/re")
        XCTAssertEqual(suggestion, dir.path + "/Reports/")
    }

    func testSuggestFileHasNoTrailingSlash() {
        let suggestion = PathCompleter.suggest(dir.path + "/readm")
        XCTAssertEqual(suggestion, dir.path + "/readme.txt")
    }

    func testSuggestCaseInsensitive() {
        XCTAssertEqual(PathCompleter.suggest(dir.path + "/REP"), dir.path + "/Reports/")
    }

    func testSuggestHiddenParticipatesWithDotPrefix() {
        XCTAssertEqual(PathCompleter.suggest(dir.path + "/.hid"), dir.path + "/.hidden-file")
    }

    func testSuggestNoMatchOrTrailingSlashReturnsNil() {
        XCTAssertNil(PathCompleter.suggest(dir.path + "/zzz"))
        XCTAssertNil(PathCompleter.suggest(dir.path + "/"))   // 无未完成段不补
        XCTAssertNil(PathCompleter.suggest("relative/path"))  // 非绝对路径不补
    }

    // MARK: - resolve

    func testResolveDirectoryFileAndMissing() {
        XCTAssertEqual(PathCompleter.resolve(dir.path + "/Reports"),
                       .directory(dir.appendingPathComponent("Reports").standardizedFileURL))
        XCTAssertEqual(PathCompleter.resolve(dir.path + "/readme.txt"),
                       .file(dir.appendingPathComponent("readme.txt").standardizedFileURL))
        XCTAssertEqual(PathCompleter.resolve(dir.path + "/nope"), .missing)
        XCTAssertEqual(PathCompleter.resolve("not-absolute"), .missing)
        XCTAssertEqual(PathCompleter.resolve("  " + dir.path + "/Reports  "), // 粘贴常带空白
                       .directory(dir.appendingPathComponent("Reports").standardizedFileURL))
    }
}
