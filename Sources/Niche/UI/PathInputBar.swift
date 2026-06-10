import AppKit
import SwiftUI

/// 路径输入条(前往,spec:specs/2026-06-10-niche-path-input-design.md):
/// 面板顶部滑出的一行,⌘⇧G / 键入 `/`、`~` 弹出。Enter 前往,Esc 关闭,错误红框留条。
struct PathInputBar: View {
    @ObservedObject var model: PanelModel
    let edge: EdgeMetrics
    /// 提交路径;返回 false = 路径不存在/非法(条上显错,不关)。成功路径由宿主收口
    /// (endPathInput / 收面板),本视图不自作主张。
    var onGoToPath: (String) -> Bool = { _ in false }

    @State private var hasError = false

    var body: some View {
        HStack(spacing: edge.innerSpacing) {
            Image(systemName: "arrow.turn.down.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            PathTextField(
                initialText: model.pathInputInitial,
                focusToken: model.pathInputFocusToken,
                onSubmit: { text in
                    let accepted = onGoToPath(text)
                    if !accepted {
                        hasError = true
                        NSSound.beep()
                    }
                    return accepted
                },
                onEdit: { hasError = false },          // 再次编辑即清错
                onCancel: { model.endPathInput() }
            )
            if hasError {
                Text("路径不存在")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, edge.panelPadding)
        .padding(.vertical, edge.innerSpacing)
        .accessibilityLabel("前往路径")
    }
}

/// AppKit 桥接的路径输入框:NSTextField + 选中式 inline 补全(Safari 地址栏/Finder ⌘⇧G 同款
/// 实现:把建议的剩余部分追加为**选中文本**,继续打字自然覆盖,Tab/→ 接受)。
/// SwiftUI TextField 控制不了选区,无法做这种补全,故桥接(与 RenameTextField 同模式:
/// 文本由 NSTextField 自持,提交时读 stringValue,不绑 @State 规避播种竞态)。
private struct PathTextField: NSViewRepresentable {
    let initialText: String
    /// 聚焦代次(model.beginPathInput 自增):条已开但焦点回了列表,再次触发要重新夺焦。
    let focusToken: Int
    /// 返回是否被接受(失败时输入框保持焦点原地可改)。
    let onSubmit: (String) -> Bool
    let onEdit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> FocusingPathField {
        let field = FocusingPathField(string: initialText)
        context.coordinator.lastFocusToken = focusToken
        field.delegate = context.coordinator
        field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.controlSize = .small
        field.bezelStyle = .roundedBezel
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingHead   // 长路径看尾部(当前所在),与 Finder 标题栏一致
        field.placeholderString = "输入路径,如 /usr/local 或 ~/Downloads"
        return field
    }

