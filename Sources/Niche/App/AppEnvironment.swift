import Foundation

/// 依赖容器:集中持有跨模块共享的长生命周期服务,避免单例散落。
///
/// MVP 阶段服务很少,随里程碑逐步挂载(BindingStore / 各 DirectoryMirror / PanelController …)。
/// 用 `ObservableObject` 让 SwiftUI 侧(SettingsView 等)可观察绑定变化。
@MainActor
final class AppEnvironment: ObservableObject {
    /// 绑定文件夹的持久化存储(路径/普通 bookmark,非 security-scoped)。
    let bindingStore: BindingStore

    init() {
        self.bindingStore = BindingStore()
    }
}
