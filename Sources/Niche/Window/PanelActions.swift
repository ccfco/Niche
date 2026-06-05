import Foundation

/// 面板向宿主(NicheController)回传的动作集合。瞬态与常驻两个呈现宿主共用,
/// 把同一组动作交给 ContentPanelView,避免逐个穿闭包。
@MainActor
struct PanelActions {
    var onOpen: (FileItem) -> Void = { _ in }
    var onTogglePin: () -> Void = {}
    var onAddFolder: () -> Void = {}
    var onRemoveFolder: (FolderBinding.ID) -> Void = { _ in }
    var onQuickLook: (_ urls: [URL], _ index: Int) -> Void = { _, _ in }
}
