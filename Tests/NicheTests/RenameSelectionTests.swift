import XCTest
@testable import Niche

/// 重命名初始选区(Finder 语义:选中文件名主干,不含扩展名)。
final class RenameSelectionTests: XCTestCase {
    private func range(_ name: String) -> NSRange { RenameSelection.stemRange(for: name) }

    func testSelectsStemWithoutExtension() {
        XCTAssertEqual(range("photo.jpg"), NSRange(location: 0, length: 5))   // "photo"
    }

    func testNoExtensionSelectsAll() {
        XCTAssertEqual(range("README"), NSRange(location: 0, length: 6))
    }

    func testHiddenFileWithoutExtensionSelectsAll() {
        // ".gitignore" 无扩展名 → 全选(deletingPathExtension 不把前导点当扩展分隔)。
        XCTAssertEqual(range(".gitignore"), NSRange(location: 0, length: 10))
    }

    func testHiddenFileWithExtensionSelectsStem() {
        // ".env.local" → 主干 ".env"。
        XCTAssertEqual(range(".env.local"), NSRange(location: 0, length: 4))
    }

    func testMultiDotSelectsUpToLastExtension() {
        // "archive.tar.gz" → 主干 "archive.tar"(Finder 只剥最后一个扩展名)。
        XCTAssertEqual(range("archive.tar.gz"), NSRange(location: 0, length: 11))
    }

    func testEmptyNameYieldsEmptyRange() {
        XCTAssertEqual(range(""), NSRange(location: 0, length: 0))
    }

    func testTrailingDotIsNotARealExtensionSoSelectsAll() {
        // "foo." 的空扩展名不被 deletingPathExtension 剥离(返回 "foo." 本身)→ 视为无扩展名,全选。
        XCTAssertEqual(range("foo."), NSRange(location: 0, length: 4))
    }

    func testSelectionLengthUsesUTF16ForNonASCII() {
        // emoji 占 2 个 UTF-16 码元;主干 "📄x" 长度应为 3(2 + 1),不是字素簇计数 2。
        XCTAssertEqual(range("📄x.txt"), NSRange(location: 0, length: 3))
    }
}
