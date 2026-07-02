import AppKit

/// 外置卷 / 网络卷挂载-卸载监听(spec §4.1.1:绑定目录整卷消失 → "卷已卸载"空态,
/// 卷重新挂载后探针成功自动重连,不删用户绑定)。
@MainActor
final class VolumeMonitor {
    /// 卷卸载(传出被卸载卷的挂载点路径)。
    var onUnmount: ((URL) -> Void)?
    /// 卷挂载(传出新挂载点路径)。
    var onMount: ((URL) -> Void)?

    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                if let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                    self?.onUnmount?(url)
                }
            }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                if let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                    self?.onMount?(url)
                }
            }
        })
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
    }

    /// 给定目录所在卷是否仍挂载:按挂载点存在性判定(/Volumes/<卷名> 在不在)。
    /// 不能用 checkResourceIsReachable —— 目录被删时同样 unreachable,会把"目录没了"
    /// 误归因成"卷已卸载"(体检审计:误报让用户以为要插回 U 盘,实际该去废纸篓找)。
    /// 启动卷路径(非 /Volumes 下)恒视为挂载;外接/网络卷在 macOS 统一挂在 /Volumes 下。
    nonisolated static func isVolumeMounted(for url: URL) -> Bool {
        let comps = url.standardizedFileURL.pathComponents
        guard comps.count > 2, comps[1] == "Volumes" else { return true }
        return FileManager.default.fileExists(atPath: "/Volumes/\(comps[2])")
    }

    /// 卷显示名:外接卷取挂载点目录名(/Volumes/<卷名>);启动卷路径回落末段目录名。
    /// 此前空态直接用 lastPathComponent —— 深层子目录会把子目录名当卷名展示。
    nonisolated static func volumeDisplayName(for url: URL) -> String {
        let comps = url.standardizedFileURL.pathComponents
        if comps.count > 2, comps[1] == "Volumes" { return comps[2] }
        return url.lastPathComponent
    }
}
