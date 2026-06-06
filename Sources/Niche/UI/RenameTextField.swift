import AppKit
import SwiftUI

/// 就地重命名输入框(AppKit 桥接)。
///
/// SwiftUI `TextField` 无法控制初始选区,而 Finder 重命名默认选中「文件名主干(不含扩展名)」
/// —— 这是 Finder 语义底线(CLAUDE.md:Finder 能做的在自己范围内不阉割)。故用 `NSTextField`:
/// 成为第一响应者时选中主干,Enter 提交,Esc / 失焦取消。文本由 NSTextField 自持(提交时读
/// `stringValue`),不绑 SwiftUI `@State`,规避「makeNSView 早于 onAppear 播种」的竞态。
struct RenameTextField: NSViewRepresentable {
    let initialName: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> FocusingTextField {
        let field = FocusingTextField(string: initialName)
        field.delegate = context.coordinator
        field.font = .preferredFont(forTextStyle: .caption1)   // 对齐展示态 .font(.caption)
        field.controlSize = .small
        field.bezelStyle = .roundedBezel
        field.alignment = .center
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }

    func updateNSView(_ nsView: FocusingTextField, context: Context) {
        context.coordinator.parent = self   // 刷新回调引用,避免持有过期闭包
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RenameTextField
        init(_ parent: RenameTextField) { self.parent = parent }

        // Enter 提交 / Esc 取消(NSTextField 标准命令选择子)。
        // 返回 true 抑制字段编辑器默认「结束编辑」:这样提交失败(空名/非法字符,宿主不 endRename)
        // 时输入框不失焦,用户可原地修改再次 Enter——无需额外状态维持"失败保持编辑态"。
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onCommit(control.stringValue)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }

        // 失焦(点击别处 / Tab):取消重命名,清掉 renamingItemID 绑定的 auto-hide 抑制态,
        // 否则面板会卡在"抑制隐藏"永不自动收回。onCancel 幂等(endRename 已置 nil 再置无副作用),
        // 故 Enter 成功 / Esc 触发的 teardown 顺带走到这里也安全——不二次改名、不需防重入标志。
        func controlTextDidEndEditing(_ obj: Notification) {
            parent.onCancel()
        }
    }
}

/// 挂上 window 即夺焦并选中文件名主干(Finder 语义)。
/// 用 `viewDidMoveToWindow`(挂上 window 必然回调)而非单次 async hop——后者在 LazyVGrid 里
/// view 尚未挂上 window 时会永久错过聚焦(Codex review)。一次性,避免后续 layout pass 重复选区。
final class FocusingTextField: NSTextField {
    private var didApplyInitialFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didApplyInitialFocus, let window else { return }
        didApplyInitialFocus = true
        window.makeFirstResponder(self)
        currentEditor()?.selectedRange = RenameSelection.stemRange(for: stringValue)
    }
}

/// 重命名初始选区的纯逻辑(抽出以便单测,不依赖 @MainActor 视图)。
enum RenameSelection {
    /// Finder 语义:重命名默认选中文件名主干(不含最后一个扩展名)。
    /// 无扩展名 / 纯隐藏名(主干为空)→ 全选。长度用 UTF-16(`NSText.selectedRange` 的索引单位)。
    static func stemRange(for name: String) -> NSRange {
        let ns = name as NSString
        let stem = ns.deletingPathExtension as NSString
        if stem.length == 0 || stem.length == ns.length {
            return NSRange(location: 0, length: ns.length)
        }
        return NSRange(location: 0, length: stem.length)
    }
}
