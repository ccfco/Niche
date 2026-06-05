import XCTest
import UniformTypeIdentifiers
@testable import Niche

final class FileItemTests: XCTestCase {
    func testLoadReadsBasicMetadata() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.cleanup(dir) }
        let file = dir.appendingPathComponent("note.txt")
        try TestSupport.touch(file, contents: "hello niche")

        let item = FileItem.load(url: file)
        XCTAssertEqual(item.name, "note.txt")
        XCTAssertFalse(item.isDirectory)
        XCTAssertFalse(item.isHidden)
        XCTAssertGreaterThan(item.size, 0)
        XCTAssertEqual(item.contentType, .plainText)
        XCTAssertFalse(item.isDataless)  // 本地普通文件不是 iCloud 占位
    }

    func testLoadDirectory() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.cleanup(dir) }
        let sub = dir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)

        let item = FileItem.load(url: sub)
        XCTAssertTrue(item.isDirectory)
        XCTAssertEqual(item.name, "sub")
    }

    func testLoadMissingFileDegradesGracefully() {
        // 镜像要容忍外部随时删文件:load 不抛,字段退化为安全默认。
        let missing = URL(fileURLWithPath: "/tmp/niche-does-not-exist-\(UUID().uuidString)")
        let item = FileItem.load(url: missing)
        XCTAssertEqual(item.name, missing.lastPathComponent)
        XCTAssertEqual(item.size, 0)
    }
}
