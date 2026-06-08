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

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if motion.prefersOpaque {
            shape.fill(Color(nsColor: .windowBackgroundColor))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.6), lineWidth: 1))
        } else {
            shape.fill(.regularMaterial)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }
}

extension View {
    /// 给面板根视图套一层常规材质背景(或无障碍降级背景)。玻璃只用于控件,不用于此容器底。
    func panelBackground(cornerRadius: CGFloat) -> some View {
        background(PanelSurface(cornerRadius: cornerRadius))
    }
}
