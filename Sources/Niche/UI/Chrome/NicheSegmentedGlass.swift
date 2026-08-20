import SwiftUI

/// 扁平分段控件。面板外壳是唯一材质层；段本身只用低对比度状态底表达 hover / 选中，
/// 让视图切换退居工具栏层而不是成为另一座玻璃岛。
///
/// 键盘仍由 `PanelController` 的 `keyDown` monitor 单一权威接管(面板键盘纪律);
/// 本控件只接鼠标点选,不加 `.onKeyPress`/`.focusable` 抢键。
struct NicheSegmentedGlass<Value: Hashable>: View {
    @EnvironmentObject private var motion: MotionPreferences
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
    private var feedback: Animation? {
        motion.reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.82)
    }

    var body: some View {
        HStack(spacing: 0) {
            // 拆出 segmentButton:整条 ForEach→Button→onHover→a11y 泛型链挤在一个 ViewBuilder
            // 里会逼近 Swift 类型推断超时(SourceKit 已报),拆子方法让编译器分段推断。
            ForEach(segments) { segmentButton($0) }
        }
        .animation(feedback, value: selection)
    }

    private func segmentButton(_ seg: Segment) -> some View {
        Button { selection = seg.value } label: {
            Image(systemName: seg.systemImage)
        }
        .buttonStyle(SegmentStyle(isSelected: seg.value == selection,
                                  isHovered: hovered == seg.value,
                                  edge: edge,
                                  reduceMotion: motion.reduceMotion))
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

    /// 段样式与普通 toolbar 按钮同源：默认透明、选中或 hover 才显轻量状态底。
    private struct SegmentStyle: ButtonStyle {
        let isSelected: Bool
        let isHovered: Bool
        let edge: EdgeMetrics
        let reduceMotion: Bool
        private var feedback: Animation? {
            reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.82)
        }

        func makeBody(configuration: Configuration) -> some View {
            let pressed = configuration.isPressed
            let control = edge.controlCornerRadius
            let strength: Double = pressed ? GlassTokens.pressed
                : (isSelected ? GlassTokens.active : (isHovered ? GlassTokens.hover : GlassTokens.idle))
            return configuration.label
                .font(.system(size: 13, weight: .medium))
                .frame(minWidth: 16)
                .padding(.horizontal, edge.itemSpacing * 1.25)   // 同 compact 档:10
                .padding(.vertical, edge.itemSpacing * 0.75)      // 同 compact 档:6
                .background {
                    RoundedRectangle(cornerRadius: control, style: .continuous)
                        .fill(Color.primary.opacity(strength))
                }
                .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
                .contentShape(RoundedRectangle(cornerRadius: control, style: .continuous))
                .animation(feedback, value: pressed)
        }
    }
}
