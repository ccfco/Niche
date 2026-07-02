import SwiftUI
import AppKit

/// 设置页左侧导航分区(书签语义:稳定、用户钦定)。顺序即视觉顺序,改这里即改 sidebar。
/// 「触发」从旧 GeneralSettings 拆出独立成页 —— 触发是 Niche 的灵魂交互,值得单列。
enum SettingsSection: String, CaseIterable, Identifiable {
    case folders, trigger, general, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .folders: return String(localized: "文件夹")
        case .trigger: return String(localized: "触发")
        case .general: return String(localized: "通用")
        case .about: return String(localized: "关于")
        }
    }

    var icon: String {
        switch self {
        case .folders: return "folder"
        case .trigger: return "bolt"
        case .general: return "gearshape"
        case .about: return "info.circle"
        }
    }

    /// pane header 摘要——对齐原生 System Settings 每个分区顶部「图标 + 标题 + 一句说明」
    /// (同 Clipin SettingsTab.summary)。
    var summary: String {
        switch self {
        case .folders: return String(localized: "管理从刘海滑出的绑定文件夹(增删/排序)。")
        case .trigger: return String(localized: "刘海热区开关、hover 灵敏度、全局呼出快捷键。")
        case .general: return String(localized: "隐藏文件显示、项目简介、开机自启等默认行为。")
        case .about: return String(localized: "版本、自动更新、开源仓库与许可信息。")
        }
    }
}

/// 设置页当前选中分区的单一真相源。**必须是 ObservableObject,不能是手搓
/// `Binding(get:set:)` 桥接一个普通字段**——后者的 set 闭包写值不会触发 SwiftUI
/// 重渲染(没有 @Published/@State 参与,view 树收不到失效通知),表现为点侧边栏无反应、
/// `show(section:)` 跳转分区不生效(实测踩过)。窗口控制器持有本对象跨 show() 调用存活,
/// 关窗重开保留上次选择。
@MainActor
final class SettingsNavigationModel: ObservableObject {
    @Published var selection: SettingsSection = .folders
}

/// 原生 System Settings 风格侧栏:`List(.sidebar)` 提供系统 vibrancy 材质 + 原生圆角选中
/// 高亮,不再自绘行背景(同 Clipin SettingsView+Sidebar.swift 的配方)。
struct SettingsSidebar: View {
    @ObservedObject var navigation: SettingsNavigationModel

    var body: some View {
        List(selection: selectionBinding) {
            ForEach(SettingsSection.allCases) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
    }

    /// `List(selection:)` 要求 `Binding<SettingsSection?>`;setter 故意吞掉 nil
    /// (⌘-click 取消侧栏当前高亮行会写 nil,原生单选侧栏语义上恒有选中项,同 Clipin)。
    private var selectionBinding: Binding<SettingsSection?> {
        Binding(
            get: { navigation.selection },
            set: { if let section = $0 { navigation.selection = section } }
        )
    }
}
