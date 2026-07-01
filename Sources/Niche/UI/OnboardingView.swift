import SwiftUI

/// 首次使用引导内容(单屏):讲清触发方式,讲完就走。不做完整功能导览。
struct OnboardingView: View {
    let triggerDescription: String
    let onOpenTriggerSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text(String(localized: "欢迎使用 Niche"))
                .font(.title2.bold())

            Text(triggerDescription)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)

            Button(String(localized: "去设置")) {
                onOpenTriggerSettings()
                onDismiss()
            }
            .buttonStyle(.link)

            Button(String(localized: "知道了")) {
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(width: 360)
    }
}
