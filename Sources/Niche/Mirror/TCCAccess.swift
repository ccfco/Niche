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

    /// 受 TCC「文件与文件夹」保护的标准目录(列其内容会弹授权)。各自独立授权 —— 授权家目录
    /// **不**连带授权它们。用于非用户动作路径(如 cell 渲染统计项目数)**跳过**这些目录,避免
    /// 偷偷触发弹窗;只在用户显式 arm 进入(当前目录已授权)后,其子项才安全访问。
    static let protectedDirectories: Set<URL> = {
        let fm = FileManager.default
        let dirs: [FileManager.SearchPathDirectory] =
            [.desktopDirectory, .documentDirectory, .downloadsDirectory,
             .moviesDirectory, .musicDirectory, .picturesDirectory]
        var set = Set(dirs.compactMap {
            try? fm.url(for: $0, in: .userDomainMask, appropriateFor: nil, create: false)
                .resolvingSymlinksInPath()
        })
        // iCloud Drive(CLAUDE.md 列入受保护域):SearchPathDirectory 无对应项,固定在 Mobile Documents
        // 容器,按路径补 —— 漏了它,iCloud 目录作为子项被统计时仍会偷偷弹 TCC 授权。
        set.insert(fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
            .resolvingSymlinksInPath())
        return set
    }()

    /// 该 URL 是否是受保护标准目录本身(列其内容会触发 TCC)。
    static func isProtected(_ url: URL) -> Bool {
        protectedDirectories.contains(url.resolvingSymlinksInPath())
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
