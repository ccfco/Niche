import Foundation

/// 路径输入(前往)的补全纯逻辑(spec:specs/2026-06-10-niche-path-input-design.md)。
/// 只做"父目录列举 + 前缀匹配",不做 glob/相对路径/环境变量(YAGNI)。纯函数可单测。
enum PathCompleter {
    /// `~` 展开为当前用户 home(`~/x` 与裸 `~`);其余原样返回。
    /// expandingTildeInPath 会吞尾 `/`,补回 —— 尾 `/` 携带"在此目录内继续补全"的语义。
    static func expand(_ input: String) -> String {
        guard input.hasPrefix("~") else { return input }
        let expanded = NSString(string: input).expandingTildeInPath
        if input.hasSuffix("/"), !expanded.hasSuffix("/") { return expanded + "/" }
        return expanded
    }

    /// 对部分路径给出 inline 补全建议:返回**完整建议串**(含已输入部分;目录带尾 `/`
    /// 以便连续下钻),无匹配返回 nil。
    ///
    /// 规则(Finder ⌘⇧G 同款手感):
    /// - 只对绝对路径补全(`~` 由调用方先 expand);以 `/` 结尾(无未完成段)不补。
    /// - 在父目录里做**忽略大小写/音调**的前缀匹配;目录优先于文件,组内 localizedStandard 排序。
    /// - 隐藏项仅在已键入 `.` 前缀时参与(与"默认不显示隐藏文件"一致,不替用户翻垃圾)。
    static func suggest(_ input: String) -> String? {
        guard input.hasPrefix("/"), !input.hasSuffix("/") else { return nil }
        let ns = input as NSString
        let parent = ns.deletingLastPathComponent
        let partial = ns.lastPathComponent
        guard !partial.isEmpty else { return nil }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: parent, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: partial.hasPrefix(".") ? [] : [.skipsHiddenFiles]
        ) else { return nil }

        let matches = entries
            .filter {
                $0.lastPathComponent.range(
                    of: partial, options: [.caseInsensitive, .diacriticInsensitive, .anchored]
                ) != nil
            }
            .sorted { lhs, rhs in
                let lDir = (try? lhs.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let rDir = (try? rhs.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if lDir != rDir { return lDir }   // 目录优先(补全目标多半是想下钻)
                return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
        guard let best = matches.first else { return nil }

        let isDir = (try? best.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let name = best.lastPathComponent
        let base = parent == "/" ? "/" : parent + "/"
        return base + name + (isDir ? "/" : "")
    }

    /// 提交时的目标判定。
    enum Target: Equatable {
        case directory(URL)
        case file(URL)
        case missing
    }

    /// 展开 + 标准化 + 存在性判定(symlink 不解析:进入链接目录看到的路径应保留用户输入形态,
    /// 与 Finder 前往一致)。非绝对路径视为 missing(不猜相对于谁)。
    /// 原样查不到时再试 shell 反转义形态:访达「拷贝为路径名称」/终端拖入给的是 `\ `、`\~`
    /// 转义路径,原样按 POSIX 查必 miss。原样优先 —— 真实文件名可含字面 `\`。
    static func resolve(_ input: String) -> Target {
        let expanded = expand(input.trimmingCharacters(in: .whitespacesAndNewlines))
        guard expanded.hasPrefix("/") else { return .missing }
        if let target = existingTarget(expanded) { return target }
        let unescaped = shellUnescaped(expanded)
        guard unescaped != expanded else { return .missing }
        return existingTarget(unescaped) ?? .missing
    }

    /// shell 反转义:`\X` → `X`(`\\` → `\`);末尾孤立 `\` 不是转义,原样保留。
    private static func shellUnescaped(_ input: String) -> String {
        var out = ""
        var iterator = input.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            guard scalar == "\\" else {
                out.unicodeScalars.append(scalar)
                continue
            }
            if let escaped = iterator.next() {
                out.unicodeScalars.append(escaped)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func existingTarget(_ path: String) -> Target? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return nil
        }
        return isDir.boolValue ? .directory(url) : .file(url)
    }
}
