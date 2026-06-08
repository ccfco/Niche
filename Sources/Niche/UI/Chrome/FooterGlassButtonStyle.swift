import SwiftUI

/// 底栏命令按钮样式 = macOS 26 标准 Liquid Glass 按钮(借鉴姊妹项目 Clipin 已验证配方)。
/// 三件套缺一翻车:
/// ① 先内边距给按钮「身体」—— glass 只在当前 bounds 内渲染,label 不留 padding 时玻璃缩成
///    一条发丝、像没有(原生 `.glass` 胶囊 + 图标紧贴就是这毛病)。
/// ② `.regular.interactive()` 原生交互玻璃 —— 悬停给系统灰高亮、按下给 press。
/// ③ `RoundedRectangle(cornerControl)` 而非 Capsule —— 只有固定圆角矩形才能与面板外壳
///    (cornerShell)同心(shell 24 = control 16 + gap 8);Capsule 圆角随高度变,永不同心。
///    hover 高亮再内缩 `footerHoverRimInset` 露一圈玻璃 rim(Raycast 式「内部小一圈灰块」)。
///
/// `isActive`:Pin 等切换态常驻高亮(读作「已钉住/已开」),不靠换 `.glassProminent` 变不透明。
/// `@State` 必须放在内嵌 View 上 —— ButtonStyle 不是 View,挂不住状态(Clipin 踩过)。
struct NicheFooterGlassButtonStyle: ButtonStyle {
    var isActive: Bool = false
    /// 紧凑档:顶部工具条(视图切换 / 加文件夹)用,内边距小一号,圆角仍 = control 保持同心语言。
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, isActive: isActive, compact: compact)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        let isActive: Bool
        let compact: Bool
        @State private var isHovered = false
        private let edge = EdgeMetrics.standard
        private let feedback = Animation.spring(response: 0.22, dampingFraction: 0.82)

        var body: some View {
            let pressed = configuration.isPressed
            let control = edge.footerControlCornerRadius
            let inset = edge.footerHoverRimInset
            let hPad = compact ? edge.itemSpacing * 1.25 : edge.sectionSpacing   // 10 / 16
            let vPad = compact ? edge.itemSpacing * 0.75 : edge.itemSpacing       //  6 /  8
            // 三态强度收口到 GlassTokens(chrome 纪律:禁组件硬编码高亮 opacity,#16)。
            let highlight: Double = pressed ? GlassTokens.pressed
                : (isActive ? GlassTokens.active : (isHovered ? GlassTokens.hover : GlassTokens.idle))
            return configuration.label
                .font(.system(size: 13, weight: .medium))
                .frame(minWidth: 16)
                .padding(.horizontal, hPad)
                .padding(.vertical, vPad)
                .glassEffect(.regular.interactive(),
                             in: RoundedRectangle(cornerRadius: control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: control - inset, style: .continuous)
                        .fill(Color.primary.opacity(highlight))
                        .padding(inset)            // 内缩一圈,露出外层玻璃边
                        .allowsHitTesting(false)   // 高亮层不抢 Button 命中
                )
                .scaleEffect(pressed ? 0.97 : 1)
                .contentShape(RoundedRectangle(cornerRadius: control, style: .continuous))
                .onHover { hovering in
                    withAnimation(feedback) { isHovered = hovering }
                }
                .animation(feedback, value: pressed)
        }
    }
}