    func updateNSView(_ nsView: FocusingPathField, context: Context) {
        context.coordinator.parent = self
        // 再次触发(⌘⇧G / 键入 `/`、`~`)且焦点不在框内 → 重新夺焦。带首字符的触发把文本
        // 重置为该字符(否则那一击被键盘权威吃掉、旧路径还赖在框里);⌘⇧G(无首字符)保留
        // 旧文本全选,直接打字即覆盖(Finder ⌘⇧G 同款)。
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            if let window = nsView.window, nsView.currentEditor() == nil {
                window.makeFirstResponder(nsView)
                if initialText.isEmpty {
                    nsView.currentEditor()?.selectedRange =
                        NSRange(location: 0, length: (nsView.stringValue as NSString).length)
                } else {
                    nsView.stringValue = initialText
                    context.coordinator.noteProgrammaticChange(length: (initialText as NSString).length)
                    nsView.currentEditor()?.selectedRange =
                        NSRange(location: (initialText as NSString).length, length: 0)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PathTextField
        var lastFocusToken = 0
        /// 上一次文本长度:只在"净增长"(打字/粘贴)时补全 —— 删除后再补全会让用户永远删不掉。
        private var lastLength = 0
        /// 程序写入(补全)引起的 didChange 不再触发补全,防递归。
        private var isCompleting = false

        init(_ parent: PathTextField) { self.parent = parent }

        /// 程序性写入(补全/重置)后同步长度基线 —— 程序写入不触发 controlTextDidChange,
        /// 否则下一次人工输入的"净增长"判定会失真。
        func noteProgrammaticChange(length: Int) {
            lastLength = length
        }

        func controlTextDidChange(_ obj: Notification) {
            parent.onEdit()
            guard !isCompleting,
                  let field = obj.object as? NSTextField,
                  let editor = field.currentEditor() else { return }
            // 输入法组合态(拼音未上屏)不补全:此刻 stringValue 是 marked text,把它当
            // 成品路径去匹配/改选区会打断组合(Codex review,中文目录名是常规场景)。
            if let textView = editor as? NSTextView, textView.hasMarkedText() { return }
            let text = field.stringValue
            defer { lastLength = (text as NSString).length }

            let length = (text as NSString).length
            let grew = length > lastLength
            // 仅在光标位于末尾的增长型编辑时补全(中段编辑/删除不打扰)。
            guard grew, editor.selectedRange.location == length, editor.selectedRange.length == 0
            else { return }

            let expanded = PathCompleter.expand(text)
            guard let suggestion = PathCompleter.suggest(expanded) else { return }
            // 把"未完成段"整体替换为磁盘上的真实拼写(Finder 同款):只追加尾巴会保留用户
            // 键入的大小写/音调形态,大小写敏感卷上提交必失败(Codex review)。
            // suggestion = 展开形父目录 + 真实条目名(+/),故未完成段之前的部分照搬用户原文
            // (保留 ~ 输入形态),之后取 suggestion 的对应尾部。
            let partialLen = (((expanded as NSString).lastPathComponent) as NSString).length
            let basePrefixLen = length - partialLen                      // 用户原文中未完成段起点
            let suggestionBaseLen = (expanded as NSString).length - partialLen
            guard basePrefixLen >= 0, suggestionBaseLen >= 0,
                  (suggestion as NSString).length > suggestionBaseLen else { return }
            let replacement = (suggestion as NSString).substring(from: suggestionBaseLen)
            let newText = (text as NSString).substring(to: basePrefixLen) + replacement
            guard newText != text else { return }                        // 已是完整真实拼写,无事可补

            isCompleting = true
            field.stringValue = newText
            // 选中"用户已键入长度之后"的部分:继续打字覆盖,Tab/→ 接受。音调不敏感匹配下
            // 真实名与键入段长度可能不同,夹取防越界。
            let newLength = (newText as NSString).length
            let selStart = min(length, newLength)
            editor.selectedRange = NSRange(location: selStart, length: newLength - selStart)
            isCompleting = false
            lastLength = newLength
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // 提交整串(含补全选中部分);失败保持编辑态原地改(同 RenameTextField 取舍)。
                _ = parent.onSubmit(control.stringValue)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.moveRight(_:)):
                // IME 组合态的 Tab/→ 是候选词操作,原样还给输入法(Codex review)。
                if textView.hasMarkedText() { return false }
                // Tab / → 接受补全:光标跳到末尾、清选区(→ 在无选区时保持默认行为)。
                guard let editor = control.currentEditor(), editor.selectedRange.length > 0 else {
                    return selector == #selector(NSResponder.insertTab(_:))   // Tab 不跳焦点,吃掉
                }
                editor.selectedRange = NSRange(location: (control.stringValue as NSString).length, length: 0)
                return true
            default:
                return false
            }
        }
    }
}

/// 挂上 window 即夺焦,光标置末尾(带入的 `/`、`~` 首字符后继续输入)。
final class FocusingPathField: NSTextField {
    private var didApplyInitialFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didApplyInitialFocus, let window else { return }
        didApplyInitialFocus = true
        window.makeFirstResponder(self)
        let end = (stringValue as NSString).length
        currentEditor()?.selectedRange = NSRange(location: end, length: 0)
    }
}
