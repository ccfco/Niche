import SwiftUI

/// 面板内容根视图:顶部文件夹 tab + 网格(或空态)+ 底栏。
///
/// 键盘导航(spec §4.7)在此统一处理:↑↓←→ 选择 / Space Quick Look / Return 打开 /
/// ⌘↓ 进子目录 / ⌘↑ 回上级。竞品几乎纯鼠标,这是差异化优势。
struct ContentPanelView: View {
    @ObservedObject var model: PanelModel
    private let edge = EdgeMetrics.standard
    @FocusState private var focused: Bool

    /// 宿主注入的动作集合(解耦 UI 与 AppKit 控制器)。
    var actions = PanelActions()

    var body: some View {
        VStack(spacing: 0) {
            FolderTabsView(model: model, edge: edge,
                           onAddFolder: actions.onAddFolder, onRemoveFolder: actions.onRemoveFolder)
            Divider()
            content
            Divider()
            BottomBarView(model: model, edge: edge, onTogglePin: actions.onTogglePin)
        }
        .frame(minWidth: 360, minHeight: 240)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(phases: .down) { press in handleKey(press) }
    }

    @ViewBuilder private var content: some View {
        switch model.currentState {
        case .idle, .loading:
            EmptyStateView(kind: .loading)
        case .permissionDenied:
            EmptyStateView(kind: .permissionDenied, onAuthorize: { model.currentMirror?.reauthorize() })
        case let .volumeUnmounted(name):
            EmptyStateView(kind: .volumeUnmounted(name))
                .onTapGesture { model.currentMirror?.retryIfPossible() }
        case .ready:
            FileGridView(model: model, edge: edge, onOpen: actions.onOpen)
        }
    }

    // MARK: - 键盘导航

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let cmd = press.modifiers.contains(.command)
        switch press.key {
        case .upArrow where cmd:
            model.currentMirror?.goUp()
            model.selection = GridSelection(index: nil)
            return .handled
        case .downArrow where cmd:
            if let item = model.selectedItem, item.isDirectory {
                model.currentMirror?.enter(item.url)
                model.selection = GridSelection(index: nil)
            }
            return .handled
        case .upArrow: model.move(.up); return .handled
        case .downArrow: model.move(.down); return .handled
        case .leftArrow: model.move(.left); return .handled
        case .rightArrow: model.move(.right); return .handled
        case .space:
            // Space → Quick Look 当前选中(spec §4.7);传整组以支持预览内翻页。
            if let idx = model.selection.index {
                actions.onQuickLook(model.sortedItems.map(\.url), idx)
            }
            return .handled
        case .return:
            if let item = model.selectedItem {
                if item.isDirectory { model.currentMirror?.enter(item.url); model.selection = GridSelection(index: nil) }
                else { actions.onOpen(item) }
            }
            return .handled
        default:
            return .ignored
        }
    }
}
