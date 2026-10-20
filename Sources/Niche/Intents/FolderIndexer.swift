import AppIntents
import CoreSpotlight

/// 把固定文件夹推进系统 Spotlight 索引。实体身份来自绑定 id,面板/设置里的增删改都经
/// `NicheController` 的绑定订阅汇到这里 —— 索引内容与 tab 列表同源,不另存一份。
///
/// 先删同类型旧实体再整体写入:N 很小(用户手选的固定文件夹),省掉"哪条被删了"的差集
/// 簿记;失败只记日志,不影响面板使用(Spotlight 是增强入口,不是主链路)。
enum FolderIndexer {
    static func refresh(_ bindings: [FolderBinding]) {
        let entities = bindings.map(FolderEntity.init)
        Task.detached(priority: .utility) {
            do {
                let index = CSSearchableIndex.default()
                try await index.deleteAppEntities(ofType: FolderEntity.self)
                if !entities.isEmpty {
                    try await index.indexAppEntities(entities)
                }
            } catch {
                Log.intents.error("文件夹 Spotlight 索引刷新失败:\(error.localizedDescription, privacy: .public)")
            }
        }
    }
}