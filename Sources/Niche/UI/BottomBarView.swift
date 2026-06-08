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
        // 横/底边距 = gap(itemSpacing 8):按钮外缘距面板边 8,使按钮圆角(16)与外壳(24)同心。
        .padding(.horizontal, edge.itemSpacing)
        .padding(.bottom, edge.itemSpacing)
        .padding(.top, edge.innerSpacing)
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
        // 菜单渲染为按钮,套同心圆玻璃样式,与底栏其余按钮统一(chrome 纪律:各按钮自承材质)。
        .menuStyle(.button)
        .buttonStyle(NicheFooterGlassButtonStyle())
        .fixedSize()
        .accessibilityLabel("排序方式")
    }

    private var hiddenToggle: some View {
        Button {
            model.showHidden.toggle()
        } label: {
            Image(systemName: model.showHidden ? "eye" : "eye.slash")
        }
        .buttonStyle(NicheFooterGlassButtonStyle(isActive: model.showHidden))
        .help("显示隐藏文件")
        .accessibilityLabel("显示隐藏文件")
        .accessibilityValue(model.showHidden ? "开" : "关")
    }

    // Pin 激活态用 isActive 常驻高亮(同心玻璃内的填充)传达"已钉住",而非换不透明材质或颜色。
    @ViewBuilder private var pinButton: some View {
        let pinned = model.windowMode == .pinned
        Button(action: onTogglePin) {
            Image(systemName: pinned ? "pin.fill" : "pin")
        }
        .buttonStyle(NicheFooterGlassButtonStyle(isActive: pinned))
        .help(pinned ? "取消钉住" : "钉住(常驻浮窗)")
        .accessibilityLabel(pinned ? "取消钉住" : "钉住为常驻浮窗")
    }
}
