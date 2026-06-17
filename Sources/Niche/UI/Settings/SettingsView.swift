import SwiftUI
import AppKit

/// 设置页(spec §M5):绑定文件夹管理(增删/排序)、触发与快捷键、隐藏文件默认、关于/更新。
///
/// 结构 = 左 sidebar(书签语义)+ 右内容区,整窗坐在窗面 Liquid Glass 上(SettingsWindowController
/// 的 NSGlassEffectView),内容透明、不再叠系统 Form 灰卡 —— 与面板同一套视觉语言,不再"像两个 App"。
/// 宿主注入面板同一个 PanelModel/TriggerPreferences:showHidden、热区等偏好只有一个真相源。
struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var model: PanelModel
    /// 触发方式偏好(热区/延迟/快捷键)单一真相源,由 NicheController 注入并订阅应用。
    @ObservedObject var triggerPrefs: TriggerPreferences
    /// 添加文件夹走 NicheController 统一路径(与面板「+」一致:自动选中新 tab)。
    var onAddFolder: () -> Void = {}

    @State private var selection: SettingsSection = .folders

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $selection)
            // 导航区↔内容区极淡发丝线:只拉层次,不给 sidebar 套独立材质底板(避免"卡片套卡片")。
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(width: 0.5)
                .frame(maxHeight: .infinity)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // 固定窗口尺寸:不让内容经 NSHostingView fitting 把窗口顶大(见 SettingsChrome.windowHeight)。
        .frame(width: SettingsChrome.windowWidth, height: SettingsChrome.windowHeight)
    }

    @ViewBuilder private var content: some View {
        switch selection {
        case .folders: FoldersSettings(onAddFolder: onAddFolder)
        case .trigger: TriggerSettings(triggerPrefs: triggerPrefs)
        case .general: GeneralSettings(model: model)
        case .about: AboutSettings()
        }
    }
}

/// 设置窗特有的 chrome 常量(不属于通用 EdgeMetrics 单旋钮:这是窗口/titlebar 维度,
/// 不随面板间距旋钮缩放)。收口一处,sidebar 与内容区共用,避免红绿灯让位魔法数两处漂移。
enum SettingsChrome {
    /// 红绿灯让位:窗口 `.fullSizeContentView` + 透明 titlebar 后内容顶到窗顶,须留标准
    /// titlebar 高度,否则品牌区/标题被红绿灯压住。标准 macOS titlebar 高度稳定为 28pt。
    static let titlebarInset: CGFloat = 28

    /// 设置窗固定尺寸(SettingsView 与 SettingsWindowController 共用一处)。固定是必须的:
    /// NSGlassEffectView 当 contentView 会把 NSHostingView 的 fitting size 传给窗口,若 SettingsView
    /// 用 maxHeight:.infinity,内容多的页(文件夹 List 取 8 项 ideal 高度)会把窗口顶大、各页不等高。
    /// 高度按内容最多的文件夹页定:容下标题/footnote/按钮 + List 滚动区。
    static let windowWidth: CGFloat = 524
    static let windowHeight: CGFloat = 492
}

/// 内容区外壳:统一顶部红绿灯让位 + 区标题 + 内边距,各 section 只填内容。
/// 标题左对齐大字(像 macOS 系统设置每页顶部),与 sidebar 同源单旋钮派生间距。
struct SettingsPane<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    private let edge = EdgeMetrics.standard

    var body: some View {
        VStack(alignment: .leading, spacing: edge.sectionSpacing) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .padding(.top, SettingsChrome.titlebarInset)
            content
            // 不放 Spacer:内容少的页靠 frame topLeading 自然顶对齐;内容多的页(文件夹)
            // 由其 List 的 maxHeight:.infinity 吃满剩余高度并滚动 —— Spacer 会与 List 抢剩余空间。
        }
        .padding(edge.panelPadding * 1.5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 设置项分组小标题(替代 Form 的 Section header):内容透明坐玻璃上,只用文字层级分组,
/// 不画灰卡背景(禁卡片套卡片)。
struct SettingsGroup<Content: View>: View {
    var header: String?
    @ViewBuilder var content: Content
    private let edge = EdgeMetrics.standard

    var body: some View {
        VStack(alignment: .leading, spacing: edge.itemSpacing) {
            if let header {
                Text(header)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            content
        }
    }
}

/// 说明性脚注(权限提示等):统一 caption 二级灰,各 section 复用。
struct SettingsFootnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
