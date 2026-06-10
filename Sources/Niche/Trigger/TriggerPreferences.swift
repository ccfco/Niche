import Foundation

/// 触发方式偏好的**唯一真相源**(设置页与触发系统共绑):刘海热区开关、hover 触发延迟、
/// 全局快捷键。didSet 持久化;应用到 HotZoneController/GlobalHotkey 由 NicheController
/// 订阅驱动(本类纯偏好状态,不持有触发组件)。
@MainActor
final class TriggerPreferences: ObservableObject {
    /// 刘海热区触发开关(关掉后仅剩菜单栏图标 + 全局快捷键呼出)。
    @Published var hotZoneEnabled: Bool {
        didSet { UserDefaults.standard.set(hotZoneEnabled, forKey: "niche.hotZoneEnabled") }
    }

    /// hover 意图延迟(秒):鼠标停留多久算"想呼出"。越小越灵敏、也越容易误触。
    @Published var hoverDelay: Double {
        didSet { UserDefaults.standard.set(hoverDelay, forKey: "niche.hoverDelay") }
    }

    /// 全局快捷键(keyCode/修饰键/展示文案)。
    @Published var hotkey: HotkeyPreference {
        didSet { hotkey.save() }
    }

    /// 触发延迟的预设档(设置页 Picker;自由滑杆对 0.18 这种手感值反而难选准)。
    static let hoverDelayPresets: [(label: String, value: Double)] = [
        ("灵敏(0.1s)", 0.1), ("标准(0.18s)", 0.18), ("稳重(0.4s)", 0.4),
    ]

    init() {
        let defaults = UserDefaults.standard
        hotZoneEnabled = defaults.object(forKey: "niche.hotZoneEnabled") as? Bool ?? true
        hoverDelay = defaults.object(forKey: "niche.hoverDelay") as? Double ?? 0.18
        hotkey = HotkeyPreference.load()
    }
}
