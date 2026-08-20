import SwiftUI
import AppKit

// 设置页四个内容分区。原生 grouped Form 的 Section 就是卡片(macOS 26/27 System Settings
// 视觉语言),各区只声明 Section,不再自绘 SettingsPane/SettingsGroup 那套文字层级分组。

/// 文件夹:绑定文件夹的增删与排序。**保留 `ForEach + .onMove`** 拿系统拖拽排序语义(不自研)。
struct FoldersSettings: View {
    @EnvironmentObject private var environment: AppEnvironment
    var onAddFolder: () -> Void = {}
    /// 待确认移除的绑定(误点删除无 undo,弹确认而非立即删)。
    @State private var pendingRemoval: FolderBinding?

    var body: some View {
        Section {
            ForEach(environment.bindingStore.bindings) { binding in
                bindingRow(binding)
            }
            .onMove { source, dest in
                environment.bindingStore.move(from: source, to: dest)
            }
            Button { onAddFolder() } label: {
                Label("添加文件夹…", systemImage: "plus")
            }
        } footer: {
            Text("从刘海滑出后,每个绑定文件夹是一个 tab。拖动可调整顺序。").settingsCaption()
        }
        .confirmationDialog(
            "移除「\(pendingRemoval?.displayName ?? "")」?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
        ) {
            Button("移除", role: .destructive) {
                if let binding = pendingRemoval { environment.bindingStore.remove(id: binding.id) }
                pendingRemoval = nil
            }
        } message: {
            Text("只解除绑定,不会动磁盘上的文件夹。")
        }
    }

    private func bindingRow(_ binding: FolderBinding) -> some View {
        HStack(spacing: EdgeMetrics.standard.itemSpacing) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {   // 名称↔副路径紧贴,纯排版微距
                Text(binding.displayName)
                Text(binding.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button(role: .destructive) {
                pendingRemoval = binding
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "移除此文件夹"))
            .accessibilityLabel(String(localized: "移除「\(binding.displayName)」"))
        }
    }
}

/// 触发:刘海热区开关、hover 灵敏度、全局快捷键。从旧 GeneralSettings 拆出独立成页。
struct TriggerSettings: View {
    @ObservedObject var triggerPrefs: TriggerPreferences

    var body: some View {
        Section {
            Toggle("顶部悬停触发", isOn: $triggerPrefs.hotZoneEnabled)
            PreferenceSliderRow(
                title: String(localized: "悬停确认"),
                valueText: hoverDelayText,
                value: hoverPosition,
                range: 0...1,
                tickCount: 5,
                minimumLabel: String(localized: "灵敏 0.1 秒"),
                maximumLabel: String(localized: "最稳 5 秒"),
                onEditingEnded: { triggerPrefs.persistHoverDelay() }
            )
            .disabled(!triggerPrefs.hotZoneEnabled
                      && triggerPrefs.enabledHotCorners.isEmpty
                      && triggerPrefs.enabledSides.isEmpty)
            LabeledContent("呼出快捷键") {
                HotkeyRecorderView(hotkey: $triggerPrefs.hotkey)
            }
        } footer: {
            Text("空手悬停使用精确热区和确认延迟；拖着文件靠近仍会立即迎上。关闭热区后仍可用菜单栏图标或快捷键呼出。").settingsCaption()
        }

        Section {
            Toggle("顶部中央触发", isOn: $triggerPrefs.fallbackHotZoneEnabled)
                .disabled(!triggerPrefs.hotZoneEnabled)
            if triggerPrefs.fallbackHotZoneEnabled {
                PreferenceSliderRow(
                    title: String(localized: "顶部热区宽度"),
                    valueText: "\(Int((triggerPrefs.hotZoneWidthScale * 100).rounded()))%",
                    value: $triggerPrefs.hotZoneWidthScale,
                    range: 0.6...2,
                    tickCount: 5,
                    minimumLabel: String(localized: "窄"),
                    maximumLabel: String(localized: "宽"),
                    onEditingEnded: { triggerPrefs.persistHotZoneWidthScale() }
                )
                .disabled(!triggerPrefs.hotZoneEnabled)
            }
        } header: {
            Text("无刘海屏幕")
        } footer: {
            Text("只影响外接显示器和无刘海 Mac；真实刘海始终按物理范围命中。关闭后这些屏幕仍可使用快捷键、热角或边缘触发。").settingsCaption()
        }

        Section {
            ForEach(ScreenCorner.allCases, id: \.self) { corner in
                Toggle(corner.title, isOn: hotCornerBinding(corner))
            }
        } header: {
            Text("热角")
        } footer: {
            Text("鼠标移到勾选的屏幕角落即可呼出,面板从该角展开,同 macOS 系统热角。不支持拖拽文件迎上。").settingsCaption()
        }

        Section {
            ForEach(ScreenSide.allCases, id: \.self) { side in
                Toggle(side.title, isOn: sideBinding(side))
            }
        } header: {
            Text("边缘触发")
        } footer: {
            Text("鼠标移到勾选的屏幕边缘即可呼出,面板从鼠标所在位置滑出。启用 Dock 所在边时留意误触。").settingsCaption()
        }
    }

