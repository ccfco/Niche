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

    func testLoadDirectorySymlinkCountsAsDirectory() throws {
        // 指向文件夹的软链按 Finder 语义当文件夹(双击下钻):.isDirectoryKey 对软链本身报 false,
        // load 须解析目标再判 —— 否则软链文件夹被当文件,双击走打开而非进入。
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.cleanup(dir) }
        let realDir = dir.appendingPathComponent("realDir", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: false)
        let dirLink = dir.appendingPathComponent("dirLink")
        try FileManager.default.createSymbolicLink(at: dirLink, withDestinationURL: realDir)

        XCTAssertTrue(FileItem.load(url: dirLink).isDirectory)
    }

    func testLoadFileSymlinkIsNotDirectory() throws {
        // 指向文件的软链仍是文件(双击走打开目标)。
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.cleanup(dir) }
        let realFile = dir.appendingPathComponent("note.txt")
        try TestSupport.touch(realFile, contents: "x")
        let fileLink = dir.appendingPathComponent("fileLink")
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: realFile)

        XCTAssertFalse(FileItem.load(url: fileLink).isDirectory)
    }

    func testLoadMissingFileDegradesGracefully() {
        // 镜像要容忍外部随时删文件:load 不抛,字段退化为安全默认。
        let missing = URL(fileURLWithPath: "/tmp/niche-does-not-exist-\(UUID().uuidString)")
        let item = FileItem.load(url: missing)
        XCTAssertEqual(item.name, missing.lastPathComponent)
        XCTAssertEqual(item.size, 0)
    }
}
