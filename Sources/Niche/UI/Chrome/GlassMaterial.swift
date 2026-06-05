import SwiftUI

/// Liquid Glass 面板背景(chrome 纪律:面板整体一层材质,禁卡片套卡片;圆角由 EdgeMetrics 派生)。
///
/// 无障碍降级(spec §4.3,非可选):降低透明度/增强对比度开启时,从材质模糊降级为不透明
/// 纯色背景 + 实色描边,保证可读性。
struct GlassBackground: View {
    @EnvironmentObject private var motion: MotionPreferences
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if motion.prefersOpaque {
                // 降级:不透明纯色 + 实色描边。
                shape.fill(Color(nsColor: .windowBackgroundColor))
                shape.strokeBorder(Color.primary.opacity(0.6), lineWidth: 1)
            } else {
                shape.fill(.ultraThinMaterial)
                shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            }
        }
    }
}

extension View {
    /// 给面板根视图套一层 Liquid Glass 背景(或无障碍降级背景)。
    func glassPanelBackground(cornerRadius: CGFloat) -> some View {
        background(GlassBackground(cornerRadius: cornerRadius))
    }
}
