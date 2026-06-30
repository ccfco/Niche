import SwiftUI
import AppKit

// 设置页四个内容分区。脱离系统 `Form.formStyle(.grouped)` 的灰卡,改为透明坐窗面玻璃上、
// 文字层级分组(SettingsPane/SettingsGroup),与面板同一套视觉语言。各区单一职责一个文件好定位。

/// 文件夹:绑定文件夹的增删与排序。**保留 `List + .onMove`** 拿系统拖拽排序语义(不自研),
/// 仅 `.scrollContentBackground(.hidden)` + `.plain` 抹掉系统底色,让玻璃透出。
struct FoldersSettings: View {
    @EnvironmentObject private var environment: AppEnvironment
    var onAddFolder: () -> Void = {}
    /// 待确认移除的绑定(误点删除无 undo,弹确认而非立即删)。
    @State private var pendingRemoval: FolderBinding?
    private let edge = EdgeMetrics.standard

    var body: some View {
        SettingsPane(title: SettingsSection.folders.title) {
            SettingsFootnote("从刘海滑出后,每个绑定文件夹是一个 tab。拖动可调整顺序。")

            List {
                ForEach(environment.bindingStore.bindings) { binding in
                    bindingRow(binding)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: edge.innerSpacing, leading: 0,
                                                  bottom: edge.innerSpacing, trailing: 0))
                }
                .onMove { source, dest in
                    environment.bindingStore.move(from: source, to: dest)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)   // 抹掉系统列表底,露出窗面玻璃
            .frame(maxHeight: .infinity)         // 吃满内容区剩余高度,文件夹多时在固定窗口内滚动(不撑破窗口)

            Button { onAddFolder() } label: {
                Label("添加文件夹…", systemImage: "plus")
            }
            .buttonStyle(NicheFooterGlassButtonStyle(compact: true))
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
        HStack(spacing: edge.itemSpacing) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {   // 名称↔副路径紧贴,纯排版微距(< base*0.5),同 footerHoverRimInset 刻意不挂 base
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
            .help("移除此文件夹")
            .accessibilityLabel("移除「\(binding.displayName)」")
        }
    }
}

/// 触发:刘海热区开关、hover 灵敏度、全局快捷键。从旧 GeneralSettings 拆出独立成页。
struct TriggerSettings: View {
    @ObservedObject var triggerPrefs: TriggerPreferences
    private let edge = EdgeMetrics.standard

    var body: some View {
        SettingsPane(title: SettingsSection.trigger.title) {
            SettingsGroup {
                Toggle("刘海热区触发", isOn: $triggerPrefs.hotZoneEnabled)
                Picker("触发灵敏度", selection: $triggerPrefs.hoverDelay) {
                    ForEach(TriggerPreferences.hoverDelayPresets, id: \.value) { preset in
                        Text(preset.label).tag(preset.value)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!triggerPrefs.hotZoneEnabled)
                LabeledContent("呼出快捷键") {
                    HotkeyRecorderView(hotkey: $triggerPrefs.hotkey)
                }
            }
            SettingsFootnote("关闭热区后仍可用菜单栏图标或快捷键呼出。")
        }
    }
}

/// 通用:显示隐藏文件、开机自启。直接绑面板 PanelModel(showHidden 单真相源,改了面板立即生效)。
struct GeneralSettings: View {
    @ObservedObject var model: PanelModel
    /// SMAppService 状态是系统侧真相,本地只留 UI 镜像;失败弹提示并回读真实状态(不静默)。
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    var body: some View {
        SettingsPane(title: SettingsSection.general.title) {
            SettingsGroup {
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
            }
            SettingsFootnote("首次访问桌面/文稿/下载等受保护目录时,系统会弹出授权请求;允许后镜像才会实时同步。")
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

/// 关于:版本、自动更新、更新状态与下载。
struct AboutSettings: View {
    @ObservedObject private var checker = UpdateChecker.shared
    private let edge = EdgeMetrics.standard

    /// 版权(读 Info.plist NSHumanReadableCopyright,不在 UI 硬编码年份 —— 年份会过时)。
    private var copyright: String? {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
    }

    var body: some View {
        SettingsPane(title: SettingsSection.about.title) {
            SettingsGroup {
                LabeledContent("当前版本") {
                    Text("Niche \(checker.currentVersion)")
                        .foregroundStyle(.secondary)
                }
                Toggle("自动检查更新", isOn: Binding(
                    get: { checker.autoCheckEnabled },
                    set: { checker.setAutoCheckEnabled($0) }
                ))
            }

            SettingsGroup(header: "更新") {
                LabeledContent("状态") { updateStatusView }
                if let release = checker.latestRelease {
                    HStack(spacing: edge.itemSpacing) {
                        Button("安装更新") { checker.installUpdate() }
                            .buttonStyle(NicheFooterGlassButtonStyle(compact: true))
                        Button("查看 Release") { checker.openReleasePage() }
                            .buttonStyle(.borderless)
                    }
                    SettingsFootnote("Niche \(release.displayVersion) 已可安装（一键自动安装）。")
                } else {
                    Button("立即检查") { checker.checkNow() }
                        .buttonStyle(NicheFooterGlassButtonStyle(compact: true))
                        .disabled(checker.isChecking)
                }
            }

            SettingsGroup(header: "项目") {
                LabeledContent("开源仓库") {
                    Link("github.com/ccfco/Niche",
                         destination: URL(string: "https://github.com/ccfco/Niche")!)
                }
                LabeledContent("许可") {
                    Text("MIT").foregroundStyle(.secondary)
                }
            }
            if let copyright {
                SettingsFootnote(copyright)
            }
        }
    }

    @ViewBuilder private var updateStatusView: some View {
        if checker.isChecking {
            HStack(spacing: edge.innerSpacing) {
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
            Text("已是最新（\(last.formatted(.relative(presentation: .named).locale(Locale(identifier: "zh_CN"))))）")
                .foregroundStyle(.secondary)
        } else {
            Text("尚未检查").foregroundStyle(.secondary)
        }
    }
}
