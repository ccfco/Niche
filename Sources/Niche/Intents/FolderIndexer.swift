import AppIntents
import CoreSpotlight
import Foundation

/// 把固定文件夹推进系统 Spotlight 索引。实体身份来自绑定 id,面板/设置里的增删改都经
/// `NicheController` 的绑定回调汇到这里 —— 索引内容与 tab 列表同源,不另存一份。
///
/// **按签名跳过无变化重建**:签名 = 应用 build + 绑定(id/别名/路径),顺序无关。启动和单纯
/// 拖 tab 排序不会重复删写索引;改名/改路径/增删才会。失败不写签名(下次启动或绑定变化重试)。
/// 已知边界:系统 Spotlight 索引被外部清空时签名仍匹配,需改一次绑定或升级应用才会重建。
/// 先删旧实体再整体写入:N 很小,省掉"哪条被删了"的差集簿记;签名没变时这段根本不跑。
@MainActor
final class FolderIndexer {
    static let shared = FolderIndexer()

    private enum Keys {
        static let signature = "niche.spotlightIndexSignature"
    }

    private let defaults: UserDefaults
    private var inFlight: Task<Void, Never>?
    private var pending: [FolderBinding]?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 主线程调用:记录最新绑定并串行消费。索引期间又来变更 → 结束当前轮后自动补跑,
    /// 不并发出两轮"删全部 + 写全部"。
    func refresh(_ bindings: [FolderBinding]) {
        pending = bindings
        guard inFlight == nil else { return }
        inFlight = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        while let bindings = pending {
            pending = nil
            let signature = Self.fullSignature(for: bindings)
            guard signature != defaults.string(forKey: Keys.signature) else { continue }

            do {
                let index = CSSearchableIndex.default()
                try await index.deleteAppEntities(ofType: FolderEntity.self)
                let entities = bindings.map(FolderEntity.init)
                if !entities.isEmpty {
                    try await index.indexAppEntities(entities)
                }
                defaults.set(signature, forKey: Keys.signature)
            } catch {
                Log.intents.error("文件夹 Spotlight 索引刷新失败:\(error.localizedDescription, privacy: .public)")
                // 不写签名:下次启动/绑定变化会重试;不在此处紧循环重试。
                break
            }
        }
        inFlight = nil
    }

    /// 绑定内容签名(不含应用 build,便于测试):按 id 排序消除拖 tab 顺序影响,
    /// 用不可见分隔符避免拼接碰撞。
    nonisolated static func signature(for bindings: [FolderBinding]) -> String {
        bindings
            .map { "\($0.id.uuidString)\u{1F}\($0.displayName)\u{1F}\($0.path)" }
            .sorted()
            .joined(separator: "\u{1E}")
    }

    /// 实际落盘的签名:叠加应用 build,升级后强制重建一次(实体元数据可能随版本变化)。
    private static func fullSignature(for bindings: [FolderBinding]) -> String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "\(build)\u{1E}\(signature(for: bindings))"
    }
}
