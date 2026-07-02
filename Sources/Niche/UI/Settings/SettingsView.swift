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

    /// 原生 System Settings 风格详情区:grouped Form 提供分组卡片 + 分隔线。
    /// 对齐原生(见系统「辅助功能」页):pane 标题**同时**出现在工具栏(navigationTitle,小)+
    /// 内容首张介绍卡(paneHeader,图标 + 标题 + 说明,大),两处角色不同、非「双头」冗余。
    /// 「关于」页首个 Section 本身是身份卡(图标+名字+版本),即它的头部,不再叠通用 paneHeader。
    @ViewBuilder
    private var detailPane: some View {
        Form {
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
        // 抵消 NavigationSplitView detail 列的幻影顶部空白(SwiftUI 已确认 bug rdar://122947424:
        // detail 列重复传播工具栏高度的 safe area,凭空多出≈一个工具栏高的空白)。见
        // SettingsChrome.settingsDetailTopGapFix。负 padding 把内容上移到标题栏正下方。
        // 曾试图换掉这个 hack 去换取滚动边缘玻璃模糊,实测手建窗口这套结构下玻璃效果做不出来
        // (同 Clipin 结论),遂保留此已验证方案,不再折腾。
        .padding(.top, -SettingsChrome.settingsDetailTopGapFix)
        .navigationTitle(navigation.selection.title)
    }

    /// 原生 System Settings 每个 pane 顶部的介绍卡:accent 圆角方块图标 + 标题 + 一句说明。
    /// 参照系统「辅助功能」页——标题内嵌在卡片里(与工具栏标题相同,原生本就重复,见 detailPane
    /// 注释),不再用 `Section(title)` 把标题拎成 grey section header。作为 grouped Form 首张
    /// 卡片(无 section header),卡片外观交给 Form 原生绘制,不自绘背景(chrome 纪律)。
    /// 顶部幻影空白由 detailPane 的负补偿统一抵消,见 SettingsChrome.settingsDetailTopGapFix。
    private func paneHeader(_ section: SettingsSection) -> some View {
        Section {
            HStack(alignment: .center, spacing: EdgeMetrics.standard.sectionSpacing) {
                Image(systemName: section.icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: EdgeMetrics.standard.controlCornerRadius, style: .continuous)
                            .fill(Color.accentColor)
                    )
                VStack(alignment: .leading, spacing: EdgeMetrics.standard.innerSpacing) {
                    Text(section.title).font(.headline)
                    Text(section.summary)
                        .settingsCaption()
                        .fixedSize(horizontal: false, vertical: true)
                }
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

    /// 设置页 detail 顶部负补偿:抵消 SwiftUI 已确认 bug(rdar://122947424)——
    /// NavigationSplitView 的 detail 列把工具栏高度的 safe area 重复传播,凭空多出
    /// ≈一个工具栏高的顶部空白(详见 developer.apple.com/forums/thread/746611)。
    /// 补偿框架 bug、非设计间距,故不挂 EdgeMetrics 网格;值≈工具栏高,经验值,随 macOS
    /// 版本可能微调——若顶部仍有空隙或内容被压到标题下,调这一个数。(与 Clipin 同构)
    static let settingsDetailTopGapFix: CGFloat = 20
}

extension View {
    /// 设置页 grouped Form 里的 caption 副说明统一样式(标题下的次要说明行)。
    /// 收口 `.font(.caption).foregroundStyle(...)` 双修饰,默认 secondary。
    func settingsCaption(_ tint: HierarchicalShapeStyle = .secondary) -> some View {
        self.font(.caption).foregroundStyle(tint)
    }
}