    private var hoverPosition: Binding<Double> {
        Binding(
            get: { TriggerPreferences.sliderPosition(for: triggerPrefs.hoverDelay) },
            set: { triggerPrefs.hoverDelay = TriggerPreferences.hoverDelay(forSliderPosition: $0) }
        )
    }

    private var hoverDelayText: String {
        let delay = triggerPrefs.hoverDelay
        if delay < 1 { return String(format: "%.2f 秒", delay) }
        return String(format: "%.1f 秒", delay)
    }

    private func hotCornerBinding(_ corner: ScreenCorner) -> Binding<Bool> {
        Binding(
            get: { triggerPrefs.enabledHotCorners.contains(corner) },
            set: { isOn in
                if isOn { triggerPrefs.enabledHotCorners.insert(corner) }
                else { triggerPrefs.enabledHotCorners.remove(corner) }
            }
        )
    }

    private func sideBinding(_ side: ScreenSide) -> Binding<Bool> {
        Binding(
            get: { triggerPrefs.enabledSides.contains(side) },
            set: { isOn in
                if isOn { triggerPrefs.enabledSides.insert(side) }
                else { triggerPrefs.enabledSides.remove(side) }
            }
        )
    }
}

/// 面板:尺寸直接保存为点数，与列/行数解耦；内容密度与现场底栏共用 PanelModel 单一真相源。
struct PanelSettings: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        Section {
            PreferenceSliderRow(
                title: String(localized: "面板宽度"),
                valueText: "\(Int(model.preferredPanelWidth.rounded())) pt",
                value: widthBinding,
                range: Double(PanelModel.panelWidthRange.lowerBound)...Double(PanelModel.panelWidthRange.upperBound),
                tickCount: 6,
                minimumLabel: String(localized: "紧凑"),
                maximumLabel: String(localized: "宽"),
                onEditingEnded: { model.persistPanelSize() }
            )
            PreferenceSliderRow(
                title: String(localized: "面板高度"),
                valueText: "\(Int(model.preferredPanelHeight.rounded())) pt",
                value: heightBinding,
                range: Double(PanelModel.panelHeightRange.lowerBound)...Double(PanelModel.panelHeightRange.upperBound),
                tickCount: 6,
                minimumLabel: String(localized: "紧凑"),
                maximumLabel: String(localized: "高"),
                onEditingEnded: { model.persistPanelSize() }
            )
        } header: {
            Text("尺寸")
        } footer: {
            Text("滑杆连续可调，刻度只作参考、不强制吸附。面板在较小屏幕上会自动夹取到可见区域内，不改写你的偏好。").settingsCaption()
        }

        Section {
            Picker("文件视图", selection: $model.viewMode) {
                Text("图标").tag(FileViewMode.icon)
                Text("列表").tag(FileViewMode.list)
            }
            Picker("文件名行数", selection: $model.filenameLineLimit) {
                Text("1 行").tag(1)
                Text("2 行").tag(2)
                Text("3 行").tag(3)
            }
            if model.viewMode == .icon {
                PreferenceSliderRow(
                    title: String(localized: "图标大小"),
                    valueText: "\(Int(model.iconSize.rounded())) pt",
                    value: iconSizeBinding,
                    range: Double(PanelModel.iconSizeRange.lowerBound)...Double(PanelModel.iconSizeRange.upperBound),
                    tickCount: 5,
                    minimumLabel: String(localized: "小"),
                    maximumLabel: String(localized: "大"),
                    onEditingEnded: { model.persistIconSize() }
                )
            }
            Toggle("显示项目信息", isOn: $model.showItemInfo)
            Toggle("显示隐藏文件", isOn: $model.showHidden)
        } header: {
            Text("内容")
        } footer: {
            Text("文件名只有真实被截断时才显示系统完整名称提示；图标大小也可以在面板底栏现场调整。").settingsCaption()
        }

        Section {
            Picker("鼠标离开后收起", selection: $model.autoHideDelay) {
                ForEach(PanelModel.autoHideDelayOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            Button("恢复面板默认设置") { model.restorePanelDefaults() }
        } header: {
            Text("行为")
        } footer: {
            Text("Pin 后面板保持常驻，不受自动收起设置影响。").settingsCaption()
        }
    }

    private var widthBinding: Binding<Double> {
        Binding(get: { Double(model.preferredPanelWidth) },
                set: { model.preferredPanelWidth = CGFloat($0) })
    }

    private var heightBinding: Binding<Double> {
        Binding(get: { Double(model.preferredPanelHeight) },
                set: { model.preferredPanelHeight = CGFloat($0) })
    }

    private var iconSizeBinding: Binding<Double> {
        Binding(get: { Double(model.iconSize) }, set: { model.iconSize = CGFloat($0) })
    }
}

