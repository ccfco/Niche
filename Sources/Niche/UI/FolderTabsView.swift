import SwiftUI

/// 顶部文件夹 tab 切换(spec §4.1:绑定多个真实文件夹,顶部 tab 切换;多文件夹是核心体验)。
struct FolderTabsView: View {
    @ObservedObject var model: PanelModel
    let edge: EdgeMetrics
    /// 「+」:弹添加菜单(选择文件夹 / 前往路径,由宿主以 NSMenu+抑制呈现,锚定按钮)。
    var onAddMenu: (_ anchor: NSView?) -> Void = { _ in }
    /// tab 右键:宿主构建带抑制的 NSMenu(移除此文件夹);nil 不弹。
    var onTabMenu: (_ id: FolderBinding.ID) -> NSMenu? = { _ in nil }
    /// 把临时 tab(前往)钉成正式绑定。
    var onPinTemporary: () -> Void = {}

    /// 「+」菜单锚点(弹在按钮下方,toolbar 菜单惯例)。
    private let addAnchor = MenuAnchorBox()

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: edge.innerSpacing) {
                ForEach(Array(model.mirrors.enumerated()), id: \.element.binding.id) { index, mirror in
                    if mirror.isTemporary {
                        temporaryTab(index: index, mirror: mirror)
                    } else {
                        tab(index: index, title: mirror.binding.displayName)
                    }
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
        // 右键菜单走 RightClickCatcher+NSMenu(抑制驱动),不用 .contextMenu —— 那接不上
        // AutoHideCoordinator,菜单开着鼠标移出走廊面板会被收走(与文件右键同一根因)。
        .overlay(RightClickCatcher { _ in onTabMenu(model.mirrors[index].binding.id) })
        // 无障碍:作为可切换标签项暴露,带当前选中态(Button 已是 .isButton,补 .isSelected)。
        .accessibilityLabel(title)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    /// 临时 tab(前往根外目录):前往图标点出身份,内联 📌 钉住(转正式绑定)与 ✕ 关闭。
    /// 不用 .contextMenu 挂动作:SwiftUI 菜单不接 AutoHideCoordinator 抑制,菜单开着面板
    /// 可能被收走(文件右键走 RightClickCatcher+NSMenu 正是为此)。
    private func temporaryTab(index: Int, mirror: DirectoryMirror) -> some View {
        let isCurrent = index == model.currentTab
        return HStack(spacing: 2) {
            Button { model.selectTab(index) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right").font(.caption2)
                    Text(mirror.binding.displayName).lineLimit(1)
                }
            }
            .buttonStyle(NicheFooterGlassButtonStyle(isActive: isCurrent, compact: true))
            .accessibilityLabel("临时:\(mirror.binding.displayName)")
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
            Button(action: onPinTemporary) { Image(systemName: "pin") }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("钉住为常驻文件夹")
                .accessibilityLabel("钉住为常驻文件夹")
            Button { model.closeTemporary() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("关闭临时文件夹")
                .accessibilityLabel("关闭临时文件夹")
        }
    }

    private var addButton: some View {
        Button { onAddMenu(addAnchor.view) } label: {
            Image(systemName: "plus")
        }
        .buttonStyle(NicheFooterGlassButtonStyle(compact: true))   // 与视图切换/底栏同一玻璃语言
        .background(MenuAnchor(box: addAnchor))
        .help("添加文件夹或前往路径")
        .accessibilityLabel("添加文件夹或前往路径")
    }
}
