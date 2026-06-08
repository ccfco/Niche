import SwiftUI
import UniformTypeIdentifiers

/// 列表视图(spec:迷你访达列表)。用 SwiftUI `Table` —— 底层即 `NSTableView`,与访达列表同源。
/// 列:名称(图标+名)/ 大小 / 种类。原生单击选中、双击打开/下钻、拖出即走、右键菜单、就地重命名。
struct FileListView: View {
    @ObservedObject var model: PanelModel
    let edge: EdgeMetrics
    var actions = PanelActions()
    /// 让 Table 成为第一响应者:PanelController 的 keyDown monitor 把列表方向键**放行**给响应链,
    /// 由原生 NSTableView 做 ∓1 导航 + 自动滚动到可见 + 回写选中 binding(#1)。
    @FocusState private var tableFocused: Bool

    var body: some View {
        Table(model.sortedItems, selection: selectionBinding, sortOrder: sortBinding) {
            TableColumn("名称", value: \.name) { item in nameCell(item) }
            TableColumn("大小", value: \.size) { item in
                Text(sizeLabel(item)).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 64, ideal: 72, max: 96)
            TableColumn("种类", value: \.kindSortKey) { item in
                Text(kindLabel(item)).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 72, ideal: 96, max: 140)
            // 修改日期列(访达列表标配):让 .date 排序态在表头有列可表示,底栏菜单与表头不撕裂。
            TableColumn("修改日期", value: \.modificationDate) { item in
                Text(dateLabel(item)).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 96, ideal: 116, max: 150)
        }
        // 关隔行背景:访达列表是纯白行 + 极细分隔;隔行底色会把行界读成"更粗更深的分割线"。
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)   // 让窗面玻璃透出,Table 不盖一层不透明底
        .focused($tableFocused)
        .onAppear { tableFocused = true }
    }

    /// 表头排序桥接:get 把真相源 FileSortOrder 映射为 Table 排序描述子(驱动表头箭头);
    /// set 把用户点表头产生的 comparator 写回 model.sortOrder(真实重排由 model.sortedItems
    /// 的 FileSortOrder.comparator 负责,保留「目录恒前」)。底栏菜单与表头共写同一真相源,自动同步。
    private var sortBinding: Binding<[KeyPathComparator<FileItem>]> {
        Binding(
            get: { [model.sortOrder.tableComparator] },
            set: { comparators in
                guard let first = comparators.first else { return }
                model.sortOrder.apply(first)
            }
        )
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
        // 右键:与图标模式同款 RightClickCatcher → ContextMenuBuilder(13 项),菜单 delegate
        // 驱动 .contextMenu auto-hide 抑制(菜单期间面板不收)。弃用阉割版 SwiftUI .contextMenu(#3)。
        // RightClickCatcher 只认领右键/control-左键,左键(原生选中/双击/拖出)透传不冲突。
        .overlay(RightClickCatcher(makeMenu: { anchor in
            // 右键先选中该行(原生 Table 右键不自动选中,因 catcher 已拦截);确保菜单作用于正确条目。
            if let idx = model.sortedItems.firstIndex(where: { $0.id == item.id }) {
                model.selection = GridSelection(index: idx)
            }
            return actions.onContextMenu([item.url], anchor)
        }))
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

    /// 修改日期:短日期 + 短时间(随系统区域),distantPast(读取失败)显 "--"。
    private func dateLabel(_ item: FileItem) -> String {
        guard item.modificationDate > .distantPast else { return "--" }
        return item.modificationDate.formatted(date: .numeric, time: .shortened)
    }
}
