import Foundation
import Combine

/// 绑定文件夹列表的持久化(UserDefaults JSON)+ tab 顺序。
///
/// 不用 security-scoped bookmark(见 [FolderBinding])。重命名/移动追踪与 bookmark 重解析
/// 在 M2 的 DirectoryMirror 里处理;本类只负责"存什么、读什么、顺序"。
@MainActor
final class BindingStore: ObservableObject {
    private enum Key {
        static let bindings = "niche.bindings"
    }

    @Published private(set) var bindings: [FolderBinding]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.bindings = Self.load(from: defaults)
    }

    private static func load(from defaults: UserDefaults) -> [FolderBinding] {
        guard let data = defaults.data(forKey: Key.bindings),
              let decoded = try? JSONDecoder().decode([FolderBinding].self, from: data)
        else { return [] }
        return decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        defaults.set(data, forKey: Key.bindings)
    }

    func add(_ binding: FolderBinding) {
        bindings.append(binding)
        persist()
    }

    func remove(id: FolderBinding.ID) {
        bindings.removeAll { $0.id == id }
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
