import AppKit

/// 面板向宿主(NicheController)回传的动作集合。瞬态与常驻两个呈现宿主共用,
/// 把同一组动作交给 ContentPanelView,避免逐个穿闭包。
@MainActor
struct PanelActions {
    var onOpen: (FileItem) -> Void = { _ in }
    var onTogglePin: () -> Void = {}
    var onAddFolder: () -> Void = {}
    var onRemoveFolder: (FolderBinding.ID) -> Void = { _ in }
    var onQuickLook: (_ urls: [URL], _ index: Int) -> Void = { _, _ in }

    // MARK: - M3 文件操作交互

    /// 右键:为给定条目构建自拼 NSMenu(anchor 用于分享 picker 定位);返回 nil 不弹。
    var onContextMenu: (_ urls: [URL], _ anchor: NSView) -> NSMenu? = { _, _ in nil }
    /// 空白处右键:背景菜单(新建文件夹 / 粘贴);返回 nil 不弹。
    var onContextMenuBackground: (_ anchor: NSView) -> NSMenu? = { _ in nil }
    /// 拖入落地:Niche 自己执行 copy/move(读修饰键 + 卷判定,spec §4.5 注②)。
    var onDropURLs: (_ urls: [URL], _ modifiers: NSEvent.ModifierFlags) -> Void = { _, _ in }
    /// 就地重命名提交;返回是否成功(失败 → cell 保持编辑态)。
    var onRename: (_ url: URL, _ newName: String) -> Bool = { _, _ in false }
    /// 键盘快捷键文件操作。
    var onCopy: (_ urls: [URL]) -> Void = { _ in }
    var onCut: (_ urls: [URL]) -> Void = { _ in }
    var onCopyPath: (_ urls: [URL]) -> Void = { _ in }
    var onTrash: (_ urls: [URL]) -> Void = { _ in }
    var onPaste: () -> Void = {}
    var onUndo: () -> Void = {}
    /// ⌘W / Esc 收回(未 pin)。
    var onClose: () -> Void = {}
    /// 拖出(面板作 drag 源)起止 → 宿主抑制/解除 auto-hide(拖出全程不消失 + 拖出即走)。
    var onDragBegin: () -> Void = {}
    var onDragEnd: () -> Void = {}
}
