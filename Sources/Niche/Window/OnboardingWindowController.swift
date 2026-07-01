import AppKit
import SwiftUI

/// 首次使用引导是否已展示过。独立于 TriggerPreferences 等业务配置的一次性 UI 标位,
/// 走旁路 UserDefaults(不进 BindingStore 那套 @Published 广播 —— 没有广播的必要)。
enum OnboardingState {
    private static let key = "niche.onboarding.hasSeen"

    static var hasSeen: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// 首次使用引导窗口壳(参照 SettingsWindowController 的量级),不进 PanelController 状态机。
@MainActor
final class OnboardingWindowController: NSWindowController {
    private static var shared: OnboardingWindowController?

    /// 展示引导窗(单例,重复调用只把已存在窗口前置)。onOpenTriggerSettings 由宿主注入,
    /// 点「去设置」时跳转设置窗「触发」分区。
    static func show(triggerDescription: String, onOpenTriggerSettings: @escaping () -> Void) {
        if let shared {
            shared.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = OnboardingWindowController(
            triggerDescription: triggerDescription,
            onOpenTriggerSettings: onOpenTriggerSettings
        )
        shared = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(triggerDescription: String, onOpenTriggerSettings: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.contentView = NSHostingView(rootView: OnboardingView(
            triggerDescription: triggerDescription,
            onOpenTriggerSettings: onOpenTriggerSettings,
            onDismiss: { [weak self] in self?.close() }
        ))
        window.center()
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

extension OnboardingWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        OnboardingState.hasSeen = true
        Self.shared = nil
    }
}
