import AppIntents
import Foundation

/// Intents 与 AppKit 控制器之间的窄桥。AppIntent 不持有视图/面板实现,只把"要打开哪个 tab"
/// 交给运行中的 `NicheController`;控制器由 AppDelegate 在启动时注入。
@MainActor
final class IntentBridge {
    static let shared = IntentBridge()

    weak var controller: NicheController?

    private init() {}
}

enum NicheIntentError: LocalizedError {
    case notReady
    case folderUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .notReady:
            String(localized: "Niche 尚未就绪，请重试。")
        case let .folderUnavailable(name):
            String(localized: "「\(name)」已不在 Niche 中。")
        }
    }
}