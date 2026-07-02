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
    /// 当前选中分区的单一真相源,窗口控制器持有、跨 show() 调用存活(见 SettingsNavigationModel 注释)。
    private let navigation = SettingsNavigationModel()

    init(environment: AppEnvironment, model: PanelModel, triggerPrefs: TriggerPreferences,
         onAddFolder: @escaping () -> Void) {
        self.environment = environment
        self.model = model
        self.triggerPrefs = triggerPrefs
        self.onAddFolder = onAddFolder
    }

    /// 显示(懒建,关闭后复用同一窗口,保留 tab 选择等窗内状态)。section 非 nil 时跳转到该分区
    /// (Onboarding「去设置」跳「触发」分区用)。直接写 @Published,SwiftUI 自动重渲染,
    /// 不需要重建/替换 rootView。
    func show(section: SettingsSection? = nil) {
        if let section { navigation.selection = section }
        let window = ensureWindow()
        NSApp.activate(ignoringOtherApps: true)   // accessory app 需显式激活,否则窗口不前置
        window.makeKeyAndOrderFront(nil)
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }

        // 原生 System Settings 风格:标准窗口 chrome(红绿灯 + 可拉伸),侧栏材质铺满全高。
        // `.fullSizeContentView` 必须保留 —— 原生 `NavigationSplitView` 靠它把 sidebar 的
        // vibrancy 材质延伸到窗口最顶端、让红绿灯坐在侧栏材质上(macOS 26 原生结构),并自动把
        // detail 区避让到工具栏下方。不再叠 `NSGlassEffectView` 整窗玻璃(那是面板/旧设置页的
        // 自绘配方) —— NavigationSplitView + grouped Form 本身就是原生 Liquid Glass,自绘玻璃
        // 反而和系统材质冲突。配套:`titlebarAppearsTransparent` 让材质透上来、
        // `titlebarSeparatorStyle=.none` 去分隔线,`titleVisibility=.visible` 让
        // `.navigationTitle(section.title)` 桥到工具栏显示当前分区名(对齐系统设置每页顶部标题)。
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsChrome.windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        w.title = String(localized: "Niche 设置")
        w.titleVisibility = .visible
        w.titlebarAppearsTransparent = true
        w.titlebarSeparatorStyle = .none
        w.isReleasedWhenClosed = false         // 关闭只是 orderOut,实例复用
        w.setContentSize(SettingsChrome.windowSize)
        w.contentMinSize = SettingsChrome.windowMinSize
        w.contentView = NSHostingView(
            rootView: SettingsView(
                model: model, triggerPrefs: triggerPrefs, navigation: navigation,
                onAddFolder: onAddFolder
            )
            .environmentObject(environment)
        )
        w.center()
        window = w
        return w
    }
}
