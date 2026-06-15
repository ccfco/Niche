import AppKit

/// 底栏排序菜单(NSMenu)。仿访达排序子菜单:排序键(名称 / 修改日期 / 大小 / 类型)+
/// 方向(升 / 降)+「文件夹保持在最前」开关,各项带勾选态。
///
/// 用 NSMenu 而非 SwiftUI Menu:菜单展开必须驱动 AutoHideCoordinator 的 .contextMenu 抑制
/// —— SwiftUI Menu 的 menu window 会抢走 key 焦点,使瞬态面板 didResignKey 即被收走(鼠标
/// 移到排序按钮上面板就消失的根因,与 tab「+」/ 右键菜单同一根因,见 FolderTabMenus.swift)。
///
/// 每次打开按当前 sortOrder 重建,点选即写回 model.sortOrder(@Published didSet 自动重排 +
/// 持久化);菜单项用 representedObject 直挂枚举值,免 tag 簿记。
@MainActor
final class SortMenuPresenter: NSObject, NSMenuDelegate {
    private let autoHide: AutoHideCoordinator
    private let model: PanelModel

    init(autoHide: AutoHideCoordinator, model: PanelModel) {
        self.autoHide = autoHide
        self.model = model
    }

    /// 锚定在排序按钮下方弹出(toolbar 菜单惯例);无锚点(无障碍 / 键盘触发等)回落鼠标位置。
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

    /// 菜单构建拆出供测试断言(popUp 是模态追踪,测试里跑不了)。
    func makeMenu() -> NSMenu {
        let order = model.sortOrder
        let menu = NSMenu()
        for key in FileSortOrder.Key.allCases {
            menu.addItem(checkable(Self.keyTitle(key),
                                   on: order.key == key,
                                   action: #selector(selectKey(_:)),
                                   represents: key))
        }
        menu.addItem(.separator())
        for direction in [FileSortOrder.Direction.ascending, .descending] {
            menu.addItem(checkable(Self.directionTitle(direction),
                                   on: order.direction == direction,
                                   action: #selector(selectDirection(_:)),
                                   represents: direction))
        }
        menu.addItem(.separator())
        // 默认混排(directoriesFirst=false,与访达一致);开则全部排序键下目录聚于最前。
        menu.addItem(checkable("文件夹保持在最前",
                               on: order.directoriesFirst,
                               action: #selector(toggleDirectoriesFirst),
                               represents: nil))
        menu.delegate = self
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) { autoHide.begin(.contextMenu) }
    func menuDidClose(_ menu: NSMenu) { autoHide.end(.contextMenu) }

    private func checkable(_ title: String, on: Bool, action: Selector, represents: Any?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        item.representedObject = represents
        return item
    }

    @objc private func selectKey(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? FileSortOrder.Key else { return }
        model.sortOrder.key = key
    }

    @objc private func selectDirection(_ sender: NSMenuItem) {
        guard let direction = sender.representedObject as? FileSortOrder.Direction else { return }
        model.sortOrder.direction = direction
    }

    @objc private func toggleDirectoriesFirst() {
        model.sortOrder.directoriesFirst.toggle()
    }

    private static func keyTitle(_ key: FileSortOrder.Key) -> String {
        switch key {
        case .name: return "名称"
        case .date: return "修改日期"
        case .size: return "大小"
        case .kind: return "类型"
        }
    }

    private static func directionTitle(_ direction: FileSortOrder.Direction) -> String {
        switch direction {
        case .ascending: return "升序"
        case .descending: return "降序"
        }
    }
}
