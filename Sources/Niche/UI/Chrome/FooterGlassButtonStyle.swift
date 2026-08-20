import SwiftUI

/// 面板内命令按钮的安静状态层。玻璃只由最外层面板承担；内部控件默认透明，hover / active
/// 才出现低对比度状态底，避免每个按钮各自成为一块悬浮材质、与文件内容争夺层级。
struct NicheFooterGlassButtonStyle: ButtonStyle {
    var isActive: Bool = false
    /// 紧凑档:顶部工具条(视图切换 / 加文件夹)用,内边距小一号,圆角仍 = control 保持同心语言。
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, isActive: isActive, compact: compact)
    }

    private struct HoverBody: View {
        @EnvironmentObject private var motion: MotionPreferences
        let configuration: Configuration
        let isActive: Bool
        let compact: Bool
        @State private var isHovered = false
        private let edge = EdgeMetrics.standard
        private var feedback: Animation? {
            motion.reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.82)
        }

        var body: some View {
            let pressed = configuration.isPressed
            let control = edge.controlCornerRadius
            let hPad = compact ? edge.itemSpacing * 1.25 : edge.sectionSpacing   // 10 / 16
            let vPad = compact ? edge.itemSpacing * 0.75 : edge.itemSpacing       //  6 /  8
            // 三态强度收口到 GlassTokens，所有内部 chrome 共享同一套轻量反馈。
            let highlight: Double = pressed ? GlassTokens.pressed
                : (isActive ? GlassTokens.active : (isHovered ? GlassTokens.hover : GlassTokens.idle))
            return configuration.label
                .font(.system(size: 13, weight: .medium))
                .frame(minWidth: 16)
                .padding(.horizontal, hPad)
                .padding(.vertical, vPad)
                .background {
                    RoundedRectangle(cornerRadius: control, style: .continuous)
                        .fill(Color.primary.opacity(highlight))
                }
                .scaleEffect(pressed && !motion.reduceMotion ? 0.97 : 1)
                .contentShape(RoundedRectangle(cornerRadius: control, style: .continuous))
                .onHover { hovering in
                    withAnimation(feedback) { isHovered = hovering }
                }
                .animation(feedback, value: pressed)
        }
    }
}
