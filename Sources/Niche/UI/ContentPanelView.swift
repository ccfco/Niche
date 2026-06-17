import SwiftUI

/// 面板内容根视图:顶部文件夹 tab + 网格(或空态)+ 底栏。
///
/// 键盘导航(spec §4.7)在此统一处理:↑↓←→ 选择 / Space Quick Look / Return 打开 /
/// ⌘↓ 进子目录 / ⌘↑ 回上级。竞品几乎纯鼠标,这是差异化优势。
struct ContentPanelView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var motion: MotionPreferences
    private let edge = EdgeMetrics.standard

    /// 宿主注入的动作集合(解耦 UI 与 AppKit 控制器)。
    var actions = PanelActions()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: edge.itemSpacing) {
                FolderTabsView(model: model, edge: edge,
                               onAddMenu: actions.onAddMenu, onTabMenu: actions.onTabMenu,
                               onPinTemporary: actions.onPinTemporary)
                viewSwitcher
                    .fixedSize()
                    .padding(.trailing, edge.panelPadding)
            }
            // 路径输入条(前往):⌘⇧G / 键入 `/`、`~` 弹出,位于 tab 与面包屑之间。
            if model.pathInputVisible {
                PathInputBar(model: model, edge: edge, onGoToPath: actions.onGoToPath)
            }
            breadcrumb
            content
            BottomBarView(model: model, edge: edge,
                          onSortMenu: actions.onSortMenu, onTogglePin: actions.onTogglePin)
        }
        .frame(minWidth: 360, minHeight: 240)
        .panelBackground()
        .clipShape(RoundedRectangle(cornerRadius: edge.panelCornerRadius, style: .continuous))
        .environmentObject(motion)
        // Reduce Motion:交错/展开动画降级为淡入(spec §4.3)。
        .animation(motion.reduceMotion ? .none : .smooth, value: model.currentTab)
        // 键盘导航统一由 PanelController 的 keyDown monitor 处理(面板键盘权威),
        // 不再用面板级 .onKeyPress —— 那会与 Table 抢焦点产生二义性(#1/#2/#22)。
    }

    /// 下钻路径栏:仅在 canGoUp(已下钻)显示;纯鼠标据此逐级回跳(#7/#8)。
    @ViewBuilder private var breadcrumb: some View {
        if let mirror = model.currentMirror, mirror.canGoUp {
            BreadcrumbBar(
                components: mirror.breadcrumb,
                edge: edge,
                onUp: { model.currentMirror?.goUp(); model.clearSelection() },
                onSelect: { url in model.currentMirror?.enter(url); model.clearSelection() }
            )
        }
    }

    @ViewBuilder private var content: some View {
        // 首次运行/未绑定任何文件夹:引导添加,而非误显"载入中"。
        if model.mirrors.isEmpty {
            EmptyStateView(kind: .noFolders, onAuthorize: actions.onAddFolder)
        } else {
            mirrorContent
        }
    }

    @ViewBuilder private var mirrorContent: some View {
        switch model.currentState {
        case .idle, .loading:
            EmptyStateView(kind: .loading)
        case .permissionDenied:
            EmptyStateView(kind: .permissionDenied(model.currentMirror?.binding.displayName ?? "此文件夹"),
                           onAuthorize: { model.currentMirror?.reauthorize() })
        case let .volumeUnmounted(name):
            // 明确「重试」按钮(复用 button 槽),不靠隐形整区可点(#12)。
            EmptyStateView(kind: .volumeUnmounted(name),
                           onAuthorize: { model.currentMirror?.retryIfPossible() })
        case .missing:
            // 目录被删/移走 ≠ 权限被拒:误报 denied 会引导用户白授权(体检审计)。
            // 从废纸篓恢复后点「重试」即可;不再要可右键 tab 移除绑定。
            EmptyStateView(kind: .missing(model.currentMirror?.binding.displayName ?? "此文件夹"),
                           onAuthorize: { model.currentMirror?.retryIfPossible() })
        case .ready:
            switch model.viewMode {
            case .list: FileListView(model: model, edge: edge, actions: actions)
            case .icon: FileGridView(model: model, edge: edge, actions: actions)
            }
        }
    }

    /// 视图切换 = 一块分段玻璃胶囊(列表/图标),仿 Finder 工具栏视图组:互斥单选挤一个胶囊,
    /// 选中段浮高亮(不靠刺眼的蓝色原生 segmented)。玻璃/高亮语言与底栏按钮同源。
    private var viewSwitcher: some View {
        NicheSegmentedGlass(
            selection: Binding(get: { model.viewMode }, set: { model.viewMode = $0 }),
            segments: [
                .init(value: .list, systemImage: "list.bullet", help: "列表视图", label: "列表视图"),
                .init(value: .icon, systemImage: "square.grid.2x2", help: "图标视图", label: "图标视图"),
            ]
        )
    }

}
