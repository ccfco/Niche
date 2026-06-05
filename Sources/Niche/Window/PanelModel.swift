import SwiftUI

/// 面板内容的共享状态(ObservableObject)。
///
/// 瞬态(DNK)与常驻(PinnedPanel)两个呈现宿主绑定**同一个** PanelModel —— Pin 切换时
/// 内容状态(当前 tab、选中、排序、隐藏开关)不丢(spec §4.6:Pin 是窗口模式切换)。
/// M1 只承载单文件夹只读骨架所需字段;多 tab / 镜像在 M2 扩展。
@MainActor
final class PanelModel: ObservableObject {
    /// 当前展示的条目(M1:硬编码目录的一次性列目录;M2:由 DirectoryMirror 实时驱动)。
    @Published var items: [FileItem] = []
    /// 网格选择(键盘导航,spec §4.7)。
    @Published var selection = GridSelection(index: nil)
    /// 排序。
    @Published var sortOrder = FileSortOrder.default
    /// 显示隐藏文件(spec §4.4)。
    @Published var showHidden = false
    /// 当前窗口模式(瞬态/常驻),由 NicheController 切换。
    @Published var windowMode: WindowMode = .transient
    /// 网格列数(键盘上下移动需要;由布局回填)。
    @Published var columns = 4

    /// 经排序的可见条目(隐藏过滤已在数据源完成;这里只排序)。
    var sortedItems: [FileItem] {
        items.sorted(by: sortOrder.comparator())
    }

    /// 当前选中的条目(若有)。
    var selectedItem: FileItem? {
        guard let idx = selection.index, sortedItems.indices.contains(idx) else { return nil }
        return sortedItems[idx]
    }

    func move(_ direction: GridSelection.Direction) {
        selection = selection.moved(direction, columns: columns, count: sortedItems.count)
    }
}
