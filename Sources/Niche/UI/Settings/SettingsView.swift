import SwiftUI
import AppKit

/// 设置页(spec §M5):绑定文件夹管理(增删/排序)、触发与快捷键、隐藏文件默认。
/// 宿主是自管 NSWindow(SettingsWindowController),注入面板同一个 PanelModel ——
/// showHidden 等偏好只有一个真相源,设置页改了面板立即生效,面板切了设置页同步显示。
struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var model: PanelModel
    /// 添加文件夹走 NicheController 统一路径(与面板「+」一致:自动选中新 tab)。
    var onAddFolder: () -> Void = {}

    var body: some View {
        TabView {
            FoldersSettings(onAddFolder: onAddFolder)
                .tabItem { Label("文件夹", systemImage: "folder") }
            GeneralSettings(model: model)
                .tabItem { Label("通用", systemImage: "gearshape") }
        }
        .frame(width: 480, height: 360)
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

    var body: some View {
        Form {
            Toggle("默认显示隐藏文件", isOn: $model.showHidden)
            LabeledContent("呼出快捷键", value: GlobalHotkey.displayString)
            LabeledContent("触发位置") {
                Text("刘海热区(无刘海回退顶部中央)+ 菜单栏图标 + 快捷键")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("提示:首次访问桌面/文稿/下载等受保护目录时,系统会弹出授权窗;授权后镜像才会实时同步。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }
}
