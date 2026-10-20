import AppIntents
import CoreSpotlight
import UniformTypeIdentifiers

/// 一个「固定的文件夹」在 App Intents / Spotlight 中的表示。id 用 `FolderBinding.id`,
/// 与 tab 身份同源;不暴露临时 tab(未持久化,系统索引里没有它的稳定身份)。
struct FolderEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Niche 文件夹")
    static let defaultQuery = FolderEntityQuery()

    /// `FolderBinding.id` 的字符串形式 —— `AppEntity.ID` 必须是跨进程稳定的值。
    let id: String
    let name: String
    let path: String

    init(binding: FolderBinding) {
        self.id = binding.id.uuidString
        self.name = binding.displayName
        self.path = binding.path
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(path)")
    }

    /// Spotlight 结果里展示的元数据。`title`/`displayName` 用 tab 别名而不是路径末段,
    /// 用户在 Niche 里改过的名字应当一路贯彻到系统搜索。
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .folder)
        attributes.title = name
        attributes.displayName = name
        attributes.path = path
        attributes.contentDescription = String(localized: "Niche 中固定的文件夹")
        attributes.keywords = ["Niche", name]
        return attributes
    }
}

/// 查询直接读 `BindingStore` 的持久化数据,不依赖 `NicheController` 已启动:
/// Spotlight 建议和 Shortcuts 参数选择可能先于面板控制器构造发生。
struct FolderEntityQuery: EntityQuery, EnumerableEntityQuery {
    func entities(for identifiers: [FolderEntity.ID]) async throws -> [FolderEntity] {
        let wanted = Set(identifiers)
        return try await allEntities().filter { wanted.contains($0.id) }
    }

    func allEntities() async throws -> [FolderEntity] {
        BindingStore.load(from: .standard).map(FolderEntity.init)
    }

    func suggestedEntities() async throws -> [FolderEntity] {
        try await allEntities()
    }
}