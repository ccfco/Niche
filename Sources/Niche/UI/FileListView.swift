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
        // 显式 rows + TableRow.itemProvider:走 NSTableView 原生行拖拽 —— 拖已选中行 = 拖**整组
        // 选中**(每行各自的 provider,真实 file URL),与图标模式 DragSourceView 的多选拖出等价。
        // 此前 nameCell 上挂 .draggable(item.url) 只能拖单项,违反「两模式行为等价」。
        Table(of: FileItem.self, selection: multiSelectionBinding, sortOrder: sortBinding) {
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
        } rows: {
            ForEach(model.sortedItems) { item in
                TableRow(item)
                    .itemProvider { NSItemProvider(object: item.url as NSURL) }
            }
        }
        // 关隔行背景:访达列表是纯白行 + 极细分隔;隔行底色会把行界读成"更粗更深的分割线"。
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)   // 让窗面玻璃透出,Table 不盖一层不透明底
        .focused($tableFocused)
        .onAppear { tableFocused = true }
        // 拖入落地 + 实时角标(与图标模式等价):落点 = 当前目录。
        .onDrop(of: [.fileURL], delegate: FileDropDelegate(
            onDrop: actions.onDropURLs,
            targetDirectory: { model.currentMirror?.currentDirectory }
        ))
        // 空文件夹空态(与图标模式等价):overlay 而非替换 Table —— Table 的 onDrop 保持活跃,
        // 空文件夹仍可拖入文件。
        .overlay {
            if model.sortedItems.isEmpty {
                EmptyStateView(kind: .empty)
            }
        }
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

    // 列表多选:直接用 Table 原生 Set selection(⌘ 离散 / ⇧ 区间 / ⌘A 全选 / 点空白清空均原生);
    // set 回写镜像到模型并据增量推断光标(供 Quick Look / 激活)。
    private var multiSelectionBinding: Binding<Set<FileItem.ID>> {
        Binding(
            get: { model.selectedIDs },
            set: { ids in model.syncListSelection(ids) }
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
                // 列表用尾部省略(中间省略在窄列表里读着怪)+ 全名 tooltip(#17)。
                Text(item.name).lineLimit(1).truncationMode(.tail).help(item.name)
            }
            if model.downloadingIDs.contains(item.id) {
                ProgressView().controlSize(.small)   // dataless 按需下载中(#13)
            } else if item.isDataless {
                Image(systemName: "icloud.and.arrow.down").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        // 双击打开/下钻(Table 原生单击负责选中,叠加双击手势不冲突)。
        .simultaneousGesture(TapGesture(count: 2).onEnded { activate(item) })
        // 拖出由 TableRow.itemProvider 承担(原生多选拖整组);拖拽 session 中 .mouseMoved 静默,
        // 面板不收;松手后在外才收(拖出即走)。
        // 右键:与图标模式同款 RightClickCatcher → ContextMenuBuilder(13 项),菜单 delegate
        // 驱动 .contextMenu auto-hide 抑制(菜单期间面板不收)。弃用阉割版 SwiftUI .contextMenu(#3)。
        // RightClickCatcher 只认领右键/control-左键,左键(原生选中/双击/拖出)透传不冲突。
        .overlay(RightClickCatcher(makeMenu: { anchor in
            // 右键未选中的行 → 单选它;已在多选内 → 保留多选(Finder 语义:菜单作用于整组选中)。
            if !model.selectedIDs.contains(item.id) { model.selectSingle(item.id) }
            return actions.onContextMenu(model.selectionURLs, anchor)
        }))
    }

    private func activate(_ item: FileItem) {
        if item.isDirectory {
            model.currentMirror?.enter(item.url)
            model.clearSelection()
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
