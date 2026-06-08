import SwiftUI

/// 面板表面背景(macOS 26 Liquid Glass 纪律:**容器/底用常规材质,玻璃只给浮层控件**)。
///
/// 整块面板背景用 `.regularMaterial` —— 一致、不随窗口焦点变化、可读。**不**用 `.glassEffect`:
/// 其 clear 变体过于通透,且活跃/非活跃窗口渲染差异大(瞬态很透、pin 后变磨砂发白),会显得"两套"。
/// 玻璃质感留给底栏按钮等浮层控件(见 BottomBarView 的 `.buttonStyle(.glass)`/`.glassProminent`)。
/// 无障碍降级(spec §4.3,非可选):降低透明度/增强对比度开启时,换不透明纯色背景 + 实色描边。
struct PanelSurface: View {
    @EnvironmentObject private var motion: MotionPreferences
    let cornerRadius: CGFloat

    /// 抽屉形:顶角小、底角大 —— 像从刘海下方"拉出"的抽屉,而非凭空浮的圆角矩形。
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: cornerRadius * 0.5,
            bottomLeadingRadius: cornerRadius,
            bottomTrailingRadius: cornerRadius,
            topTrailingRadius: cornerRadius * 0.5,
            style: .continuous
        )
    }

    var body: some View {
        if motion.prefersOpaque {
            shape.fill(Color(nsColor: .windowBackgroundColor))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.6), lineWidth: 1))
        } else {
            // 暗色玻璃:ultraThin 背景模糊(折射壁纸)+ 暗色 tint(与黑色刘海连续、压住背景花纹)+
            // 顶缘高光描边(玻璃受光边,macOS 26 标志)。在 .darkAqua 外观下渲染,稳定不随焦点变。
            shape.fill(.ultraThinMaterial)
                .overlay(shape.fill(Color.black.opacity(0.30)))
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.30), .white.opacity(0.06)],
                            startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.8)
                )
        }
    }
}

extension View {
    /// 给面板根视图套一层常规材质背景(或无障碍降级背景)。玻璃只用于控件,不用于此容器底。
    func panelBackground(cornerRadius: CGFloat) -> some View {
        background(PanelSurface(cornerRadius: cornerRadius))
    }
}
