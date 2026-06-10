import AppKit
import Carbon.HIToolbox

/// 全局快捷键偏好(keyCode + Carbon 修饰键 + 录制时捕获的展示文案)。
///
/// 展示文案在**录制时**从事件取(charactersIgnoringModifiers / 特殊键表),持久化跟着存
/// —— 不做 keyCode → 字符的反查(那需要 UCKeyTranslate + 键盘布局监听,为一个标签不值)。
/// RegisterEventHotKey 失败的可见错误(Carbon 只回 OSStatus,对用户无意义,给人话)。
struct HotkeyRegistrationError: LocalizedError {
    let display: String
    var errorDescription: String? {
        "「\(display)」可能已被系统或其他 App 占用,请换一个组合。"
    }
}

struct HotkeyPreference: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var display: String

    /// 默认 ⌃⌥⌘Space(避开系统 symbolic hotkey:⌥⌘Space=访达搜索、⌃⌘Space=emoji,
    /// 见 GlobalHotkey.register 注释)。
    static let `default` = HotkeyPreference(
        keyCode: 49,
        carbonModifiers: UInt32(controlKey | optionKey | cmdKey),
        display: "⌃⌥⌘Space"
    )

    // MARK: - 录制:从 keyDown 事件捕获

    /// 从按键事件生成偏好;不含 ⌘/⌃/⌥ 任一修饰键返回 nil(裸键/纯 ⇧ 会与正常输入冲突,
    /// 也注册不出可靠的全局热键)。
    static func from(event: NSEvent) -> HotkeyPreference? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else {
            return nil
        }
        var carbon: UInt32 = 0
        var symbols = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); symbols += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); symbols += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); symbols += "⌘" }
        let key = keyLabel(for: event)
        guard !key.isEmpty else { return nil }
        return HotkeyPreference(keyCode: UInt32(event.keyCode), carbonModifiers: carbon,
                                display: symbols + key)
    }

    /// 特殊键的展示名;其余用按键自身字符(忽略修饰键,大写)。
    private static let specialKeyNames: [UInt16: String] = [
        49: "Space", 36: "↩", 76: "⌅", 48: "⇥", 51: "⌫", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    private static func keyLabel(for event: NSEvent) -> String {
        if let name = specialKeyNames[event.keyCode] { return name }
        guard let chars = event.charactersIgnoringModifiers,
              let scalar = chars.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar),
              !(0xF700...0xF8FF).contains(scalar.value)   // 未列入表的功能键:不可显示,拒绝
        else { return "" }
        return chars.uppercased()
    }

    // MARK: - 持久化

    private static let defaultsKey = "niche.hotkey"

    static func load() -> HotkeyPreference {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let pref = try? JSONDecoder().decode(HotkeyPreference.self, from: data)
        else { return .default }
        return pref
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
