import XCTest
@testable import Niche

/// DirectoryMirror.contains 是拖拽循环防护与卷卸载判定的边界基石 —— 必须按路径组件边界,
/// 不能用 hasPrefix(否则 /Volumes/Data 会误命中 /Volumes/Data2)。
@MainActor
final class PathContainmentTests: XCTestCase {
    private func url(_ p: String) -> URL { URL(fileURLWithPath: p) }

    func testDescendantWithinAncestor() {
        XCTAssertTrue(DirectoryMirror.contains(ancestor: url("/Volumes/Data"),
                                               descendant: url("/Volumes/Data/sub/file")))
    }

    func testEqualPathsCountAsContained() {
        XCTAssertTrue(DirectoryMirror.contains(ancestor: url("/Volumes/Data"),
                                               descendant: url("/Volumes/Data")))
    }

    func testSiblingPrefixIsNotContained() {
        // 关键反例:/Volumes/Data2 不属于 /Volumes/Data。
        XCTAssertFalse(DirectoryMirror.contains(ancestor: url("/Volumes/Data"),
                                                descendant: url("/Volumes/Data2/x")))
    }

    func testUnrelatedPaths() {
        XCTAssertFalse(DirectoryMirror.contains(ancestor: url("/Users/me/A"),
                                                descendant: url("/Users/me/B")))
    }

    // MARK: - containsUnresolved(软链就地下钻越界判定:不解析符号链接)

    func testUnresolvedDescendantWithinAncestor() {
        XCTAssertTrue(DirectoryMirror.containsUnresolved(ancestor: url("/Users/me/root"),
                                                         descendant: url("/Users/me/root/link/sub")))
    }

    func testUnresolvedSiblingPrefixIsNotContained() {
        XCTAssertFalse(DirectoryMirror.containsUnresolved(ancestor: url("/Users/me/root"),
                                                          descendant: url("/Users/me/root2/x")))
    }

    /// 关键:目标在 root 之内的软链路径,即便其真实指向越界,按未解析路径仍判为「在内」——
    /// 这是软链就地下钻能成立的前提(contains 会解析、误判越界,故二者分工)。
    func testUnresolvedKeepsSymlinkPathInsideRoot() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("niche-symlink-\(UUID().uuidString)", isDirectory: true)
        let root = tmp.appendingPathComponent("root", isDirectory: true)
        let outside = tmp.appendingPathComponent("outside", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)

        // 软链路径在 root 之下 → containsUnresolved 判内(就地下钻成立)。
        XCTAssertTrue(DirectoryMirror.containsUnresolved(ancestor: root, descendant: link))
        // 对照:contains 解析到 outside → 判越界。二者按设计相反。
        XCTAssertFalse(DirectoryMirror.contains(ancestor: root, descendant: link))
    }

    /// 指向目录的软链应被认作可下钻目录;指向文件的软链不应(走打开)。
    func testIsNavigableDirectoryFollowsSymlinkTarget() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("niche-navsym-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let realDir = tmp.appendingPathComponent("realDir", isDirectory: true)
        try fm.createDirectory(at: realDir, withIntermediateDirectories: true)
        let dirLink = tmp.appendingPathComponent("dirLink")
        try fm.createSymbolicLink(at: dirLink, withDestinationURL: realDir)

        let realFile = tmp.appendingPathComponent("realFile.txt")
        try Data().write(to: realFile)
        let fileLink = tmp.appendingPathComponent("fileLink")
        try fm.createSymbolicLink(at: fileLink, withDestinationURL: realFile)

        XCTAssertTrue(DirectoryMirror.isNavigableDirectory(dirLink))
        XCTAssertFalse(DirectoryMirror.isNavigableDirectory(fileLink))
    }
}
