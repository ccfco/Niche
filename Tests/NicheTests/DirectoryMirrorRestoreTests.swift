import XCTest
@testable import Niche

/// 下钻位置 per-binding 持久化的单元测试(§4.7 肌肉记忆:重启恢复上次下钻深度)。
///
/// 走公开行为面验证:构造 mirror → 读 `currentDirectory`(`private(set)` 可测)。不撬私有
/// `restoredDirectory`,重构内部不碎测。多数用例通过 `enter()` 真实落点驱动持久化 —— 注意
/// `enter` 的 `persistCurrentDirectory()` 在 `armed` 守卫**之前**,故无需 arm(不触发 FSEvents/TCC),
/// 只要目标是磁盘上真实目录即可。
///
/// 隔离:每个测试注入独立 UserDefaults suite(DirectoryMirror.init(defaults:)),不碰 `.standard`、
/// 互不串台;`tearDown` 抹除该 suite。
@MainActor
final class DirectoryMirrorRestoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "niche-restoretest-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// 建一棵临时目录树 root/sub,返回 (base, root, sub);调用方负责 defer 清理 base。
    private func makeTree() throws -> (base: URL, root: URL, sub: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("niche-restoretest-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        return (base, root, sub)
    }

    private func makeMirror(_ binding: FolderBinding, isTemporary: Bool = false) -> DirectoryMirror {
        DirectoryMirror(binding: binding, showHidden: false, isTemporary: isTemporary, defaults: defaults)
    }

    /// 往返:mirror A 下钻进 sub(持久化)→ 同 binding 的 mirror B 启动恢复到 sub。
    func testEnterPersistsAndNewMirrorRestores() throws {
        let (base, root, sub) = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }

        let binding = FolderBinding(path: root.path)
        let mirrorA = makeMirror(binding)
        mirrorA.enter(sub)   // persist 在 armed 守卫前执行,无需 arm
        XCTAssertEqual(mirrorA.currentDirectory.standardizedFileURL, sub.standardizedFileURL)

        let mirrorB = makeMirror(binding)
        XCTAssertEqual(mirrorB.currentDirectory.standardizedFileURL, sub.standardizedFileURL,
                       "同 binding 的新 mirror 应从持久化恢复到上次下钻的子目录")
        XCTAssertEqual(mirrorB.breadcrumb.count, 2, "面包屑应反映 root → sub 两级")
    }

    /// goUp 回到根后,新 mirror 恢复到根(写入根路径 = 下次无需恢复子目录)。
    func testGoUpToRootPersistsRoot() throws {
        let (base, root, sub) = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }

        let binding = FolderBinding(path: root.path)
        let mirrorA = makeMirror(binding)
        mirrorA.enter(sub)
        mirrorA.goUp()
        XCTAssertEqual(mirrorA.currentDirectory.standardizedFileURL, root.standardizedFileURL)

        let mirrorB = makeMirror(binding)
        XCTAssertEqual(mirrorB.currentDirectory.standardizedFileURL, root.standardizedFileURL)
    }

    /// 临时 tab 不持久化:isTemporary 的 mirror 下钻后,正式 mirror 仍恢复到根。
    func testTemporaryTabDoesNotPersist() throws {
        let (base, root, sub) = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }

        let binding = FolderBinding(path: root.path)
        let temp = makeMirror(binding, isTemporary: true)
        temp.enter(sub)
        XCTAssertEqual(temp.currentDirectory.standardizedFileURL, sub.standardizedFileURL,
                       "临时 tab 自身仍可下钻,只是不落盘")

        let normal = makeMirror(binding)
        XCTAssertEqual(normal.currentDirectory.standardizedFileURL, root.standardizedFileURL,
                       "临时 tab 的下钻不应被持久化")
    }

    /// 无存储:全新 binding 的 mirror 停在根。
    func testNoStoredPathStaysAtRoot() throws {
        let (base, root, _) = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }

        let mirror = makeMirror(FolderBinding(path: root.path))
        XCTAssertEqual(mirror.currentDirectory.standardizedFileURL, root.standardizedFileURL)
    }

    /// clearLastPath 后恢复回根(BindingStore.remove 删绑定后不残留旧位置)。
    func testClearLastPathResetsRestore() throws {
        let (base, root, sub) = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }

        let binding = FolderBinding(path: root.path)
        makeMirror(binding).enter(sub)
        DirectoryMirror.clearLastPath(for: binding.id, defaults: defaults)

        let mirror = makeMirror(binding)
        XCTAssertEqual(mirror.currentDirectory.standardizedFileURL, root.standardizedFileURL)
    }

    /// 越界回退:存储里被塞入根外路径(模拟根被移动致旧绝对路径失效 / 篡改),
    /// 启动时前缀校验不过 → 回退根。此用例须直接写 key(enter 不可能持久化越界路径)。
    func testOutOfRootStoredPathFallsBackToRoot() throws {
        let (base, root, _) = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }

        let binding = FolderBinding(path: root.path)
        defaults.set("/etc", forKey: "niche.lastPath.\(binding.id.uuidString)")  // 镜像生产 key 格式(lastPathKey 私有)

        let mirror = makeMirror(binding)
        XCTAssertEqual(mirror.currentDirectory.standardizedFileURL, root.standardizedFileURL,
                       "根外存储路径不在根内 → 回退绑定根,不跳出绑定边界")
    }

    /// 兄弟前缀不被误判为根内(/root2 不是 /root 的子路径)。
    func testSiblingPrefixStoredPathFallsBackToRoot() throws {
        let (base, root, _) = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }

        let binding = FolderBinding(path: root.path)
        defaults.set(root.path + "2", forKey: "niche.lastPath.\(binding.id.uuidString)")  // root 的兄弟前缀

        let mirror = makeMirror(binding)
        XCTAssertEqual(mirror.currentDirectory.standardizedFileURL, root.standardizedFileURL)
    }
}
