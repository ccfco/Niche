import AppKit

/// 调起访达原生的「显示简介」(Get Info)窗口。
///
/// Get Info 面板是访达进程私有的 UI,**没有 AppKit 公开 API 能在本进程内弹起**。唯一正解是经
/// Apple Events 驱动访达弹它自己的 `information window` —— `open information window of` 是访达脚本
/// 字典存在已久的标准命令(区别于「自定义文件夹」外观:那在 26.5 实测无字典命令,故无法编程弹起,
/// 见 ContextMenuBuilder.doCustomizeFolder)。这是 spec「Get Info 系统硬边界搬不过来」结论的细化:
/// 面板本体搬不过来,但可驱动访达弹它自己的,功能 100% 齐全且永远跟随系统,零维护。
///
/// 代价(均为本动作语义内可接受):
/// ① 跳访达抢焦点 —— 「显示简介」语义上是「进入认真处理此文件」的长尾出口(同「在 Finder 中显示」),
///    非高频取用路径,抢焦点合理;
/// ② macOS 10.14+ 发 Apple Events 受 TCC「自动化」管控,首次弹授权(同步阻塞,故调用方须包
///    withModalContext:抑制收回 + 降级面板 level,否则系统授权窗成 key 时面板被收/遮挡),被拒后
///    系统不再弹,需引导去「系统设置 › 隐私与安全性 › 自动化」。
@MainActor
enum FinderGetInfo {
    enum Outcome {
        case shown
        case notAuthorized      // TCC「自动化」被拒(errAEEventNotPermitted)→ 引导去系统设置
        case failed(Error)
    }

    /// 为选区每个 URL 弹一个简介窗口(对齐访达 ⌘I 多选逐个弹)。空选区 no-op(返回 .shown)。
    /// 必须在主线程调用(驱动访达 + 可能弹系统授权窗)。
    @discardableResult
    static func show(_ urls: [URL]) -> Outcome {
        guard !urls.isEmpty else { return .shown }

        // 逐项 `open information window of` 而非一次性传 list:每项一行,语义确定、各弹一窗,
        // 不赌访达对 `information window of {list}` 的解释。activate 一次置访达前台。
        let lines = urls
            .map { "    open information window of (POSIX file \"\(escapedForAppleScript($0.path))\" as alias)" }
            .joined(separator: "\n")
        let source = """
        tell application "Finder"
            activate
        \(lines)
        end tell
        """

        guard let script = NSAppleScript(source: source) else {
            return .failed(NSError(domain: "FinderGetInfo", code: -1,
                                   userInfo: [NSLocalizedDescriptionKey: "无法构造 AppleScript"]))
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return .shown }

        let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
        if code == errAEEventNotPermitted { return .notAuthorized }
        let message = (errorInfo[NSAppleScript.errorMessage] as? String)
            ?? (errorInfo[NSAppleScript.errorBriefMessage] as? String)
            ?? "访达执行「显示简介」失败"
        return .failed(NSError(domain: "FinderGetInfo", code: code,
                               userInfo: [NSLocalizedDescriptionKey: message]))
    }

    /// 自动化授权被拒后的引导(系统首拒后不再自动弹,只能手动去设置)。带「打开系统设置」直达
    /// 自动化面板。autoHide 抑制同 FailureAlert:弹窗成 key 会让瞬态面板收回。
    static func presentAuthorizationAlert(autoHide: AutoHideCoordinator) {
        autoHide.begin(.modalDialog)
        defer { autoHide.end(.modalDialog) }
        let alert = NSAlert()
        alert.messageText = "需要「自动化」权限"
        alert.informativeText = "「显示简介」需要让 Niche 控制「访达」。请在「系统设置 › 隐私与安全性 › 自动化」中允许 Niche 控制访达,然后重试。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// 转义为 AppleScript 字符串字面量。顺序不可换:`\` 必须最先(否则会二次转义后面插入的反斜杠);
    /// 引号其次;换行最后(转成 `\r`/`\n` 转义序列,本身带反斜杠,故必须排在 `\` 规则之后)。
    /// 防路径含 `"` / `\` 破坏脚本语法(注入),以及含换行(macOS 文件名合法含 `\n`/`\r`)致字符串
    /// 字面量跨物理行、脚本语法错 —— Finder 对这类文件名能正常 Get Info,不能在此阉割正确性。
    private static func escapedForAppleScript(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
