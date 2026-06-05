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
}
