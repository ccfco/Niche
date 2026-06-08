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
                               onAddFolder: actions.onAddFolder, onRemoveFolder: actions.onRemoveFolder)
                viewSwitcher
                    .fixedSize()
                    .padding(.trailing, edge.panelPadding)
            }
            breadcrumb
            content
            BottomBarView(model: model, edge: edge, onTogglePin: actions.onTogglePin)
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
        case .ready:
            switch model.viewMode {
            case .list: FileListView(model: model, edge: edge, actions: actions)
            case .icon: FileGridView(model: model, edge: edge, actions: actions)
            }
        }
    }

    /// 视图切换 = 两颗玻璃切换按钮(列表/图标),与底栏按钮同一玻璃语言(取代刺眼的蓝色原生 segmented)。
    /// 当前模式按钮常驻高亮(isActive),不靠蓝色填充。
    private var viewSwitcher: some View {
        HStack(spacing: edge.innerSpacing) {
            Button { model.viewMode = .list } label: { Image(systemName: "list.bullet") }
                .buttonStyle(NicheFooterGlassButtonStyle(isActive: model.viewMode == .list, compact: true))
                .accessibilityLabel("列表视图")
            Button { model.viewMode = .icon } label: { Image(systemName: "square.grid.2x2") }
                .buttonStyle(NicheFooterGlassButtonStyle(isActive: model.viewMode == .icon, compact: true))
                .accessibilityLabel("图标视图")
        }
    }

}
