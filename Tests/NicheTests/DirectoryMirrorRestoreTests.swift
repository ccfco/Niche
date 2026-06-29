import XCTest
@testable import Niche

/// 下钻位置 per-binding 持久化的单元测试(§4.7 肌肉记忆:重启恢复上次下钻深度)。
///
/// 走公开行为面验证:构造 mirror → 读 `currentDirectory`(`private(set)` 可测)。不撬私有
/// `restoredDirectory`,重构内部不碎测。多数用例通过 `enter()` 真实落点驱动持久化 —— 注意
/// `enter` 的 `persistCurrentDirectory()` 在 `armed` 守卫**之前**,故无需 arm(不触发 FSEvents/TCC),
/// 只要目标是磁盘上真实目录即可。
///
/// 隔离:这些 static helper 硬编码 `UserDefaults.standard`(不可注入),故测试用唯一 UUID 的
/// binding(key=`niche.lastPath.<uuid>` 必不与真实键冲突)+ `defer clearLastPath` 清理。
@MainActor
final class DirectoryMirrorRestoreTests: XCTestCase {
    /// 建一棵临时目录树 root/sub,返回 (root, sub);调用方负责 defer 清理 tmpBase。
    private func makeTree(file: StaticString = #filePath, line: UInt = #line) throws
        -> (base: URL, root: URL, sub: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("niche-restoretest-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        return (base, root, sub)
    }

    /// 往返:mirror A 下钻进 sub(持久化)→ 同 binding 的 mirror B 启动恢复到 sub。
    func testEnterPersistsAndNewMirrorRestores() throws {
        let (base, root, sub) = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }

        let binding = FolderBinding(path: root.path)
        defer { DirectoryMirror.clearLastPath(for: binding.id) }

        let mirrorA = DirectoryMirror(binding: binding, showHidden: false)
        mirrorA.enter(sub)   // persist 在 armed 守卫前执行,无需 arm
        XCTAssertEqual(mirrorA.currentDirectory.standardizedFileURL, sub.standardizedFileURL)

        let mirrorB = DirectoryMirror(binding: binding, showHidden: false)
        XCTAssertEqual(mirrorB.currentDirectory.standardizedFileURL, sub.standardizedFileURL,
                       "同 binding 的新 mirror 应从持久化恢复到上次下钻的子目录")
        XCTAssertEqual(mirrorB.breadcrumb.count, 2, "面包屑应反映 root → sub 两级")
    }

    /// goUp 回到根后,新 mirror 恢复到根(写入根路径 = 下次无需恢复子目录)。
    func testGoUpToRootPersistsRoot() throws {
        let (base, root, sub) = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }

        let binding = FolderBinding(path: root.path)
        defer { DirectoryMirror.clearLastPath(for: binding.id) }

        let mirrorA = DirectoryMirror(binding: binding, showHidden: false)
        mirrorA.enter(sub)
        mirrorA.goUp()
        XCTAssertEqual(mirrorA.currentDirectory.standardizedFileURL, root.standardizedFileURL)

        let mirrorB = DirectoryMirror(binding: binding, showHidden: false)
        XCTAssertEqual(mirrorB.currentDirectory.standardizedFileURL, root.standardizedFileURL)
    }

    /// 临时 tab 不持久化:isTemporary 的 mirror 下钻后,正式 mirror 仍恢复到根。
    func testTemporaryTabDoesNotPersist() throws {
        let (base, root, sub) = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }

        let binding = FolderBinding(path: root.path)
        defer { DirectoryMirror.clearLastPath(for: binding.id) }

        let temp = DirectoryMirror(binding: binding, showHidden: false, isTemporary: true)
        temp.enter(sub)
        XCTAssertEqual(temp.currentDirectory.standardizedFileURL, sub.standardizedFileURL,
                       "临时 tab 自身仍可下钻,只是不落盘")

        let normal = DirectoryMirror(binding: binding, showHidden: false)
        XCTAssertEqual(normal.currentDirectory.standardizedFileURL, root.standardizedFileURL,
                       "临时 tab 的下钻不应被持久化")
    }

    /// 无存储:全新 binding 的 mirror 停在根。
    func testNoStoredPathStaysAtRoot() throws {
        let (base, root, _) = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }

        let binding = FolderBinding(path: root.path)
        defer { DirectoryMirror.clearLastPath(for: binding.id) }

        let mirror = DirectoryMirror(binding: binding, showHidden: false)
        XCTAssertEqual(mirror.currentDirectory.standardizedFileURL, root.standardizedFileURL)
    }

    /// clearLastPath 后恢复回根(BindingStore.remove 删绑定后不残留旧位置)。
    func testClearLastPathResetsRestore() throws {
        let (base, root, sub) = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }

        let binding = FolderBinding(path: root.path)
        defer { DirectoryMirror.clearLastPath(for: binding.id) }

        DirectoryMirror(binding: binding, showHidden: false).enter(sub)
        DirectoryMirror.clearLastPath(for: binding.id)

        let mirror = DirectoryMirror(binding: binding, showHidden: false)
        XCTAssertEqual(mirror.currentDirectory.standardizedFileURL, root.standardizedFileURL)
    }

    /// 越界回退:存储里被塞入根外路径(模拟根被移动致旧绝对路径失效 / 篡改),
    /// 启动时前缀校验不过 → 回退根。此用例须直接写 key(enter 不可能持久化越界路径)。
    func testOutOfRootStoredPathFallsBackToRoot() throws {
        let (base, root, _) = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }

        let binding = FolderBinding(path: root.path)
        let key = "niche.lastPath.\(binding.id.uuidString)"   // 镜像生产 key 格式(lastPathKey 私有)
        UserDefaults.standard.set("/etc", forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let mirror = DirectoryMirror(binding: binding, showHidden: false)
        XCTAssertEqual(mirror.currentDirectory.standardizedFileURL, root.standardizedFileURL,
                       "根外存储路径不在根内 → 回退绑定根,不跳出绑定边界")
    }

    /// 兄弟前缀不被误判为根内(/root2 不是 /root 的子路径)。
    func testSiblingPrefixStoredPathFallsBackToRoot() throws {
        let (base, root, _) = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }

        let binding = FolderBinding(path: root.path)
        let key = "niche.lastPath.\(binding.id.uuidString)"
        UserDefaults.standard.set(root.path + "2", forKey: key)   // root 的兄弟前缀
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let mirror = DirectoryMirror(binding: binding, showHidden: false)
        XCTAssertEqual(mirror.currentDirectory.standardizedFileURL, root.standardizedFileURL)
    }
}
