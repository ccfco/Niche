import SwiftUI

/// 首次使用引导内容(单屏):讲清触发方式,讲完就走。不做完整功能导览——文字面板讲不清楚
/// 互动行为(拖拽/钉住这类动作类心智,读文字和实际操作之间有天然隔阂,写了也没用),
/// tab/拖拽/钉住留给用户在面板里自然发现(同已确认的原始范围)。
///
/// 玻璃质感在 SwiftUI 层(`.glassEffect`),不建 `NSGlassEffectView` 整窗玻璃 —— 窗口层只做
/// 透明标题栏 + 隐藏交通灯(见 OnboardingWindowController),对齐 Clipin 辅助浮层窗口的配方,
/// 比整窗玻璃更轻量,适合这种固定尺寸、无呼出动画的独立小窗。窗口层必须用
/// `NicheGlassHostingView`(不能是裸 `NSHostingView`)—— 后者不透明背衬层会整个盖住这层玻璃。
struct OnboardingView: View {
    let triggerDescription: String
    let onOpenTriggerSettings: () -> Void
    let onDismiss: () -> Void
    private let edge = EdgeMetrics.standard

    var body: some View {
        VStack(spacing: edge.sectionSpacing) {
            header
            Text(triggerDescription)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, edge.sectionSpacing)
            footer
        }
        .padding(edge.panelPadding * 1.5)
        .frame(width: 360)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: edge.panelCornerRadius, style: .continuous))
    }

    private var header: some View {
        VStack(spacing: edge.itemSpacing) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            Text(String(localized: "欢迎使用 Niche"))
                .font(.title2.bold())
        }
    }

    private var footer: some View {
        HStack(spacing: edge.itemSpacing) {
            Button(String(localized: "去设置")) {
                onOpenTriggerSettings()
                onDismiss()
            }
            .buttonStyle(.link)

            Spacer(minLength: 0)

            Button(String(localized: "知道了")) {
                onDismiss()
            }
            .buttonStyle(NicheFooterGlassButtonStyle(isActive: true))
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity)
    }
}
