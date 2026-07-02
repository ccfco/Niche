import Foundation
import UniformTypeIdentifiers
@testable import Niche

enum TestSupport {
    /// 构造内存中的 FileItem(不碰磁盘),供排序/diff 测试。
    static func item(
        _ name: String,
        dir: Bool = false,
        hidden: Bool = false,
        size: Int64 = 0,
        date: Date = Date(timeIntervalSince1970: 0),
        type: UTType? = .plainText,
        dataless: Bool = false,
        tags: [String] = [],
        sig: String = ""
    ) -> FileItem {
        FileItem(
            url: URL(fileURLWithPath: "/tmp/niche-test/\(name)"),
            name: name,
            isDirectory: dir,
            isHidden: hidden,
            size: size,
            modificationDate: date,
            contentType: type,
            isDataless: dataless,
            tags: tags,
            folderIconSignature: sig
        )
    }

    /// 建一个唯一临时目录,返回 URL;调用方负责清理(或用 cleanup)。
    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("niche-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    static func touch(_ url: URL, contents: String = "x") throws -> URL {
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    /// 等待异步条件成立(arm/下钻的快照已后台化,测试不能再同步断言扫描结果)。
    /// 轮询 + 让出主线程,让 Task.detached → MainActor.run 的发布链有机会执行;
    /// 超时直接返回,由调用方的断言暴露失败。
    @MainActor
    static func waitUntil(timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
