import Foundation
import Testing
@testable import Niche

/// BindingStore 从 Combine 迁到 Observation 后,宿主靠显式 onChange 重建镜像 —— 钉住
/// "回调携带的是变更后的列表"这一契约(先重建再读注册表会拿到旧列表)。
@MainActor
@Suite("BindingStore 变更回调")
struct BindingStoreObservationTests {
    @Test("增删改后回调携带最新列表")
    func onChangeCarriesLatestBindings() throws {
        let suite = "niche.tests.bindingstore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = BindingStore(defaults: defaults)
        var snapshots: [[FolderBinding]] = []
        store.onChange = { snapshots.append($0) }

        let binding = FolderBinding(path: "/tmp/Design", displayName: "设计稿")
        store.add(binding)
        #expect(snapshots.last?.map(\.id) == [binding.id])

        var renamed = binding
        renamed.displayName = "设计稿 2026"
        store.update(renamed)
        #expect(snapshots.last?.first?.displayName == "设计稿 2026")

        store.remove(id: binding.id)
        #expect(snapshots.last?.isEmpty == true)
    }

    @Test("写入后新实例读回同一列表")
    func persistsBindings() throws {
        let suite = "niche.tests.bindingstore.persist.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = BindingStore(defaults: defaults)
        let binding = FolderBinding(path: "/tmp/Archive", displayName: "归档")
        store.add(binding)

        let reloaded = BindingStore(defaults: defaults)
        #expect(reloaded.bindings.map(\.id) == [binding.id])
        #expect(reloaded.bindings.first?.displayName == "归档")
    }
}