import AppKit
import SwiftUI

/// tab 栏的两个 NSMenu:「+」添加菜单与 tab 右键菜单。
///
/// 都用 NSMenu 而非 SwiftUI Menu/.contextMenu:菜单展开必须驱动 AutoHideCoordinator 的
/// .contextMenu 抑制(SwiftUI 菜单接不上 menuWillOpen/DidClose,菜单开着瞬态面板可能被
/// 收走 —— 与文件右键走 RightClickCatcher+NSMenu 同一根因)。

/// 「+」的添加菜单:同一入口承接两条添加路径 —— 选择文件夹(NSOpenPanel,鼠标党)/
/// 前往路径(路径输入条,与 ⇧⌘G 同源)。心智模型 = 书签栏 + 地址栏:添加动作发生在
/// 面板使用现场,设置页只是管理界面。
@MainActor
final class AddFolderMenuPresenter: NSObject, NSMenuDelegate {
    private let autoHide: AutoHideCoordinator
    private let onChooseFolder: () -> Void
    private let onGoToPath: () -> Void

    init(autoHide: AutoHideCoordinator,
         onChooseFolder: @escaping () -> Void,
         onGoToPath: @escaping () -> Void) {
        self.autoHide = autoHide
        self.onChooseFolder = onChooseFolder
        self.onGoToPath = onGoToPath
    }

    /// 锚定在「+」按钮下方弹出(toolbar 菜单惯例);无锚点(无障碍/键盘触发等极端情况)
    /// 回落鼠标位置。anchor 非翻转坐标系下 (0,0) 即按钮左下角 = 菜单左上角贴齐其下沿。
    func present(from anchor: NSView?) {
        let menu = makeMenu()
        if let anchor {
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: anchor.isFlipped ? anchor.bounds.maxY : 0),
                       in: anchor)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    /// 菜单构建拆出来供测试断言(popUp 是模态追踪,测试里跑不了)。
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let choose = NSMenuItem(title: "添加文件夹…", action: #selector(doChooseFolder), keyEquivalent: "")
        choose.target = self
        choose.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        menu.addItem(choose)
        // keyEquivalent 只作 ⇧⌘G 的提示展示(菜单非主菜单不参与派发,快捷键本体在面板键盘权威)。
        let go = NSMenuItem(title: "前往路径…", action: #selector(doGoToPath), keyEquivalent: "g")
        go.keyEquivalentModifierMask = [.command, .shift]
        go.target = self
        go.image = NSImage(systemSymbolName: "arrow.turn.down.right", accessibilityDescription: nil)
        menu.addItem(go)
        menu.delegate = self
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) { autoHide.begin(.contextMenu) }
    func menuDidClose(_ menu: NSMenu) { autoHide.end(.contextMenu) }

    @objc private func doChooseFolder() { onChooseFolder() }
    @objc private func doGoToPath() { onGoToPath() }
}

/// 正式 tab 的右键菜单(目前仅「移除此文件夹」)。取代 SwiftUI .contextMenu:那接不上
/// 抑制,右键菜单开着鼠标移出走廊面板会被收走(Codex review)。
@MainActor
final class TabContextMenuPresenter: NSObject, NSMenuDelegate {
    private let autoHide: AutoHideCoordinator
    private let onRemove: (FolderBinding.ID) -> Void
    /// 当前菜单作用的绑定(makeMenu 时记下,action 派发时读)。
    private var pendingID: FolderBinding.ID?

    init(autoHide: AutoHideCoordinator, onRemove: @escaping (FolderBinding.ID) -> Void) {
        self.autoHide = autoHide
        self.onRemove = onRemove
    }

    func makeMenu(for id: FolderBinding.ID) -> NSMenu {
        pendingID = id
        let menu = NSMenu()
        let remove = NSMenuItem(title: "移除此文件夹", action: #selector(doRemove), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
        menu.delegate = self
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) { autoHide.begin(.contextMenu) }
    func menuDidClose(_ menu: NSMenu) { autoHide.end(.contextMenu) }

    @objc private func doRemove() {
        if let id = pendingID { onRemove(id) }
        pendingID = nil
    }
}

/// 把宿主 NSView 暴露给 SwiftUI 按钮做菜单锚点(类引用盒,makeNSView 里赋值不触发
/// SwiftUI 状态写入)。「+」按钮 background 挂上即可拿到弹菜单的锚。
@MainActor
final class MenuAnchorBox {
    fileprivate(set) weak var view: NSView?
}

struct MenuAnchor: NSViewRepresentable {
    let box: MenuAnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        box.view = nsView
    }
}
