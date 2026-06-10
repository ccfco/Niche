import Foundation

/// type-ahead 键入跳选(Finder 同款):连续键入的字符在超时窗口内拼成前缀,跳选首个
/// 名称匹配项;停顿超时后重新开始。纯状态 + 注入时间,可单测。
struct TypeAheadBuffer {
    private(set) var buffer = ""
    private var lastInput = Date.distantPast
    /// 连击窗口:Finder 实测约 1s,停顿超过即视为新一轮输入。
    var timeout: TimeInterval = 1.0

    /// 追加输入并返回当前累计前缀。
    mutating func append(_ chars: String, at now: Date = Date()) -> String {
        if now.timeIntervalSince(lastInput) > timeout { buffer = "" }
        buffer += chars
        lastInput = now
        return buffer
    }

    mutating func reset() {
        buffer = ""
        lastInput = .distantPast
    }

    /// 该按键是否参与 type-ahead:可见字符才算(控制键/F 键等私有区码位不算;空格被
    /// Quick Look 占用,方向键/Esc/Return 在 keyMonitor 更早的分支已各有语义)。
    static func isTypeAheadInput(_ chars: String?) -> Bool {
        guard let chars, let scalar = chars.unicodeScalars.first else { return false }
        // 0xF700-0xF8FF:NSEvent 用 Unicode 私有区表示功能键(方向/F1-F12/Page 等)。
        if (0xF700...0xF8FF).contains(scalar.value) { return false }
        if CharacterSet.controlCharacters.contains(scalar) { return false }
        if chars == " " { return false }
        return true
    }

    /// 在 names 里找首个以 prefix 开头的下标(忽略大小写与音调,本地化比较)。
    static func firstMatch(prefix: String, in names: [String]) -> Int? {
        guard !prefix.isEmpty else { return nil }
        return names.firstIndex {
            $0.range(of: prefix, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
        }
    }
}
