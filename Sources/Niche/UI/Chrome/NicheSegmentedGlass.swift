import SwiftUI

/// 分段玻璃控件 = 一块玻璃胶囊 + 内部 N 段单选(借鉴 Finder 工具栏视图切换:
/// 互斥的同类选项挤进同一个胶囊,异质的独立动作才各自分开)。
///
/// 取代「并排两颗独立玻璃 pill」:并排两块玻璃读作两张卡(碰「禁卡片套卡片」),
/// 改为单块胶囊承一份材质、选中段浮 rim-inset 高亮 —— 才是原生分段语言。
/// 无分隔线(macOS 26 Liquid Glass 现代分段只浮高亮);高亮三态与底栏按钮同源
/// (`GlassTokens`),圆角同源(`EdgeMetrics`),与外壳同心。
///
/// 键盘仍由 `PanelController` 的 `keyDown` monitor 单一权威接管(面板键盘纪律);
/// 本控件只接鼠标点选,不加 `.onKeyPress`/`.focusable` 抢键。
struct NicheSegmentedGlass<Value: Hashable>: View {
    struct Segment: Identifiable {
        let value: Value
        let systemImage: String
        let help: String
        let label: String   // VoiceOver 读出
        var id: Value { value }
    }

    @Binding var selection: Value
    let segments: [Segment]

    @State private var hovered: Value?
    private let edge = EdgeMetrics.standard
    private let feedback = Animation.spring(response: 0.22, dampingFraction: 0.82)

    var body: some View {
        HStack(spacing: 0) {
            // 拆出 segmentButton:整条 ForEach→Button→onHover→a11y 泛型链挤在一个 ViewBuilder
            // 里会逼近 Swift 类型推断超时(SourceKit 已报),拆子方法让编译器分段推断。
            ForEach(segments) { segmentButton($0) }
        }
        // 一块玻璃承整组,圆角 = footerControlCornerRadius(16,与外壳 24 同心)。
        // 用非交互 .regular(而非 .interactive()):.interactive() 是给单个控件的,套在含多个
        // Button 的容器上会被 Liquid Glass 按子控件各裹一层 → 裂成两块。容器只做统一背景玻璃,
        // 按压/选中反馈由各段自理(scaleEffect + glassHighlight)。
        .glassEffect(.regular,
                     in: RoundedRectangle(cornerRadius: edge.footerControlCornerRadius, style: .continuous))
        .animation(feedback, value: selection)
    }

    private func segmentButton(_ seg: Segment) -> some View {
        Button { selection = seg.value } label: {
            Image(systemName: seg.systemImage)
        }
        .buttonStyle(SegmentStyle(isSelected: seg.value == selection,
                                  isHovered: hovered == seg.value,
                                  edge: edge))
        .onHover { hovering in
            withAnimation(feedback) {
                if hovering { hovered = seg.value }
                else if hovered == seg.value { hovered = nil }
            }
        }
        .help(seg.help)
        .accessibilityLabel(seg.label)
        .accessibilityAddTraits(seg.value == selection ? .isSelected : [])
    }

    /// 段样式:自身不承玻璃(玻璃在容器),只画 rim-inset 高亮 + press 缩放,
    /// 与 `NicheFooterGlassButtonStyle` 同款触感。段内边距对齐 compact 档(10 / 6)。
    private struct SegmentStyle: ButtonStyle {
        let isSelected: Bool
        let isHovered: Bool
        let edge: EdgeMetrics
        private let feedback = Animation.spring(response: 0.22, dampingFraction: 0.82)

        func makeBody(configuration: Configuration) -> some View {
            let pressed = configuration.isPressed
            let control = edge.footerControlCornerRadius
            let inset = edge.footerHoverRimInset
            let strength: Double = pressed ? GlassTokens.pressed
                : (isSelected ? GlassTokens.active : (isHovered ? GlassTokens.hover : GlassTokens.idle))
            return configuration.label
                .font(.system(size: 13, weight: .medium))
                .frame(minWidth: 16)
                .padding(.horizontal, edge.itemSpacing * 1.25)   // 同 compact 档:10
                .padding(.vertical, edge.itemSpacing * 0.75)      // 同 compact 档:6
                .glassHighlight(strength, edge: edge)
                .scaleEffect(pressed ? 0.97 : 1)
                .contentShape(RoundedRectangle(cornerRadius: control - inset, style: .continuous))
                .animation(feedback, value: pressed)
        }
    }
}
