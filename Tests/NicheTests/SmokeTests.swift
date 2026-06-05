import XCTest
@testable import Niche

/// 占位冒烟测试:确认测试 target 能链接 app target 并运行。
/// 纯逻辑模块的真实单测在 Task 2 各 *Tests.swift 中补齐。
final class SmokeTests: XCTestCase {
    func testFolderBindingDefaultDisplayName() {
        let binding = FolderBinding(path: "/Users/me/Downloads")
        XCTAssertEqual(binding.displayName, "Downloads")
        XCTAssertEqual(binding.url.path, "/Users/me/Downloads")
    }
}
