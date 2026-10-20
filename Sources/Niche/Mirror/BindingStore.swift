import Foundation
import Observation

/// 绑定文件夹列表的持久化(UserDefaults JSON)+ tab 顺序。
///
/// 不用 security-scoped bookmark(见 [FolderBinding])。重命名/移动追踪与 bookmark 重解析
/// 在 M2 的 DirectoryMirror 里处理;本类只负责"存什么、读什么、顺序"。
@MainActor @Observable
final class BindingStore {
    private enum Key {
        static let bindings = "niche.bindings"
    }

    private(set) var bindings: [FolderBinding]

    /// 变更后的旁路回调(非视图消费):NicheController 据此重建镜像。
    /// Observation 没有 catch-all,订阅方显式挂这里。
    @ObservationIgnored var onChange: (([FolderBinding]) -> Void)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.bindings = Self.load(from: defaults)
    }

    /// 从持久化数据还原绑定列表。`nonisolated` 供 App Intents 的实体查询在任意执行器读取
    /// (Shortcuts/Spotlight 可能先于 `BindingStore` 实例化)。
    nonisolated static func load(from defaults: UserDefaults) -> [FolderBinding] {
        guard let data = defaults.data(forKey: Key.bindings) else { return [] }
        guard let decoded = try? JSONDecoder().decode([FolderBinding].self, from: data) else {
            Log.mirror.error("绑定数据解码失败,本次按空列表启动(UserDefaults 数据保留待排查)")
            return []
        }
        return decoded
    }

    private func persist() {
        // 内存里的绑定已变,回调必须发(镜像/设置页据此同步);编码失败只影响下次启动。
        defer { onChange?(bindings) }
        guard let data = try? JSONEncoder().encode(bindings) else {
            Log.mirror.error("绑定数据编码失败,本次变更未持久化")
            return
        }
        defaults.set(data, forKey: Key.bindings)
    }

    func add(_ binding: FolderBinding) {
        bindings.append(binding)
        persist()
    }

    /// 批量追加(拖入多个文件夹一次固定):一次 append + 一次 persist + 一次 Observation 变更,
    /// 避免逐个 add 触发 N 次持久化与 N 次镜像重建(Codex review)。空数组为 no-op。
    func add(_ newBindings: [FolderBinding]) {
        guard !newBindings.isEmpty else { return }
        bindings.append(contentsOf: newBindings)
        persist()
    }

    /// 在指定 index 插入(拖文件夹「定位固定」):落点由 tab 栏插入光标算出。index 越界夹到
    /// 合法区间(末尾追加),不崩。空数组为 no-op。
    func insert(_ newBindings: [FolderBinding], at index: Int) {
        guard !newBindings.isEmpty else { return }
        bindings.insert(contentsOf: newBindings, at: min(max(index, 0), bindings.count))
        persist()
    }

    func remove(id: FolderBinding.ID) {
        bindings.removeAll { $0.id == id }
        DirectoryMirror.clearLastPath(for: id, defaults: defaults)   // 防 per-binding 下钻位置 key 泄漏(同后端才清得到)
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        bindings.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func update(_ binding: FolderBinding) {
        guard let index = bindings.firstIndex(where: { $0.id == binding.id }) else { return }
        bindings[index] = binding
        persist()
    }
}
