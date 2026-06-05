import XCTest
@testable import Niche

final class ConflictResolutionTests: XCTestCase {
    func testNoConflictReturnsOriginalURL() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.cleanup(dir) }
        let proposed = dir.appendingPathComponent("file.txt")
        XCTAssertEqual(ConflictResolver.uniqueURL(for: proposed, in: dir), proposed)
    }

    func testConflictAppendsCounterPreservingExtension() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.cleanup(dir) }
        try TestSupport.touch(dir.appendingPathComponent("file.txt"))

        let unique = ConflictResolver.uniqueURL(for: dir.appendingPathComponent("file.txt"), in: dir)
        XCTAssertEqual(unique.lastPathComponent, "file 2.txt")
    }

    func testMultipleConflictsIncrementCounter() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.cleanup(dir) }
        try TestSupport.touch(dir.appendingPathComponent("file.txt"))
        try TestSupport.touch(dir.appendingPathComponent("file 2.txt"))

        let unique = ConflictResolver.uniqueURL(for: dir.appendingPathComponent("file.txt"), in: dir)
        XCTAssertEqual(unique.lastPathComponent, "file 3.txt")
    }

    func testNoExtensionDirectory() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.cleanup(dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"),
                                                withIntermediateDirectories: false)
        let unique = ConflictResolver.uniqueURL(for: dir.appendingPathComponent("sub"), in: dir)
        XCTAssertEqual(unique.lastPathComponent, "sub 2")
    }

    func testHasConflictDetectsExisting() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.cleanup(dir) }
        try TestSupport.touch(dir.appendingPathComponent("a.txt"))
        XCTAssertTrue(ConflictResolver.hasConflict(name: "a.txt", in: dir))
        XCTAssertFalse(ConflictResolver.hasConflict(name: "b.txt", in: dir))
    }
}
