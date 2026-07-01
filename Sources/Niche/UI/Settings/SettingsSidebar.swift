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
}

/// 左侧 sidebar:品牌区 + 导航行。**不叠整块玻璃底板** —— 内容透明坐窗面玻璃上(像面板),
/// 与右侧内容区仅靠间距与一条极淡分隔线区分,不做"卡片套卡片"。
struct SettingsSidebar: View {
    @Binding var selection: SettingsSection
    private let edge = EdgeMetrics.standard

    var body: some View {
        VStack(alignment: .leading, spacing: edge.itemSpacing) {
            brand
                .padding(.top, SettingsChrome.titlebarInset)
                .padding(.horizontal, edge.itemSpacing)
                .padding(.bottom, edge.itemSpacing)

            VStack(spacing: edge.innerSpacing) {
                ForEach(SettingsSection.allCases) { section in
                    SidebarRow(section: section, selection: $selection)
                }
            }

            Spacer(minLength: 0)

            // 底部版本号:平衡 sidebar 下半空白 + 实用(文档原计划的"底部状态区")。
            Text("Niche \(appVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, edge.itemSpacing)
                .padding(.bottom, edge.innerSpacing)
        }
        .padding(edge.itemSpacing)
        .frame(width: 168)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// app 版本(Bundle 读;sidebar 装饰用,不耦合 UpdateChecker 服务)。
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private var brand: some View {
        HStack(spacing: edge.innerSpacing) {
            // 真 app 图标(Assets.xcassets/AppIcon):品牌区与 Finder/关于面板同一视觉来源。
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 26, height: 26)
            Text("Niche")
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 0)
        }
    }
}

/// sidebar 单行：图标 + 文字。三态与面板单元同源 —— 选中 `accentColor.selectionFill`(像访达蓝)、
/// hover `primary.hoverFill`(淡灰提示)、静止透明；圆角 `itemCornerRadius`、强度 `GlassTokens`。
private struct SidebarRow: View {
    let section: SettingsSection
    @Binding var selection: SettingsSection
    @State private var isHovered = false
    private let edge = EdgeMetrics.standard
    private let feedback = Animation.spring(response: 0.22, dampingFraction: 0.82)

    private var isSelected: Bool { selection == section }

    var body: some View {
        // 走 Button(而非裸 onTapGesture):设置窗是独立普通 NSWindow,不受面板键盘纪律
        // (那只约束 PanelController 的 keyDown monitor),sidebar 需键盘 Tab/Space/Return
        // 可达 + VoiceOver .isButton 语义;.buttonStyle(.plain) 保留自定义玻璃外观。
        Button {
            selection = section
        } label: {
            HStack(spacing: edge.itemSpacing) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(section.title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.85))
            .padding(.horizontal, edge.itemSpacing)
            .padding(.vertical, edge.itemSpacing * 0.75)
            .background(
                RoundedRectangle(cornerRadius: edge.itemCornerRadius, style: .continuous)
                    .fill(rowFill)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(feedback) { isHovered = hovering }
        }
        .animation(feedback, value: isSelected)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var rowFill: Color {
        if isSelected { return Color.accentColor.opacity(GlassTokens.selectionFill) }
        if isHovered { return Color.primary.opacity(GlassTokens.hoverFill) }
        return .clear
    }
}
