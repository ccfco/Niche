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
    /// 慢速单击重命名的延迟任务(列表模式无法接管原生选中,只能借 @State + 延迟兜底,与图标模式
    /// DragSourceNSView 的计时器同义)。双击的第二击会取消它,改走 activate。
    @State private var pendingRename: DispatchWorkItem?

    var body: some View {
        // 显式 rows + TableRow.itemProvider:走 NSTableView 原生行拖拽 —— 拖已选中行 = 拖**整组
        // 选中**(每行各自的 provider,真实 file URL),与图标模式 DragSourceView 的多选拖出等价。
        // 此前 nameCell 上挂 .draggable(item.url) 只能拖单项,违反「两模式行为等价」。
        Table(of: FileItem.self, selection: multiSelectionBinding, sortOrder: sortBinding) {
            TableColumn("名称", value: \.name) { item in nameCell(item) }
            // 次列也挂右键/双击(secondaryCell):右键/双击不该只在名称列生效——图标模式整格
            // 可右键,列表只覆盖名称列即违反「两模式行为等价」(Codex review)。
            TableColumn("大小", value: \.size) { item in
                secondaryCell(item) { Text(sizeLabel(item)).foregroundStyle(.secondary).monospacedDigit() }
            }
            .width(min: 64, ideal: 72, max: 96)
            TableColumn("种类", value: \.kindSortKey) { item in
                secondaryCell(item) { Text(kindLabel(item)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .width(min: 72, ideal: 96, max: 140)
            // 修改日期列(访达列表标配):让 .date 排序态在表头有列可表示,底栏菜单与表头不撕裂。
            TableColumn("修改日期", value: \.modificationDate) { item in
                secondaryCell(item) { Text(dateLabel(item)).foregroundStyle(.secondary).lineLimit(1) }
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
        // 目录行是更内层的独立落点(cell 上的 onDrop),此处只接落到空白/非目录行的拖入。
        .onDrop(of: [.fileURL], delegate: FileDropDelegate(
            onDrop: { actions.onDropURLs($0, $1, nil) },
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

    /// 目录行 = 独立拖入落点(与图标模式文件夹格子等价)。一行四列各是独立 drop region,
    /// 共写 model.dropTargetID(计数式)→ 四列同步高亮,看起来是整行高亮。非目录不拦,
    /// 拖入穿透到 Table 外层(落当前目录)。
    @ViewBuilder private func folderDropTarget<Content: View>(
        _ item: FileItem, @ViewBuilder content: () -> Content
    ) -> some View {
        let highlighted = content()
            .background(model.dropTargetID == item.id
                        ? Color.accentColor.opacity(GlassTokens.selectionFill) : Color.clear)
        if item.isDirectory {
            highlighted.onDrop(of: [.fileURL], delegate: FileDropDelegate(
                onDrop: { actions.onDropURLs($0, $1, item.url) },
                targetDirectory: { item.url },
                onTargeted: { model.setDropTarget(item.id, targeted: $0) }
            ))
        } else {
            highlighted
        }
    }

    @ViewBuilder private func nameCell(_ item: FileItem) -> some View {
        folderDropTarget(item) { nameCellContent(item) }
    }

    @ViewBuilder private func nameCellContent(_ item: FileItem) -> some View {
        HStack(spacing: edge.innerSpacing) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable().frame(width: 16, height: 16)
                .accessibilityHidden(true)   // 装饰性类型图标,种类列已承载语义
            if model.renamingItemID == item.id {
                RenameTextField(
                    initialName: item.name,
                    onCommit: { if actions.onRename(item.url, $0) { model.endRename() } },
                    // 仅当 renamingItemID 仍是本项才结束:Tab 跳邻项后旧框拆除的 onCancel 不误清新目标。
                    onCancel: { if model.renamingItemID == item.url { model.endRename() } },
                    // 失焦提交(点面板内别处):Finder 失焦=保存;无效名静默还原,总是结束。
                    onEndEditing: { newName in
                        guard model.renamingItemID == item.url else { return }
                        _ = actions.onRename(item.url, newName)
                        model.endRename()
                    },
                    onTab: { newName, offset in
                        let neighbor = model.neighborURL(of: item.url, offset: offset)
                        if actions.onRename(item.url, newName) {
                            model.endRename()
                            if let neighbor {
                                // 移动选中到邻项(匹配 Finder + 让原生 Table 把该行带进视区使改名框挂载/夺焦,#2)。
                                model.selectSingle(neighbor)
                                model.beginRename(neighbor)
                            }
                        }
                    }
                )
            } else {
                // 列表用尾部省略(中间省略在窄列表里读着怪)+ 全名 tooltip(#17)。
                // 慢速单击重命名只挂在文字上(Finder:点类型图标只选中,点文件名文字才改名);
                // contentShape 让文字整块可命中。
                Text(item.name).lineLimit(1).truncationMode(.tail).help(item.name)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture(count: 1).onEnded { scheduleListRename(item) })
            }
            if model.downloadingIDs.contains(item.id) {
                ProgressView().controlSize(.small)   // dataless 按需下载中(#13)
            } else if item.isDataless {
                Image(systemName: "icloud.and.arrow.down").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        // 双击打开/下钻(Table 原生单击负责选中,叠加双击手势不冲突;activate 内会取消挂起的重命名)。
        // 慢速单击重命名不挂整行,只挂上面的 Text(Finder:点文件名文字才改名,点图标只选中)。
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

    /// 次列(大小/种类/日期)单元包装:补与名称列等价的双击激活 + 右键菜单 + 目录行拖入落点
    /// (整行可右键/可落入,与图标模式整格等价)。
    @ViewBuilder private func secondaryCell<Content: View>(
        _ item: FileItem, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        folderDropTarget(item) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture(count: 2).onEnded { activate(item) })
                .overlay(RightClickCatcher(makeMenu: { anchor in
                    if !model.selectedIDs.contains(item.id) { model.selectSingle(item.id) }
                    return actions.onContextMenu(model.selectionURLs, anchor)
                }))
        }
    }

    private func activate(_ item: FileItem) {
        pendingRename?.cancel(); pendingRename = nil   // 双击打开 = 放弃慢速单击重命名(任意列双击都经此)
        if item.isDirectory {
            model.currentMirror?.enter(item.url)
            model.clearSelection()
        } else {
            actions.onOpen(item)
        }
    }

    /// 慢速单击重命名:仅当点中"已是唯一选中行"才触发(Finder 语义;首次点击选中、再点才重命名)。
    /// 延迟一个双击间隔,期间来双击则被 count:2 取消,无双击且仍唯一选中才真正进重命名。
    private func scheduleListRename(_ item: FileItem) {
        // 双击的第二击 clickCount=2 直接拦掉(借系统 clickCount,与图标模式同源):否则双击已选中
        // 文件时第二击的单击手势可能晚于 activate 重新排期 → 打开后又进重命名。
        guard (NSApp.currentEvent?.clickCount ?? 1) == 1 else { return }
        // 必须「点击前就已唯一选中本项」(快照),否则首次点击选中行会被误判成再次点击进重命名。
        guard model.selectionAtMouseDown == [item.id],
              model.selectedIDs == [item.id], model.renamingItemID == nil else { return }
        pendingRename?.cancel()
        let token = model.renameArmToken   // 捕获代次:面板收起会自增,触发时比对失效(防泄漏 .renaming 抑制)
        let work = DispatchWorkItem {
            pendingRename = nil
            // 触发时二次确认仍是唯一选中本项(期间双击/切走 → 放弃),与图标模式的二次校验对称;
            // 并比对代次——面板已收起则放弃,不在隐藏后置 renamingItemID(Codex review)。
            if model.renameArmToken == token, model.selectedIDs == [item.id], model.renamingItemID == nil {
                model.beginRename(item.url)
            }
        }
        pendingRename = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
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
