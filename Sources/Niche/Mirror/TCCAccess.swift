import AppKit

/// 受保护目录(Desktop/Documents/Downloads/iCloud)的 TCC 隐私授权处理(spec §4.1.1)。
///
/// 关键不变量:**不存在无副作用的 preflight** —— macOS 对受保护目录没有"只探测不弹窗"的
/// 公开 API,`contentsOfDirectory` 本身就是一次访问、会触发 TCC 弹窗。所以"访问探针"必须
/// **绑定用户显式动作**(打开 tab / 点授权按钮),禁止启动期/后台偷偷列受保护目录。
enum TCCAccess {
    /// 探针:尝试列目录。成功 = 可访问;失败 = 被拒/需授权(调用方据此显示"点此授权并重试")。
    /// 这是一次真实访问 —— 调用点必须是用户显式动作。
    static func probe(_ url: URL) -> Bool {
        do {
            _ = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: []
            )
            return true
        } catch {
            return false
        }
    }

    /// 首次被拒后,系统不会再次弹窗,需引导用户去"系统设置 › 隐私与安全性 › 文件与文件夹"
    /// 手动开启。由用户点"授权"按钮触发(非自动)。
    static func openPrivacySettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
