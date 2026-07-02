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
            Toggle("刘海热区触发", isOn: $triggerPrefs.hotZoneEnabled)
            Picker("触发灵敏度", selection: $triggerPrefs.hoverDelay) {
                ForEach(TriggerPreferences.hoverDelayPresets, id: \.value) { preset in
                    Text(preset.label).tag(preset.value)
                }
            }
            // 延迟作用于所有 hover 触发(主热区/热角/边缘),任一开启就可调 —— 只绑主热区会出现
            // "只开热角时延迟在生效却改不了"。
            .disabled(!triggerPrefs.hotZoneEnabled
                      && triggerPrefs.enabledHotCorners.isEmpty
                      && triggerPrefs.enabledSides.isEmpty)
            LabeledContent("呼出快捷键") {
                HotkeyRecorderView(hotkey: $triggerPrefs.hotkey)
            }
        } footer: {
            Text("关闭热区后仍可用菜单栏图标或快捷键呼出。").settingsCaption()
        }

        Section {
            Slider(value: $triggerPrefs.hotZoneWidthScale, in: 0.6...2.0, step: 0.1) {
                Text("热区宽度")
            }
            .disabled(!triggerPrefs.hotZoneEnabled)
        } footer: {
            Text("仅影响无刘海屏幕的回退热区,真实刘海按物理宽度显示,不受此项影响。").settingsCaption()
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

/// 通用:显示隐藏文件、开机自启。直接绑面板 PanelModel(showHidden 单真相源,改了面板立即生效)。
struct GeneralSettings: View {
    @ObservedObject var model: PanelModel
    /// SMAppService 状态是系统侧真相,本地只留 UI 镜像;失败弹提示并回读真实状态(不静默)。
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    var body: some View {
        Section {
            // 与面板 eye 按钮同一真相源,改了立即生效 —— 不是"默认值",别写"默认"误导。
            Toggle("显示隐藏文件", isOn: $model.showHidden)
            // 图标视图名称下显副信息(分辨率/时长/项目数/大小),同访达「显示项目简介」。
            Toggle("显示项目简介(分辨率 / 时长 / 项目数)", isOn: $model.showItemInfo)
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
