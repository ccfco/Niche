import XCTest
import UniformTypeIdentifiers
@testable import Niche

final class SortOrderTests: XCTestCase {
    private func sortedNames(_ items: [FileItem], _ order: FileSortOrder) -> [String] {
        items.sorted(by: order.comparator()).map(\.name)
    }

    func testNameAscendingUsesNaturalNumericOrder() {
        let items = [TestSupport.item("file10"), TestSupport.item("file2"), TestSupport.item("file1")]
        let order = FileSortOrder(key: .name, direction: .ascending, directoriesFirst: false)
        XCTAssertEqual(sortedNames(items, order), ["file1", "file2", "file10"])
    }

    func testNameDescending() {
        let items = [TestSupport.item("a"), TestSupport.item("c"), TestSupport.item("b")]
        let order = FileSortOrder(key: .name, direction: .descending, directoriesFirst: false)
        XCTAssertEqual(sortedNames(items, order), ["c", "b", "a"])
    }

    func testDirectoriesFirstRegardlessOfDirection() {
        let items = [
            TestSupport.item("zfile"),
            TestSupport.item("adir", dir: true),
            TestSupport.item("afile"),
        ]
        let asc = FileSortOrder(key: .name, direction: .ascending, directoriesFirst: true)
        XCTAssertEqual(sortedNames(items, asc), ["adir", "afile", "zfile"])
        // 降序时目录仍在最前。
        let desc = FileSortOrder(key: .name, direction: .descending, directoriesFirst: true)
        XCTAssertEqual(sortedNames(items, desc).first, "adir")
    }

    func testSizeAscendingWithNameTiebreaker() {
        let items = [
            TestSupport.item("big", size: 100),
            TestSupport.item("smallB", size: 10),
            TestSupport.item("smallA", size: 10),
        ]
        let order = FileSortOrder(key: .size, direction: .ascending, directoriesFirst: false)
        XCTAssertEqual(sortedNames(items, order), ["smallA", "smallB", "big"])
    }

    func testDateDescending() {
        let items = [
            TestSupport.item("old", date: Date(timeIntervalSince1970: 100)),
            TestSupport.item("new", date: Date(timeIntervalSince1970: 999)),
        ]
        let order = FileSortOrder(key: .date, direction: .descending, directoriesFirst: false)
        XCTAssertEqual(sortedNames(items, order), ["new", "old"])
    }

    func testKindGroupsByContentType() {
        let items = [
            TestSupport.item("b.txt", type: .plainText),
            TestSupport.item("a.png", type: .png),
            TestSupport.item("a.txt", type: .plainText),
        ]
        let order = FileSortOrder(key: .kind, direction: .ascending, directoriesFirst: false)
        // 同类型内按名称;不同类型按 identifier。png(image) 与 plainText(text) 分组稳定。
        let names = sortedNames(items, order)
        XCTAssertEqual(Set(names), Set(["a.png", "a.txt", "b.txt"]))
        // 同为 plainText 的两个,a.txt 在 b.txt 前。
        XCTAssertLessThan(names.firstIndex(of: "a.txt")!, names.firstIndex(of: "b.txt")!)
    }
}
