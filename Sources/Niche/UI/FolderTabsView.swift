import SwiftUI

/// 顶部文件夹 tab 切换(spec §4.1:绑定多个真实文件夹,顶部 tab 切换;多文件夹是核心体验)。
struct FolderTabsView: View {
    @ObservedObject var model: PanelModel
    let edge: EdgeMetrics
    /// 添加文件夹(由宿主弹 NSOpenPanel 并持久化绑定)。
    var onAddFolder: () -> Void = {}
    /// 移除当前 tab 的绑定。
    var onRemoveFolder: (FolderBinding.ID) -> Void = { _ in }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: edge.innerSpacing) {
                ForEach(Array(model.mirrors.enumerated()), id: \.element.binding.id) { index, mirror in
                    tab(index: index, title: mirror.binding.displayName)
                }
                addButton
            }
            .padding(.horizontal, edge.panelPadding)
            .padding(.vertical, edge.innerSpacing)
        }
    }

    private func tab(index: Int, title: String) -> some View {
        let isCurrent = index == model.currentTab
        // 与 +/视图切换/底栏统一玻璃语言:当前 tab 用 isActive 常驻高亮,去掉裸 accent 方块(#15)。
        return Button { model.selectTab(index) } label: {
            Text(title).lineLimit(1)
        }
        .buttonStyle(NicheFooterGlassButtonStyle(isActive: isCurrent, compact: true))
        .contextMenu {
            Button("移除此文件夹", role: .destructive) {
                onRemoveFolder(model.mirrors[index].binding.id)
            }
        }
        // 无障碍:作为可切换标签项暴露,带当前选中态(Button 已是 .isButton,补 .isSelected)。
        .accessibilityLabel(title)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private var addButton: some View {
        Button(action: onAddFolder) {
            Image(systemName: "plus")
        }
        .buttonStyle(NicheFooterGlassButtonStyle(compact: true))   // 与视图切换/底栏同一玻璃语言
        .help("添加文件夹")
        .accessibilityLabel("添加文件夹")
    }
}
