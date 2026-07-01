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

    init(environment: AppEnvironment, model: PanelModel, triggerPrefs: TriggerPreferences,
         onAddFolder: @escaping () -> Void) {
        self.environment = environment
        self.model = model
        self.triggerPrefs = triggerPrefs
        self.onAddFolder = onAddFolder
    }

    /// 显示(懒建,关闭后复用同一窗口,保留 tab 选择等窗内状态)。
    func show() {
        let window = ensureWindow()
        NSApp.activate(ignoringOtherApps: true)   // accessory app 需显式激活,否则窗口不前置
        window.makeKeyAndOrderFront(nil)
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let size = NSSize(width: SettingsChrome.windowWidth, height: SettingsChrome.windowHeight)

        // 内容宿主用面板同款 `NicheGlassHostingView`(透明、safe area 归零):内容透明坐窗面玻璃上,
        // 不再叠任何背景 —— 这正是设置页"像面板"的根:整窗一层玻璃,内容只画选中/hover 填充。
        let host = NicheGlassHostingView(
            rootView: SettingsView(model: model, triggerPrefs: triggerPrefs, onAddFolder: onAddFolder)
                .environmentObject(environment)
        )

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
