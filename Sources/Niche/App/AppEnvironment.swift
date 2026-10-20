import Foundation
import Observation

/// 依赖容器:集中持有跨模块共享的长生命周期服务,避免单例散落。
///
/// MVP 阶段服务很少,随里程碑逐步挂载(BindingStore / 各 DirectoryMirror / PanelController …)。
/// `@Observable` 让 SwiftUI 侧(SettingsView 等)经 `@Environment(AppEnvironment.self)` 注入;
/// 绑定变化本身由 BindingStore 的属性级追踪负责。
@MainActor @Observable
final class AppEnvironment {
    /// 绑定文件夹的持久化存储(路径/普通 bookmark,非 security-scoped)。
    let bindingStore: BindingStore

    init() {
        self.bindingStore = BindingStore()
    }
}
