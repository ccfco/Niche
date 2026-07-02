import SwiftUI
import AppKit

/// 设置页(spec §M5):绑定文件夹管理(增删/排序)、触发与快捷键、隐藏文件默认、关于/更新。
///
/// 结构 = 原生 `NavigationSplitView`(侧栏 List + detail)+ 原生 grouped `Form`,对齐
/// macOS 26/27 System Settings 视觉语言(同 Clipin SettingsView.swift 的配方) —— 不再自绘
/// 整窗玻璃 + 文字层级分组,交给系统原生材质与卡片。
/// 宿主注入面板同一个 PanelModel/TriggerPreferences:showHidden、热区等偏好只有一个真相源。
struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var model: PanelModel
    /// 触发方式偏好(热区/延迟/快捷键)单一真相源,由 NicheController 注入并订阅应用。
    @ObservedObject var triggerPrefs: TriggerPreferences
    @ObservedObject var navigation: SettingsNavigationModel
    /// 添加文件夹走 NicheController 统一路径(与面板「+」一致:自动选中新 tab)。
    var onAddFolder: () -> Void = {}

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(navigation: navigation)
        } detail: {
            detailPane
        }
    }

    /// 原生 System Settings 风格详情区:grouped Form 提供分组卡片 + 分隔线,顶部 paneHeader
    /// (图标 + 标题 + 描述)对齐原生每个 pane 的头部块。
    @ViewBuilder
    private var detailPane: some View {
        Form {
            // 「关于」页第一个 Section 本身就是身份卡(图标+名字+版本),已经是它的头部,
            // 不再叠通用 paneHeader,避免"双头"冗余(同 Clipin About 页的取舍)。
            if navigation.selection != .about {
                paneHeader(navigation.selection)
            }
            switch navigation.selection {
            case .folders: FoldersSettings(onAddFolder: onAddFolder)
            case .trigger: TriggerSettings(triggerPrefs: triggerPrefs)
            case .general: GeneralSettings(model: model)
            case .about: AboutSettings()
            }
        }
        .formStyle(.grouped)
        .navigationTitle(navigation.selection.title)
    }

    /// 原生 System Settings 每个 pane 顶部的头部块:accent 圆角方块图标 + 一句摘要。
    /// Section 必须带 header 文字 —— grouped Form 对无 header 的首个 Section 会在顶部留一块
    /// 平台级空白(与内容无关,公开 API 够不着);给分区名当 header 是零自绘的解法,顺带满足
    /// 「设置页内禁止自绘卡片,分组交给 grouped Form」这条 chrome 纪律(同 Clipin 踩过的坑)。
    private func paneHeader(_ section: SettingsSection) -> some View {
        Section(section.title) {
            HStack(alignment: .center, spacing: EdgeMetrics.standard.sectionSpacing) {
                Image(systemName: section.icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: EdgeMetrics.standard.controlCornerRadius, style: .continuous)
                            .fill(Color.accentColor)
                    )
                Text(section.summary)
                    .settingsCaption()
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, EdgeMetrics.standard.innerSpacing)
        }
    }
}

/// 设置窗特有的 chrome 常量(不属于通用 EdgeMetrics 单旋钮:这是窗口维度,不随面板间距旋钮
/// 缩放)。可调尺寸(不再固定死):`NavigationSplitView` + grouped `Form` 原生处理内容滚动,
/// 不需要靠固定窗口尺寸规避 fitting size 顶大窗口那套(旧整窗玻璃方案的限制)。
enum SettingsChrome {
    static let windowSize = NSSize(width: 560, height: 480)
    static let windowMinSize = NSSize(width: 480, height: 380)
}

extension View {
    /// 设置页 grouped Form 里的 caption 副说明统一样式(标题下的次要说明行)。
    /// 收口 `.font(.caption).foregroundStyle(...)` 双修饰,默认 secondary。
    func settingsCaption(_ tint: HierarchicalShapeStyle = .secondary) -> some View {
        self.font(.caption).foregroundStyle(tint)
    }
}
