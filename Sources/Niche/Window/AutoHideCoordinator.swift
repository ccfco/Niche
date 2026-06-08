import AppKit

/// 瞬态面板"失焦即隐"的抑制模型(spec §4.6 关键不变量:自动隐藏不能绑定 resignKey)。
///
/// 直接把 auto-hide 绑到 `resignKey` 会与 Quick Look / 自拼右键菜单 / 拖拽 / 就地重命名冲突
/// (尤其 QLPreviewPanel 是独立窗口,becomeKey 会让面板 resignKey → 面板会在预览浮空时收回)。
/// 因此引入显式抑制集合:任一抑制源活跃时暂停 auto-hide;且失焦判定要排除"焦点转移到自己
/// 派生的辅助窗口"(QLPreviewPanel、菜单、重命名 popup)。本类是纯状态逻辑,可单测。
@MainActor
final class AutoHideCoordinator {
    enum Suppressor: Hashable {
        case quickLook    // Quick Look 活跃
        case contextMenu  // 自拼右键菜单展开中(menuWillOpen/menuDidClose 驱动)
        case dragging     // 拖入(面板是 drop 目标)进行中
        case draggingOut  // 拖出(面板是 drag 源)进行中
        case renaming     // 就地重命名编辑中
    }

    private var active: Set<Suppressor> = []

    /// 判定可隐藏后触发(由持有者执行真正的收回动画)。
    var onShouldHide: (() -> Void)?

    var isSuppressed: Bool { !active.isEmpty }

    func begin(_ suppressor: Suppressor) {
        active.insert(suppressor)
    }

    /// 结束某抑制源;若全部结束,重新评估是否该隐藏(失焦期间被抑制、抑制解除后补隐)。
    func end(_ suppressor: Suppressor) {
        active.remove(suppressor)
        if active.isEmpty, pendingHide {
            pendingHide = false
            onShouldHide?()
        }
    }

    /// 失焦发生时被抑制,记一笔"待隐藏",等抑制解除再补。
    private var pendingHide = false

    /// 面板自有窗口集合(瞬态面板 + 其派生辅助窗口)。失焦判定用它排除"焦点只是转移到
    /// 自己派生的辅助窗口"的情况。
    var ownedWindows: () -> [NSWindow] = { [] }

    /// 收到 resignKey:若新 key window 仍属于自己(辅助窗口),或正被抑制,则不隐藏。
    /// 只有焦点真正离开 app 自有窗口集合且无抑制时才收回。
    func handleResignKey(newKeyWindow: NSWindow?) {
        // 焦点转移到自己派生的辅助窗口(QL/菜单/重命名 popup):不隐藏。
        if let newKeyWindow, ownedWindows().contains(where: { $0 === newKeyWindow }) {
            return
        }
        // QLPreviewPanel 等可能尚未进入 ownedWindows,但抑制集合已标记 → 延后。
        if isSuppressed {
            pendingHide = true
            return
        }
        onShouldHide?()
    }
}
