import SwiftUI
import AppKit

/// 设置页(spec §M5):绑定文件夹管理(增删/排序)、触发与快捷键、隐藏文件默认。
struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        TabView {
            FoldersSettings()
                .tabItem { Label("文件夹", systemImage: "folder") }
            GeneralSettings()
                .tabItem { Label("通用", systemImage: "gearshape") }
        }
        .frame(width: 480, height: 360)
    }
}

private struct FoldersSettings: View {
    @EnvironmentObject private var environment: AppEnvironment

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
                            environment.bindingStore.remove(id: binding.id)
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                .onMove { source, dest in
                    environment.bindingStore.move(from: source, to: dest)
                }
            }
            .frame(minHeight: 180)

            Button { addFolder() } label: { Label("添加文件夹", systemImage: "plus") }
        }
        .padding()
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "添加"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bookmark = DirectoryMirror.makeBookmark(for: url)
        environment.bindingStore.add(FolderBinding(bookmarkData: bookmark, path: url.path))
    }
}

private struct GeneralSettings: View {
    @AppStorage("niche.showHidden") private var showHidden = false

    var body: some View {
        Form {
            Toggle("默认显示隐藏文件", isOn: $showHidden)
            LabeledContent("呼出快捷键", value: "⌥⌘Space")
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
