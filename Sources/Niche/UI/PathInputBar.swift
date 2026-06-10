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
        // 再次触发(⌘⇧G / 键入 `/`)且焦点不在框内 → 重新夺焦并全选(直接打字即覆盖旧路径)。
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            if let window = nsView.window, nsView.currentEditor() == nil {
                window.makeFirstResponder(nsView)
                nsView.currentEditor()?.selectedRange =
                    NSRange(location: 0, length: (nsView.stringValue as NSString).length)
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

        func controlTextDidChange(_ obj: Notification) {
            parent.onEdit()
            guard !isCompleting,
                  let field = obj.object as? NSTextField,
                  let editor = field.currentEditor() else { return }
            let text = field.stringValue
            defer { lastLength = (text as NSString).length }

            let length = (text as NSString).length
            let grew = length > lastLength
            // 仅在光标位于末尾的增长型编辑时补全(中段编辑/删除不打扰)。
            guard grew, editor.selectedRange.location == length, editor.selectedRange.length == 0
            else { return }

            let expanded = PathCompleter.expand(text)
            guard let suggestion = PathCompleter.suggest(expanded),
                  (suggestion as NSString).length > (expanded as NSString).length,
                  suggestion.lowercased().hasPrefix(expanded.lowercased())
            else { return }

            // 用户输入形态保留(尤其 ~ 前缀不被展开形替换):建议只追加"展开形之后多出来的尾巴"。
            let tail = (suggestion as NSString).substring(from: (expanded as NSString).length)
            isCompleting = true
            field.stringValue = text + tail
            editor.selectedRange = NSRange(location: length, length: (tail as NSString).length)
            isCompleting = false
            lastLength = (field.stringValue as NSString).length
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
