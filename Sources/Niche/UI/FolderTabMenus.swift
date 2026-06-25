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

/// 「路径脊柱」右键菜单:tab(根段)与面包屑(子级段)是同一条路径脊柱,共用一套"文件夹引用
/// 操作"(复制路径 / 在 Finder 中显示 / 显示简介);tab 段额外多两项书签身份操作(重命名标签 /
/// 移除此文件夹)。书签 ≠ 文件夹:刻意不含会真改磁盘的项(废纸篓/移动/压缩/分享),对齐 Finder
/// 边栏收藏项的克制(导航+身份+查看)。
///
/// 用 NSMenu 而非 SwiftUI .contextMenu:菜单展开必须驱动 AutoHideCoordinator 的 .contextMenu
/// 抑制,否则菜单开着鼠标移出走廊瞬态面板会被收走(与文件右键同一根因)。
@MainActor
final class PathContextMenu: NSObject, NSMenuDelegate {
    private let autoHide: AutoHideCoordinator
    private let onCopyPath: ([URL]) -> Void
    private let onReveal: ([URL]) -> Void
    private let onShowInfo: ([URL]) -> Void
    private let onRenameTab: (FolderBinding.ID) -> Void
    private let onRemove: (FolderBinding.ID) -> Void
    /// 当前菜单作用的目标(makeMenu 时记下,action 派发时读)。tab 段两者皆有;面包屑段仅 url。
    private var pendingURL: URL?
    private var pendingID: FolderBinding.ID?

    init(autoHide: AutoHideCoordinator,
         onCopyPath: @escaping ([URL]) -> Void,
         onReveal: @escaping ([URL]) -> Void,
         onShowInfo: @escaping ([URL]) -> Void,
         onRenameTab: @escaping (FolderBinding.ID) -> Void,
         onRemove: @escaping (FolderBinding.ID) -> Void) {
        self.autoHide = autoHide
        self.onCopyPath = onCopyPath
        self.onReveal = onReveal
        self.onShowInfo = onShowInfo
        self.onRenameTab = onRenameTab
        self.onRemove = onRemove
    }

    /// tab(根段)菜单:文件夹引用操作 + 书签身份操作。
    func makeTabMenu(id: FolderBinding.ID, url: URL) -> NSMenu {
        pendingURL = url
        pendingID = id
        let menu = NSMenu()
        appendFolderRefItems(menu)
        menu.addItem(.separator())
        add(menu, "重命名标签…", #selector(doRenameTab), symbol: "pencil")
        add(menu, "移除此文件夹", #selector(doRemove), symbol: "minus.circle")
        menu.delegate = self
        return menu
    }

    /// 面包屑(子级段)菜单:仅文件夹引用操作(无书签身份操作 —— 它不是书签)。
    func makeSegmentMenu(url: URL) -> NSMenu {
        pendingURL = url
        pendingID = nil
        let menu = NSMenu()
        appendFolderRefItems(menu)
        menu.delegate = self
        return menu
    }

    /// 脊柱任意段共用的三项文件夹引用操作。
    private func appendFolderRefItems(_ menu: NSMenu) {
        add(menu, "在 Finder 中显示", #selector(doReveal), symbol: "folder")
        add(menu, "复制路径", #selector(doCopyPath), symbol: "doc.on.clipboard")
        add(menu, "显示简介", #selector(doShowInfo), symbol: "info.circle")
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, symbol: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menu.addItem(item)
    }

    func menuWillOpen(_ menu: NSMenu) { autoHide.begin(.contextMenu) }
    func menuDidClose(_ menu: NSMenu) { autoHide.end(.contextMenu) }

    @objc private func doCopyPath() { if let url = pendingURL { onCopyPath([url]) } }
    @objc private func doReveal() { if let url = pendingURL { onReveal([url]) } }
    @objc private func doShowInfo() { if let url = pendingURL { onShowInfo([url]) } }
    @objc private func doRenameTab() { if let id = pendingID { onRenameTab(id) } }
    @objc private func doRemove() { if let id = pendingID { onRemove(id) } }
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
