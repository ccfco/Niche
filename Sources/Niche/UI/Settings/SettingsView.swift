import SwiftUI
import AppKit

/// 设置页(spec §M5):绑定文件夹管理(增删/排序)、触发与快捷键、隐藏文件默认。
/// 宿主是自管 NSWindow(SettingsWindowController),注入面板同一个 PanelModel ——
/// showHidden 等偏好只有一个真相源,设置页改了面板立即生效,面板切了设置页同步显示。
struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var model: PanelModel
    /// 触发方式偏好(热区/延迟/快捷键)单一真相源,由 NicheController 注入并订阅应用。
    @ObservedObject var triggerPrefs: TriggerPreferences
    /// 添加文件夹走 NicheController 统一路径(与面板「+」一致:自动选中新 tab)。
    var onAddFolder: () -> Void = {}

    var body: some View {
        TabView {
            FoldersSettings(onAddFolder: onAddFolder)
                .tabItem { Label("文件夹", systemImage: "folder") }
            GeneralSettings(model: model, triggerPrefs: triggerPrefs)
                .tabItem { Label("通用", systemImage: "gearshape") }
        }
        .frame(width: 480, height: 420)
    }
}

private struct FoldersSettings: View {
    @EnvironmentObject private var environment: AppEnvironment
    var onAddFolder: () -> Void = {}
    /// 待确认移除的绑定(误点 minus 无 undo,弹确认而非立即删)。
    @State private var pendingRemoval: FolderBinding?

    var body: some View {
        VStack(alignment: .leading) {
            Text("绑定文件夹").font(.headline)
            Text("从刘海滑出后,每个绑定文件夹是一个 tab。拖动可调整顺序。")
                .font(.caption).foregroundStyle(.secondary)

            List {
                ForEach(environment.bindingStore.bindings) { binding in
                    HStack {
                        Image(systemName: "folder")
                        VStack(alignment: .leading) {
                            Text(binding.displayName)
                            Text(binding.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            pendingRemoval = binding
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                .onMove { source, dest in
                    environment.bindingStore.move(from: source, to: dest)
                }
            }
            .frame(minHeight: 180)

            Button { onAddFolder() } label: { Label("添加文件夹", systemImage: "plus") }
        }
        .padding()
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
}

private struct GeneralSettings: View {
    /// 直接绑面板的 PanelModel:showHidden 单真相源(模型持久化到 UserDefaults),
    /// 不再用 @AppStorage 另起一份 —— 那会与面板 eye 按钮互相看不见(双真相源撕裂)。
    @ObservedObject var model: PanelModel
    @ObservedObject var triggerPrefs: TriggerPreferences
    /// SMAppService 状态是系统侧真相,本地只留 UI 镜像;失败弹提示并回读真实状态(不静默)。
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section {
                Toggle("默认显示隐藏文件", isOn: $model.showHidden)
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
            Section("触发") {
                Toggle("刘海热区触发", isOn: $triggerPrefs.hotZoneEnabled)
                Picker("触发灵敏度", selection: $triggerPrefs.hoverDelay) {
                    ForEach(TriggerPreferences.hoverDelayPresets, id: \.value) { preset in
                        Text(preset.label).tag(preset.value)
                    }
                }
                .disabled(!triggerPrefs.hotZoneEnabled)
                LabeledContent("呼出快捷键") {
                    HotkeyRecorderView(hotkey: $triggerPrefs.hotkey)
                }
                Text("关闭热区后仍可用菜单栏图标或快捷键呼出。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("提示:首次访问桌面/文稿/下载等受保护目录时,系统会弹出授权窗;授权后镜像才会实时同步。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
        .alert("无法更改开机自启", isPresented: Binding(
            get: { launchError != nil }, set: { if !$0 { launchError = nil } }
        )) {
            Button("好") { launchError = nil }
        } message: {
            Text(launchError ?? "")
        }
    }
}
