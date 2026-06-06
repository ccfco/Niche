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
        return Text(title)
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, edge.itemSpacing)
            .padding(.vertical, edge.innerSpacing)
            .background(
                RoundedRectangle(cornerRadius: edge.controlCornerRadius, style: .continuous)
                    .fill(isCurrent ? Color.accentColor.opacity(0.22) : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture { model.selectTab(index) }
            .contextMenu {
                Button("移除此文件夹", role: .destructive) {
                    onRemoveFolder(model.mirrors[index].binding.id)
                }
            }
            // 无障碍:作为可切换标签项暴露,带当前选中态(否则 VoiceOver 只当静态文本)。
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    private var addButton: some View {
        Button(action: onAddFolder) {
            Image(systemName: "plus")
        }
        .buttonStyle(.borderless)
        .help("添加文件夹")
        .accessibilityLabel("添加文件夹")
    }
}
