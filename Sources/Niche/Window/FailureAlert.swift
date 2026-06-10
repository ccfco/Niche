import AppKit

/// 用户动作失败的统一可见提示(不静默吞错,CLAUDE.md):标题说清"哪个动作失败",正文带系统错误。
///
/// 弹窗期间挂 `.modalDialog` 抑制:NSAlert 成 key 会让瞬态面板 resignKey、鼠标移去点按会离开
/// 走廊,不抑制则提示还没读完面板已被挤收回。
@MainActor
enum FailureAlert {
    static func present(title: String, error: Error, autoHide: AutoHideCoordinator) {
        autoHide.begin(.modalDialog)
        defer { autoHide.end(.modalDialog) }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
