import ServiceManagement

/// 开机自启(SMAppService.mainApp,macOS 13+ 标准途径;不沙盒自分发 app 从 /Applications
/// 运行即可注册,无需 helper)。失败上抛由设置页弹可见提示(不静默吞)。
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
