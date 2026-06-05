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

    /// 给定目录当前所在卷是否仍挂载(目录可访问即视为挂载)。
    static func isVolumeMounted(for url: URL) -> Bool {
        (try? url.checkResourceIsReachable()) ?? false
    }
}
