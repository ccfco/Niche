import SwiftUI

/// 底栏(chrome 纪律:各按钮自承材质,不套卡片;间距由 EdgeMetrics 派生)。
/// M1:Pin 切换 + 排序/隐藏开关;M2 扩展 tab 切换等。
struct BottomBarView: View {
    @ObservedObject var model: PanelModel
    let edge: EdgeMetrics
    var onTogglePin: () -> Void = {}

    var body: some View {
        HStack(spacing: edge.itemSpacing) {
            sortMenu
            hiddenToggle
            Spacer()
            pinButton
        }
        .padding(.horizontal, edge.panelPadding)
        .padding(.vertical, edge.innerSpacing)
    }

    private var sortMenu: some View {
        Menu {
            Picker("排序", selection: $model.sortOrder.key) {
                Text("名称").tag(FileSortOrder.Key.name)
                Text("修改日期").tag(FileSortOrder.Key.date)
                Text("大小").tag(FileSortOrder.Key.size)
                Text("类型").tag(FileSortOrder.Key.kind)
            }
            Divider()
            Picker("方向", selection: $model.sortOrder.direction) {
                Text("升序").tag(FileSortOrder.Direction.ascending)
                Text("降序").tag(FileSortOrder.Direction.descending)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var hiddenToggle: some View {
        Button {
            model.showHidden.toggle()
        } label: {
            Image(systemName: model.showHidden ? "eye" : "eye.slash")
        }
        .help("显示隐藏文件")
    }

    private var pinButton: some View {
        Button(action: onTogglePin) {
            Image(systemName: model.windowMode == .pinned ? "pin.fill" : "pin")
        }
        .help(model.windowMode == .pinned ? "取消钉住" : "钉住(常驻浮窗)")
    }
}
