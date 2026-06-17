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
        case pathInput    // 路径输入条(前往)展开中:输入路径常要对照别处,鼠标离开不该把面板抽走
        case modalDialog  // 模态对话框(NSOpenPanel/NSAlert)展示中:对话框成 key + 鼠标移去
                          // 点按都会触发收回,不抑制则"添加文件夹/移动到…/冲突确认"期间面板被挤走
    }

    /// 抑制源 → 嵌套计数(非 Set):同名抑制可重入(如集中式 withModalContext 嵌套 presentFailure),
    /// begin/end 必须平衡配对——用 Set 时内层 end 会把外层仍需的抑制源整个抹掉,造成模态期间面板被收回。
    private var active: [Suppressor: Int] = [:]

    /// 判定可隐藏后触发(由持有者执行真正的收回动画)。
    var onShouldHide: (() -> Void)?

    /// 抑制解除补隐时调:重新评估鼠标当前位置,而非盲目兑现抑制期间记下的 pendingHide。
    /// QL 盖住面板时鼠标移到 QL 上会记一笔 pendingHide,关 QL 后若鼠标已回面板走廊内则不该收。
    /// 注入缺省(nil)时 fallback onShouldHide,保持本类纯状态逻辑、不强依赖几何、可单测。
    var onReevaluate: (() -> Void)?

    var isSuppressed: Bool { !active.isEmpty }

    func begin(_ suppressor: Suppressor) {
        active[suppressor, default: 0] += 1
    }

    /// 结束某抑制源;若全部结束且有待隐藏,**推迟一拍再重新评估**(而非盲目兑现)。
    /// 推迟是必须的:NSMenu 的 menuDidClose 先于菜单项 action 派发,同步兑现会插进
    /// "解除 .contextMenu"与"action 建立下一个抑制(.modalDialog/.pathInput)"的空隙,
    /// 面板在 NSOpenPanel/路径条出现前就开始收回(Codex review)。
    /// pendingHide 留到兑现时刻才消费:① 兑现时已有新抑制接棒 → 原样保留等它解除再评;
    /// ② 空隙里 handleMouseLeave/ResignKey 直接收回会消费它,排队的块自然失效,不双发
    /// onShouldHide;③ 多次 end 排队多个块,首个消费后其余 guard 短路。
    func end(_ suppressor: Suppressor) {
        guard let count = active[suppressor] else { return }   // 未配对的 end:忽略(不下溢)
        if count <= 1 { active[suppressor] = nil } else { active[suppressor] = count - 1 }
        guard active.isEmpty, pendingHide else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingHide, self.active.isEmpty else { return }
            self.pendingHide = false
            (self.onReevaluate ?? self.onShouldHide)?()
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
        pendingHide = false   // 立即收回即消费待隐,end() 排队的兑现块据此短路(防双发)
        onShouldHide?()
    }

    /// 收到"瞬态面板鼠标离开":有抑制源(Quick Look / 菜单 / 拖拽 / 重命名)则记待隐藏,
    /// 待抑制解除再补;否则立即收回。与 resignKey 同走抑制判定,是"移开即收"的主路径。
    func handleMouseLeave() {
        if isSuppressed {
            pendingHide = true
            return
        }
        pendingHide = false   // 同 handleResignKey:消费待隐,防 end() 兑现块双发
        onShouldHide?()
    }
}
