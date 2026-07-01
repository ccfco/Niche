import AppKit
import SwiftUI

/// 自管设置窗口(替代 SwiftUI `Settings` scene)。
///
/// accessory app 没有公开 API 能从 AppKit 侧打开 Settings scene(`showSettingsWindow:` 私有
/// 选择子在 macOS 14+ 被封禁,SettingsLink 只能活在 SwiftUI 菜单里)。自管一个普通 NSWindow
/// 反而简单可靠:菜单栏「设置…」、面板 ⌘, 都能直达,且可注入 PanelModel(showHidden 单真相源)。
@MainActor
final class SettingsWindowController {
    private let environment: AppEnvironment
    private let model: PanelModel
    private let triggerPrefs: TriggerPreferences
    private let onAddFolder: () -> Void
    private var window: NSWindow?
    private var hostingView: NicheGlassHostingView<AnyView>?
    /// 当前选中分区,窗口控制器持有(而非 SettingsView 的 @State)—— 这样 show(section:) 才能在
    /// 窗口已建好后仍跳转分区,同时关窗重开保留上次选择(与此前行为一致)。
    private var selection: SettingsSection = .folders

    init(environment: AppEnvironment, model: PanelModel, triggerPrefs: TriggerPreferences,
         onAddFolder: @escaping () -> Void) {
        self.environment = environment
        self.model = model
        self.triggerPrefs = triggerPrefs
        self.onAddFolder = onAddFolder
    }

    /// 显示(懒建,关闭后复用同一窗口,保留 tab 选择等窗内状态)。section 非 nil 时跳转到该分区
    /// (Onboarding「去设置」跳「触发」分区用)。
    func show(section: SettingsSection? = nil) {
        if let section, section != selection {
            selection = section
            hostingView?.rootView = makeContent()
        }
        let window = ensureWindow()
        NSApp.activate(ignoringOtherApps: true)   // accessory app 需显式激活,否则窗口不前置
        window.makeKeyAndOrderFront(nil)
    }

    /// 内容宿主用面板同款 `NicheGlassHostingView`(透明、safe area 归零):内容透明坐窗面玻璃上,
    /// 不再叠任何背景 —— 这正是设置页"像面板"的根:整窗一层玻璃,内容只画选中/hover 填充。
    private func makeContent() -> AnyView {
        AnyView(
            SettingsView(
                model: model, triggerPrefs: triggerPrefs,
                selection: Binding(
                    get: { [weak self] in self?.selection ?? .folders },
                    set: { [weak self] in self?.selection = $0 }
                ),
                onAddFolder: onAddFolder
            )
            .environmentObject(environment)
        )
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let size = NSSize(width: SettingsChrome.windowWidth, height: SettingsChrome.windowHeight)

        let host = NicheGlassHostingView(rootView: makeContent())
        hostingView = host

        // 窗面 = macOS 26 原生整窗 Liquid Glass(NSGlassEffectView),与面板(PanelController)同源。
        // 面板因呼出逐帧 resize 会触发玻璃液态 morph,才不把玻璃直接当 contentView;设置页固定尺寸、
        // 无生长动画,直接当 contentView 即可,省掉 container+snap 中介。
        let glass = NSGlassEffectView()
        glass.contentView = host

        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        w.contentView = glass
        w.title = String(localized: "Niche 设置")
        w.titleVisibility = .hidden            // 隐藏标题文字,红绿灯仍保留、浮在玻璃左上
        w.titlebarAppearsTransparent = true    // 内容延伸进 titlebar,整窗才是一块连续玻璃
        w.isMovableByWindowBackground = true   // 无可见标题栏文字,允许直接拖玻璃移动窗口
        w.isReleasedWhenClosed = false         // 关闭只是 orderOut,实例复用
        w.center()
        window = w
        return w
    }
}
