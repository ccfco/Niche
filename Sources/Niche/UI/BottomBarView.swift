import SwiftUI

/// 底栏(chrome 纪律:各按钮自承材质,不套卡片;间距由 EdgeMetrics 派生)。
/// M1:Pin 切换 + 排序/隐藏开关;M2 扩展 tab 切换等。
struct BottomBarView: View {
    @ObservedObject var model: PanelModel
    let edge: EdgeMetrics
    /// 排序按钮:弹排序菜单(由宿主以 NSMenu+抑制呈现,锚定按钮)。不用 SwiftUI Menu——
    /// 那会抢 key 焦点让瞬态面板 didResignKey 即收回(鼠标移到排序按钮上面板就消失的根因)。
    var onSortMenu: (_ anchor: NSView?) -> Void = { _ in }
    var onTogglePin: () -> Void = {}
    /// 图标缩放滑块拖动起止(true=开始/false=松手)→ 宿主抑制/解除 auto-hide。
    var onIconSizeEditing: (Bool) -> Void = { _ in }

    /// 排序菜单锚点(弹在按钮下方,toolbar 菜单惯例)。
    private let sortAnchor = MenuAnchorBox()

    var body: some View {
        HStack(spacing: edge.itemSpacing) {
            sortButton
            hiddenToggle
            Spacer()
            if model.viewMode == .icon { iconSizeSlider }
            pinButton
        }
        // 横/底边距 = gap(itemSpacing 8):按钮外缘距面板边 8,使按钮圆角(16)与外壳(24)同心。
        .padding(.horizontal, edge.itemSpacing)
        .padding(.bottom, edge.itemSpacing)
        .padding(.top, edge.innerSpacing)
    }

    /// 图标缩放滑块(仅图标视图)—— 对齐访达底部缩放条:无极调图标大小,两端小/大图标提示。
    /// 拖动只改 model.iconSize(→ cell frame 缩放 + 列数),缩略图按最大尺寸生成一次不重取,丝滑。
    private var iconSizeSlider: some View {
        // HStack 手放两端小/大图标 + 纯 Slider:init 简单确定,两端提示不依赖 labelsHidden 行为。
        // 拖动实时缩放(iconSize @Published),松手(onEditingChanged false)才持久化,不逐帧写盘。
        HStack(spacing: edge.innerSpacing) {
            Image(systemName: "photo").font(.system(size: 8)).foregroundStyle(.secondary)
            Slider(value: $model.iconSize, in: PanelModel.iconSizeRange,
                   onEditingChanged: { editing in
                       onIconSizeEditing(editing)            // 拖动期间抑制 auto-hide(防鼠标甩出收面板)
                       if !editing { model.persistIconSize() }   // 松手才落盘
                   })
                .controlSize(.mini)
                .frame(width: edge.base * 9)   // ~72pt 轨道,两端图标另算,不挤占底栏
            Image(systemName: "photo").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .help("图标大小")
        .accessibilityLabel("图标大小")
    }

    private var sortButton: some View {
        Button { onSortMenu(sortAnchor.view) } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        // 与底栏其余按钮统一玻璃语言(chrome 纪律:各按钮自承材质)。
        .buttonStyle(NicheFooterGlassButtonStyle())
        .background(MenuAnchor(box: sortAnchor))
        .help("排序方式")
        .accessibilityLabel("排序方式")
        .accessibilityValue(sortDescription)   // VoiceOver 读出当前排序态,不用进菜单才知道
    }

    private var sortDescription: String {
        let key: String
        switch model.sortOrder.key {
        case .name: key = "名称"
        case .date: key = "修改日期"
        case .size: key = "大小"
        case .kind: key = "类型"
        }
        return "按\(key)\(model.sortOrder.direction == .ascending ? "升序" : "降序")"
    }

    private var hiddenToggle: some View {
        Button {
            model.showHidden.toggle()
        } label: {
            // 图标恒定 eye,靠 isActive 高亮表达开关(与 pin 一致),不换图标(#18)。
            Image(systemName: "eye")
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
