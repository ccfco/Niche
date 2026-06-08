import SwiftUI
import UniformTypeIdentifiers

/// 列表视图(spec:迷你访达列表)。用 SwiftUI `Table` —— 底层即 `NSTableView`,与访达列表同源。
/// 列:名称(图标+名)/ 大小 / 种类。原生单击选中、双击打开/下钻、拖出即走、右键菜单、就地重命名。
struct FileListView: View {
    @ObservedObject var model: PanelModel
    let edge: EdgeMetrics
    var actions = PanelActions()

    var body: some View {
        Table(model.sortedItems, selection: selectionBinding) {
            TableColumn("名称") { item in nameCell(item) }
            TableColumn("大小") { item in
                Text(sizeLabel(item)).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 64, ideal: 72, max: 96)
            TableColumn("种类") { item in
                Text(kindLabel(item)).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 72, ideal: 96, max: 140)
        }
        // 关隔行背景:访达列表是纯白行 + 极细分隔;隔行底色会把行界读成"更粗更深的分割线"。
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)   // 让窗面玻璃透出,Table 不盖一层不透明底
    }

    // 选中态在 model.selection(index)与 Table(by id)之间双向映射。
    private var selectionBinding: Binding<FileItem.ID?> {
        Binding(
            get: {
                guard let idx = model.selection.index, model.sortedItems.indices.contains(idx) else { return nil }
                return model.sortedItems[idx].id
            },
            set: { id in
                if let id, let idx = model.sortedItems.firstIndex(where: { $0.id == id }) {
                    model.selection = GridSelection(index: idx)
                } else {
                    model.selection = GridSelection(index: nil)
                }
            }
        )
    }

    @ViewBuilder private func nameCell(_ item: FileItem) -> some View {
        HStack(spacing: edge.innerSpacing) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable().frame(width: 16, height: 16)
            if model.renamingItemID == item.id {
                RenameTextField(
                    initialName: item.name,
                    onCommit: { if actions.onRename(item.url, $0) { model.endRename() } },
                    onCancel: { model.endRename() }
                )
            } else {
                Text(item.name).lineLimit(1).truncationMode(.middle)
            }
            if item.isDataless {
                Image(systemName: "icloud.and.arrow.down").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        // 双击打开/下钻(Table 原生单击负责选中,叠加双击手势不冲突)。
        .simultaneousGesture(TapGesture(count: 2).onEnded { activate(item) })
        // 拖出真实 file URL。拖拽 session 中 .mouseMoved 静默,面板不收;松手后在外才收(拖出即走)。
        .draggable(item.url)
        .contextMenu {
            Button("打开") { actions.onOpen(item) }
            Button("重命名") { model.beginRename(item.url) }
            Divider()
            Button("拷贝路径") { actions.onCopyPath([item.url]) }
            Button("移到废纸篓", role: .destructive) { actions.onTrash([item.url]) }
        }
    }

    private func activate(_ item: FileItem) {
        if item.isDirectory {
            model.currentMirror?.enter(item.url)
            model.selection = GridSelection(index: nil)
        } else {
            actions.onOpen(item)
        }
    }

    private func sizeLabel(_ item: FileItem) -> String {
        item.isDirectory ? "--" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
    }

    private func kindLabel(_ item: FileItem) -> String {
        item.contentType?.localizedDescription ?? (item.isDirectory ? "文件夹" : "文件")
    }
}
