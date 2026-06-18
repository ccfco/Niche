import AppKit

/// 面板向宿主(NicheController)回传的动作集合。瞬态与常驻两个呈现宿主共用,
/// 把同一组动作交给 ContentPanelView,避免逐个穿闭包。
@MainActor
struct PanelActions {
    var onOpen: (FileItem) -> Void = { _ in }
    var onTogglePin: () -> Void = {}
    var onAddFolder: () -> Void = {}
    /// tab 栏「+」:弹添加菜单(选择文件夹 / 前往路径),非直开 NSOpenPanel;锚定按钮下方。
    var onAddMenu: (_ anchor: NSView?) -> Void = { _ in }
    /// tab 右键:构建带抑制的 NSMenu(移除此文件夹);nil 不弹。
    var onTabMenu: (_ id: FolderBinding.ID) -> NSMenu? = { _ in nil }
    /// 底栏排序按钮:弹排序菜单(NSMenu+抑制,锚定按钮下方);不用 SwiftUI Menu(会抢焦点收面板)。
    var onSortMenu: (_ anchor: NSView?) -> Void = { _ in }
    var onRemoveFolder: (FolderBinding.ID) -> Void = { _ in }
    var onQuickLook: (_ urls: [URL], _ index: Int) -> Void = { _, _ in }
    /// Quick Look 当前是否由本 app 驱动且可见(键盘单一权威据此接管预览态:空格 toggle / Esc 关)。
    var isQuickLookActive: () -> Bool = { false }
    /// 主动关闭 Quick Look 预览(空格 toggle / Esc 关预览,而非误关整个面板)。
    var onQuickLookClose: () -> Void = {}
    /// QL 活跃时方向键移光标后**同步**把当前光标推给 QL(不绕 Combine 异步)。QL 是 key window 时
    /// `.receive(on: RunLoop.main)` 的延迟块会滞后到下次按键 → 预览落后一格;同步推送当场翻页。
    var onQuickLookSyncCursor: () -> Void = {}

    // MARK: - M3 文件操作交互

    /// 右键:为给定条目构建自拼 NSMenu(anchor 用于分享 picker 定位);返回 nil 不弹。
    var onContextMenu: (_ urls: [URL], _ anchor: NSView) -> NSMenu? = { _, _ in nil }
    /// 空白处右键:背景菜单(新建文件夹 / 粘贴);返回 nil 不弹。
    var onContextMenuBackground: (_ anchor: NSView) -> NSMenu? = { _ in nil }
    /// 拖入落地:Niche 自己执行 copy/move(读修饰键 + 卷判定,spec §4.5 注②)。
    /// destination 显式落点(拖到目录格子/行上 = 落进该文件夹);nil = 当前目录。
    var onDropURLs: (_ urls: [URL], _ modifiers: NSEvent.ModifierFlags, _ destination: URL?) -> Void = { _, _, _ in }
    /// 就地重命名提交;返回是否成功(失败 → cell 保持编辑态)。
    var onRename: (_ url: URL, _ newName: String) -> Bool = { _, _ in false }
    /// 键盘快捷键文件操作。
    var onCopy: (_ urls: [URL]) -> Void = { _ in }
    var onCut: (_ urls: [URL]) -> Void = { _ in }
    var onCopyPath: (_ urls: [URL]) -> Void = { _ in }
    var onTrash: (_ urls: [URL]) -> Void = { _ in }
    var onPaste: () -> Void = {}
    var onUndo: () -> Void = {}
    /// ⇧⌘Z 重做最近一次撤销。
    var onRedo: () -> Void = {}
    /// ⌘⇧N 在当前目录新建文件夹并进入就地重命名(与背景右键菜单同一落点)。
    var onNewFolder: () -> Void = {}
    /// ⌘W / Esc 收回(未 pin)。
    var onClose: () -> Void = {}
    /// ⌘, 打开设置窗口(面板是 nonactivating panel,app 常处于非激活态,主菜单 key equivalent
    /// 不可靠 —— 由面板键盘权威显式接管)。
    var onOpenSettings: () -> Void = {}
    /// 路径输入条提交「前往」。返回 false = 路径不存在/非法(条上显错,不关条)。
    var onGoToPath: (String) -> Bool = { _ in false }
    /// 把临时 tab 钉成正式绑定(bookmark + 入 BindingStore,临时槽让位)。
    var onPinTemporary: () -> Void = {}
    /// 拖动重排正式 tab:from = 原索引,to = `Array.move(toOffset:)` 语义落点。宿主走 BindingStore.move 持久化。
    var onMoveTab: (_ from: Int, _ to: Int) -> Void = { _, _ in }
    /// 拖文件夹进 tab 栏 → 固定为常驻绑定(只接文件夹,宿主去重已绑定路径;内容区子文件夹 / 外部 Finder 同路)。
    /// index = 插入光标算出的落点(正式 tab 序);nil = 几何未就绪,末尾追加兜底。
    var onDropFolders: (_ urls: [URL], _ index: Int?) -> Void = { _, _ in }
    /// 拖出(面板作 drag 源)起止 → 宿主抑制/解除 auto-hide(拖出全程不消失 + 拖出即走)。
    var onDragBegin: () -> Void = {}
    var onDragEnd: () -> Void = {}
    /// 底栏图标缩放滑块拖动起止(true=开始/false=松手)→ 宿主抑制/解除 auto-hide,防拖动时鼠标
    /// 甩出面板边界致收回、中断拖动(同拖出语义)。
    var onIconSizeEditing: (Bool) -> Void = { _ in }
}
