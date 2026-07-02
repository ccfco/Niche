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
        // `.fullSizeContentView` 必须带上:没有它,`.titled` 会在窗口顶部保留一条系统标准
        // titlebar 高度(28pt)的区域,SwiftUI 内容(含圆角玻璃卡片)只画在这条区域下方——
        // titlebar 区自己也是透明背景,于是卡片顶部之上多出一条对不上圆角的透明色带
        // (实测踩过,肉眼像"多出一条莫名的透明边")。带上此 mask 后内容铺满整个窗口,
        // 不再有保留区。
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        // 无交通灯的辅助浮层 chrome(同 Clipin onboarding/permission 窗口的配方):透明
        // titlebar + 隐藏标题文字 + 隐藏红绿灯 + 原生阴影,不建 `NSGlassEffectView` 整窗玻璃——
        // 玻璃质感交给 SwiftUI 层的 `.glassEffect`(见 OnboardingView),窗口层只负责"看起来
        // 不像个普通窗口"。KVC `cornerRadius` 对齐面板外壳圆角,窗与内容视觉同心。
        window.title = String(localized: "欢迎使用 Niche")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isMovableByWindowBackground = true
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { button in
            window.standardWindowButton(button)?.isHidden = true
        }
        window.setValue(EdgeMetrics.standard.panelCornerRadius, forKey: "cornerRadius")

        // 复用 PanelController 的 NicheGlassHostingView,不能用裸 NSHostingView —— 后者默认带
        // 不透明白色背衬层(updateLayer 不清 backgroundColor),会把 SwiftUI 层的 `.glassEffect`
        // 完全遮住,视觉上呈现"死白卡片"而非磨砂玻璃(实测踩过:整块内容看起来完全不透)。
        let host = NicheGlassHostingView(rootView: OnboardingView(
            triggerDescription: triggerDescription,
            onOpenTriggerSettings: onOpenTriggerSettings,
            onDismiss: { [weak self] in self?.close() }
        ))
        window.contentView = host
        // NSHostingView 不会自动把 .zero 起建的窗口撑到内容实际大小,须显式按 fittingSize
        // 设窗口内容尺寸,否则窗口以 0x0 呈现(视觉上等同"没弹出",且极易被误判/意外关闭)。
        window.setContentSize(host.fittingSize)
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