/// 通用:应用级行为。面板显示偏好已集中到独立「面板」页。
struct GeneralSettings: View {
    /// SMAppService 状态是系统侧真相,本地只留 UI 镜像;失败弹提示并回读真实状态(不静默)。
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    var body: some View {
        Section {
            Toggle("开机自启", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    guard enabled != LaunchAtLogin.isEnabled else { return }
                    do { try LaunchAtLogin.set(enabled) }
                    catch {
                        launchError = error.localizedDescription
                        launchAtLogin = LaunchAtLogin.isEnabled   // 回读系统真相
                    }
                }
        } footer: {
            Text("首次访问桌面/文稿/下载等受保护目录时,系统会弹出授权请求;允许后镜像才会实时同步。").settingsCaption()
        }
        // 复用窗口(isReleasedWhenClosed=false):重开设置页时回读系统真相,避免外部改了
        // Login Items 后仍显示陈旧 @State 镜像。
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
        .alert("无法更改开机自启", isPresented: Binding(
            get: { launchError != nil }, set: { if !$0 { launchError = nil } }
        )) {
            Button("好") { launchError = nil }
        } message: {
            Text(launchError ?? "")
        }
    }
}

/// 关于:身份卡(图标+名字+版本,自身即头部,不叠通用 paneHeader)、自动更新、更新状态与下载、项目信息。
struct AboutSettings: View {
    @ObservedObject private var checker = UpdateChecker.shared

    /// 版权(读 Info.plist NSHumanReadableCopyright,不在 UI 硬编码年份 —— 年份会过时)。
    private var copyright: String? {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
    }

    var body: some View {
        // 身份卡作为「关于」页的头部(图标+名字+版本),无 section header。顶部幻影空白
        // 由 detailPane 的负补偿统一抵消(rdar://122947424),见 SettingsChrome.settingsDetailTopGapFix
        // ——不再靠给 Section 传 header 文字来填(那是被幻影空白误导的旧解法,原生首张介绍卡
        // 就是无 header 且不留白)。
        Section {
            HStack(spacing: EdgeMetrics.standard.sectionSpacing) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Niche").font(.headline)
                    Text("Niche \(checker.currentVersion)").settingsCaption()
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, EdgeMetrics.standard.innerSpacing)
            Toggle("自动检查更新", isOn: Binding(
                get: { checker.autoCheckEnabled },
                set: { checker.setAutoCheckEnabled($0) }
            ))
        }

        Section(String(localized: "更新")) {
            LabeledContent("状态") { updateStatusView }
            if let release = checker.latestRelease {
                HStack(spacing: EdgeMetrics.standard.itemSpacing) {
                    Button("安装更新") { checker.installUpdate() }
                    Button("查看 Release") { checker.openReleasePage() }
                }
                Text("Niche \(release.displayVersion) 已可安装（一键自动安装）。").settingsCaption()
            } else {
                Button("立即检查") { checker.checkNow() }
                    .disabled(checker.isChecking)
            }
        }

        Section {
            LabeledContent("开源仓库") {
                Link("github.com/ccfco/Niche",
                     destination: URL(string: "https://github.com/ccfco/Niche")!)
            }
            LabeledContent("许可") {
                Text("MIT").settingsCaption()
            }
        } header: {
            Text("项目")
        } footer: {
            if let copyright {
                Text(copyright).settingsCaption()
            }
        }
    }

    @ViewBuilder private var updateStatusView: some View {
        if checker.isChecking {
            HStack(spacing: EdgeMetrics.standard.innerSpacing) {
                ProgressView().controlSize(.small)
                Text("正在检查…").foregroundStyle(.secondary)
            }
        } else if checker.latestRelease != nil {
            Label("发现新版本", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.green)
        } else if checker.didLastCheckFail {
            Label("检查失败", systemImage: "exclamationmark.circle")
                .foregroundStyle(.secondary)
        } else if let last = checker.lastCheckedAt {
            // 跟随系统当前语言格式化相对时间(此前写死 zh_CN,英文系统下这句仍会显示中文)。
            Text("已是最新（\(last.formatted(.relative(presentation: .named)))）")
                .foregroundStyle(.secondary)
        } else {
            Text("尚未检查").foregroundStyle(.secondary)
        }
    }
}
