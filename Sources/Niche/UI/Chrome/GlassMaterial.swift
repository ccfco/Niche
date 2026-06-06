import SwiftUI

/// Liquid Glass 面板背景(chrome 纪律:面板整体一层材质,禁卡片套卡片;圆角由 EdgeMetrics 派生)。
///
/// macOS 26 原生 Liquid Glass:用 `.glassEffect` 渲染真正的玻璃材质。
/// 无障碍降级(spec §4.3,非可选):降低透明度/增强对比度开启时,降级为不透明纯色背景 +
/// 实色描边,保证可读性。
struct GlassBackground: View {
    @EnvironmentObject private var motion: MotionPreferences
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if motion.prefersOpaque {
            ZStack {
                shape.fill(Color(nsColor: .windowBackgroundColor))
                shape.strokeBorder(Color.primary.opacity(0.6), lineWidth: 1)
            }
        } else {
            // .clear:Liquid Glass 高通透变体,折射壁纸更明显(对比 .regular 的磨砂)。
            // 无障碍「降低透明度」已有上面的不透明降级兜底,故这里可放心给通透质感。
            Color.clear
                .glassEffect(.clear, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        }
    }
}

extension View {
    /// 给面板根视图套一层 Liquid Glass 背景(或无障碍降级背景)。
    func glassPanelBackground(cornerRadius: CGFloat) -> some View {
        background(GlassBackground(cornerRadius: cornerRadius))
    }
}
