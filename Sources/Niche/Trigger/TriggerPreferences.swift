import Foundation

/// 触发方式偏好的**唯一真相源**(设置页与触发系统共绑):刘海热区开关、hover 触发延迟、
/// 全局快捷键。离散项 didSet 持久化；连续滑杆在编辑结束时落盘。应用到
/// HotZoneController/GlobalHotkey 由 NicheController 订阅驱动(本类纯偏好状态,不持有触发组件)。
@MainActor
final class TriggerPreferences: ObservableObject {
    /// 刘海热区触发开关(关掉后仅剩菜单栏图标 + 全局快捷键呼出)。
    @Published var hotZoneEnabled: Bool {
        didSet { UserDefaults.standard.set(hotZoneEnabled, forKey: "niche.hotZoneEnabled") }
    }

    /// hover 意图延迟(秒):鼠标停留多久算"想呼出"。默认 0.3s 对齐成熟刘海工具的稳态手感；
    /// 已保存的旧灵敏值原样保留，不在升级时静默改写用户选择。
    @Published var hoverDelay: Double

    func persistHoverDelay() {
        UserDefaults.standard.set(hoverDelay, forKey: "niche.hoverDelay")
    }

    /// 设置页连续滑杆使用对数映射：0.1–0.5s 的常用区获得足够行程，同时仍可覆盖到 5s。
    static let hoverDelayRange: ClosedRange<Double> = 0.1...5

    static func sliderPosition(for delay: Double) -> Double {
        let range = hoverDelayRange
        let clamped = min(max(delay, range.lowerBound), range.upperBound)
        return log(clamped / range.lowerBound) / log(range.upperBound / range.lowerBound)
    }

    static func hoverDelay(forSliderPosition position: Double) -> Double {
        let range = hoverDelayRange
        let clamped = min(max(position, 0), 1)
        return range.lowerBound * pow(range.upperBound / range.lowerBound, clamped)
    }

    func enablesPrimaryZone(hasNotch: Bool) -> Bool {
        hotZoneEnabled && (hasNotch || fallbackHotZoneEnabled)
    }

    /// 无刘海屏回退热区的宽度缩放(1.0 = 按屏宽 16% 的默认比例)。真实刘海不受此项影响,
    /// 见 NotchGeometry.resolve。
    @Published var hotZoneWidthScale: Double

    func persistHotZoneWidthScale() {
        UserDefaults.standard.set(hotZoneWidthScale, forKey: "niche.hotZoneWidthScale")
    }

    /// 外接显示器/无刘海 Mac 的顶部中央回退热区可独立关闭；真实刘海不受影响。
    @Published var fallbackHotZoneEnabled: Bool {
        didSet { UserDefaults.standard.set(fallbackHotZoneEnabled, forKey: "niche.fallbackHotZoneEnabled") }
    }

    /// 启用的热角(默认空,对齐 macOS 原生 Hot Corners「出厂不配置任何角」的心智)。
    /// hover-only,不支持拖拽迎上(同原生 Hot Corners)。
    @Published var enabledHotCorners: Set<ScreenCorner> {
        didSet {
            let raw = enabledHotCorners.map(\.rawValue)
            UserDefaults.standard.set(raw, forKey: "niche.enabledHotCorners")
        }
    }

    /// 启用的边缘触发(默认空)。面板从该边、鼠标所在位置滑出;hover-only,不支持拖拽迎上。
    @Published var enabledSides: Set<ScreenSide> {
        didSet {
            let raw = enabledSides.map(\.rawValue)
            UserDefaults.standard.set(raw, forKey: "niche.enabledScreenSides")
        }
    }

    /// 全局快捷键(keyCode/修饰键/展示文案)。
    @Published var hotkey: HotkeyPreference {
        didSet { hotkey.save() }
    }

    init() {
        let defaults = UserDefaults.standard
        hotZoneEnabled = defaults.object(forKey: "niche.hotZoneEnabled") as? Bool ?? true
        let savedDelay = defaults.object(forKey: "niche.hoverDelay") as? Double ?? 0.3
        hoverDelay = min(max(savedDelay, Self.hoverDelayRange.lowerBound), Self.hoverDelayRange.upperBound)
        let savedWidthScale = defaults.object(forKey: "niche.hotZoneWidthScale") as? Double ?? 1.0
        hotZoneWidthScale = min(max(savedWidthScale, 0.6), 2)
        fallbackHotZoneEnabled = defaults.object(forKey: "niche.fallbackHotZoneEnabled") as? Bool ?? true
        let rawCorners = defaults.stringArray(forKey: "niche.enabledHotCorners") ?? []
        enabledHotCorners = Set(rawCorners.compactMap(ScreenCorner.init(rawValue:)))
        let rawSides = defaults.stringArray(forKey: "niche.enabledScreenSides") ?? []
        enabledSides = Set(rawSides.compactMap(ScreenSide.init(rawValue:)))
        hotkey = HotkeyPreference.load()
    }

    /// Onboarding 用的一句话触发方式描述。始终主推刘海热区(产品主打交互,不能被"当前恰好关着"
    /// 埋没)——热区开着就讲怎么用,关着则讲清楚同时给出开启入口 + 当前可用的替代方式(快捷键),
    /// 不是简单"配成什么就说什么"。
    var onboardingTriggerDescription: String {
        if hotZoneEnabled {
            return String(localized: "从屏幕顶部(刘海所在位置)滑出——把鼠标移到那里就能唤出 Niche。")
        } else {
            return String(localized: "把鼠标移到屏幕顶部(刘海所在位置)就能唤出 Niche——这个热区目前是关闭的,可以点下面「去设置」打开;当前也能用快捷键「\(hotkey.display)」呼出。")
        }
    }
}
