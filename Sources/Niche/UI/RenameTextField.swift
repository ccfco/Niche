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
    /// Enter:提交(失败由宿主保持编辑态,不 endRename)。
    let onCommit: (String) -> Void
    /// Esc:主动取消,还原原名。
    let onCancel: () -> Void
    /// 失焦(点面板内别处 / 窗口失活):Finder 语义 = 提交当前(无效名则还原),总是结束重命名。
    /// 宿主据 `renamingItemID == 本项` 守卫:Enter 成功 / Esc / Tab 跳走后旧框拆除触发的此回调
    /// 会因守卫失败而 no-op,只有真·失焦(仍在重命名本项)才提交。
    var onEndEditing: (String) -> Void = { _ in }
    /// Tab / ⇧Tab:提交当前并重命名相邻项(Finder 语义)。offset +1 = 下一项,-1 = 上一项。
    var onTab: (String, Int) -> Void = { _, _ in }
    /// 图标模式:多行换行撑开显示完整文件名(Finder 图标视图重命名同款);列表模式保持单行截断。
    var multiline: Bool = false
    /// 多行态圆角(borderless 自绘):由宿主传入与格子同心的半径。
    var cornerRadius: CGFloat = 6

    func makeNSView(context: Context) -> FocusingTextField {
        let field = FocusingTextField(string: initialName)
        field.delegate = context.coordinator
        field.font = .preferredFont(forTextStyle: .caption1)   // 对齐展示态 .font(.caption)
        field.controlSize = .small
        field.alignment = .center
        if multiline {
            // 图标模式:多行换行撑开显示完整文件名(不是单行截断)。系统圆角 bezel 仅支持单行,
            // 故改 borderless + 圆角图层 + 细边自绘;高度由 sizeThatFits 按换行宽算 cellSize 撑开。
            field.isBezeled = false
            field.isBordered = false
            field.usesSingleLineMode = false
            field.lineBreakMode = .byCharWrapping        // 文件名按字符换行(可断在任意位置,同 Finder)
            field.maximumNumberOfLines = 0
            field.cell?.wraps = true
            field.cell?.isScrollable = false
            field.drawsBackground = true
            field.backgroundColor = .textBackgroundColor
            field.focusRingType = .none
            field.wantsLayer = true
            field.layer?.cornerRadius = cornerRadius
            field.layer?.masksToBounds = true            // 文字底是方形,靠图层裁成圆角
            field.layer?.borderWidth = 1
            field.layer?.borderColor = NSColor.separatorColor.cgColor
        } else {
            field.bezelStyle = .roundedBezel
            field.usesSingleLineMode = true
            field.lineBreakMode = .byTruncatingMiddle
        }
        return field
    }

    func updateNSView(_ nsView: FocusingTextField, context: Context) {
        context.coordinator.parent = self   // 刷新回调引用,避免持有过期闭包
    }

    /// 多行态:按 SwiftUI 给的宽度算换行后高度,撑开输入框(否则 representable 默认按单行高布局,
    /// 长名仍挤成一行)。单行态返回 nil 用系统默认尺寸。输入变化时 controlTextDidChange 触发重测。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FocusingTextField, context: Context) -> CGSize? {
        guard multiline, let width = proposal.width, width.isFinite, width > 0 else { return nil }
        nsView.preferredMaxLayoutWidth = width
        let full = nsView.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width,
                                                           height: .greatestFiniteMagnitude)).height
            ?? nsView.intrinsicContentSize.height
        // 限高(约 5 行 + 内边距):超长名不无限撑高、不挤压网格,超出部分在框内裁切/滚动(同 Finder)。
        let lineHeight = nsView.font?.boundingRectForFont.height ?? 14
        let maxHeight = ceil(lineHeight * 5) + 8
        return CGSize(width: width, height: min(ceil(full), maxHeight))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RenameTextField
        init(_ parent: RenameTextField) { self.parent = parent }

        // Enter 提交 / Esc 取消(NSTextField 标准命令选择子)。
        // 返回 true 抑制字段编辑器默认「结束编辑」:这样提交失败(空名/非法字符,宿主不 endRename)
        // 时输入框不失焦,用户可原地修改再次 Enter——无需额外状态维持"失败保持编辑态"。
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // 提交值读 field editor 实时内容 `textView.string`,而非 `control.stringValue`:这些路径
            // 都 return true 抑制默认结束编辑,AppKit 不会把 field editor 同步回 control,中文输入法
            // 候选词未上屏时 stringValue 会是旧值(失焦路径已同步,仍可用 stringValue)。
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onCommit(textView.string)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            case #selector(NSResponder.insertTab(_:)):
                parent.onTab(textView.string, +1)   // 提交并跳下一项(宿主在提交前按当前序定位邻项)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                parent.onTab(textView.string, -1)   // ⇧Tab:提交并跳上一项
                return true
            default:
                return false
            }
        }

        // 失焦(点面板内别处 / 窗口失活):Finder 语义 = 提交(无效名还原),总是结束。交宿主
        // onEndEditing,内部据 `renamingItemID == 本项` 守卫 —— Enter 成功 / Esc / Tab 跳走后的
        // teardown 也会走到这里,但那时 renamingItemID 已移走,守卫失败 → no-op,不二次提交。
        func controlTextDidEndEditing(_ obj: Notification) {
            parent.onEndEditing((obj.object as? NSControl)?.stringValue ?? parent.initialName)
        }

        // 多行态边打字边换行 → 失效内在尺寸,促 SwiftUI 重跑 sizeThatFits 把框撑高(单行态无副作用)。
        func controlTextDidChange(_ obj: Notification) {
            (obj.object as? NSView)?.invalidateIntrinsicContentSize()
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
        guard let window, !didApplyInitialFocus else { return }
        didApplyInitialFocus = true
        focusAndSelectStem(in: window)
        // 兜底(#2):Tab 跳邻项时,旧框拆除(resign first responder)与本框夺焦发生在同一次
        // SwiftUI 更新里,顺序不定 —— 旧框后拆会把本框刚夺到的焦点清空,导致光标不进新改名框。
        // 下一拍若本框仍挂在窗口、且当前没有任何输入框持有焦点,则补夺一次(不抢另一个已激活
        // 输入框:firstResponder 已是 NSText 即跳过)。
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window,
                  !(window.firstResponder is NSText) else { return }
            self.focusAndSelectStem(in: window)
        }
    }

    private func focusAndSelectStem(in window: NSWindow) {
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
