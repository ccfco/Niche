import AppKit

/// 窗口模式(spec §4.6 关键设计:Pin 是两种窗口模式的切换,不是布尔开关)。
///
/// 从第一行代码就把"窗口模式"做成可切换状态机,不能先写死 launcher 再改。两种模式的
/// 窗口层级 / collectionBehavior / 焦点策略完全不同 —— 由本枚举集中派生,PanelController
/// 按这些属性配置 NSPanel。
enum WindowMode: Equatable {
    /// 瞬态:借刘海的用完即走面板。nonactivating、失焦即隐、不进 Mission Control。
    case transient
    /// 常驻:普通可激活、可拖动、always-on-top 浮窗(detach 后可放任意位置)。
    case pinned

    /// 窗口层级。瞬态用 statusBar 之上保证压住菜单栏区;常驻用 floating 置顶。
    var level: NSWindow.Level {
        switch self {
        case .transient: return .statusBar
        case .pinned: return .floating
        }
    }

    /// collectionBehavior。瞬态跨所有 Space 且不进 Mission Control / 窗口循环;
    /// 常驻可被 Mission Control 管理、跟随当前 Space。
    var collectionBehavior: NSWindow.CollectionBehavior {
        switch self {
        case .transient:
            return [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        case .pinned:
            return [.managed, .fullScreenAuxiliary]
        }
    }

    /// 失焦是否自动隐藏(瞬态是,常驻否)。注意:真正的 auto-hide 还要过 AutoHideCoordinator
    /// 的抑制集合(Quick Look / 菜单 / 拖拽 / 重命名),不能简单绑 resignKey。
    var hidesOnResignKey: Bool {
        self == .transient
    }

    /// 是否可成为 key window。两种模式都要 true —— 瞬态也需承载键盘导航与就地重命名
    /// 文本编辑(spec §4.6:nonactivating 面板需 canBecomeKey=true)。
    var canBecomeKey: Bool { true }

    /// 是否可成为 main window。瞬态 nonactivating 不抢主窗口;常驻可以。
    var canBecomeMain: Bool {
        self == .pinned
    }

    /// 切换到"另一个"模式(Pin/Unpin)。
    var toggled: WindowMode {
        self == .transient ? .pinned : .transient
    }
}
