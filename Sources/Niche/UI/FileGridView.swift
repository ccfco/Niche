import SwiftUI
import UniformTypeIdentifiers

/// 网格视图(spec §4.4)。展示 + 选中 + 双击打开/下钻 + 拖出 + 右键 + 就地重命名 + 拖入落地。
struct FileGridView: View {
    @ObservedObject var model: PanelModel
    @EnvironmentObject private var motion: MotionPreferences
    let edge: EdgeMetrics
    var actions = PanelActions()

    var body: some View {
        GeometryReader { geo in
            let columns = columnCount(for: geo.size.width)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: gridItems(columns), spacing: edge.itemSpacing) {
                        ForEach(Array(model.sortedItems.enumerated()), id: \.element.id) { index, item in
                            cell(index: index, item: item)
                                .id(index)
                        }
                    }
                    .padding(edge.panelPadding)
                }
                // 列数变化(resize)→ 回填 model,使键盘跨行移动与真实布局一致。
                .onChange(of: columns, initial: true) { _, new in model.columns = new }
                // 键盘移动选中 → 滚动跟随,保持选中项可见(spec §4.7 手感)。
                .onChange(of: model.selection.index) { _, index in
                    guard let index else { return }
                    // Reduce Motion:滚动瞬时到位,不做动画(spec §4.3 非可选)。
                    if motion.reduceMotion {
                        proxy.scrollTo(index, anchor: .center)
                    } else {
                        withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(index, anchor: .center) }
                    }
                }
            }
        }
        .overlay {
            if model.sortedItems.isEmpty {
                EmptyStateView(kind: .empty)
            }
        }
        // 空白处右键 → 背景菜单(新建文件夹/粘贴)。置于内容之下:cell 自带 RightClickCatcher 在上层
        // 优先认领落到条目上的右键,gap/空白处的右键穿透到此(catcher 只认右键,不挡左键/拖入)。
        .background(RightClickCatcher(makeMenu: { actions.onContextMenuBackground($0) }))
        // 拖入落地:Niche 自己执行 copy/move(读修饰键 + 卷判定,spec §4.5 注②)。
        .onDrop(of: [.fileURL], delegate: FileDropDelegate(onDrop: actions.onDropURLs))
    }

    private func columnCount(for width: CGFloat) -> Int {
        let usable = width - edge.panelPadding * 2
        let unit = edge.cellWidth + edge.itemSpacing
        return max(1, Int((usable + edge.itemSpacing) / unit))
    }

    private func gridItems(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: edge.itemSpacing), count: count)
    }

    private func cell(index: Int, item: FileItem) -> some View {
        FileCellView(
            item: item,
            isSelected: model.selection.index == index,
            isRenaming: model.renamingItemID == item.id,
            edge: edge,
            onRenameCommit: { newName in
                // 失败(空名/非法字符)保持编辑态(Codex review)。
                if actions.onRename(item.url, newName) { model.endRename() }
            },
            onRenameCancel: { model.endRename() },
            makeContextMenu: { anchor in
                model.selection = GridSelection(index: index)
                return actions.onContextMenu([item.url], anchor)
            },
            onSelect: { model.selection = GridSelection(index: index) },
            onActivate: { activate(item) },
            onDragBegin: actions.onDragBegin,
            onDragEnd: actions.onDragEnd
        )
    }

    private func activate(_ item: FileItem) {
        if item.isDirectory {
            model.currentMirror?.enter(item.url)
            model.selection = GridSelection(index: nil)
        } else {
            actions.onOpen(item)
        }
    }
}

/// 拖入处理:从 providers 取 file URL,读当前修饰键,交宿主执行(宿主据当前目录算卷/语义)。
struct FileDropDelegate: DropDelegate {
    let onDrop: (_ urls: [URL], _ modifiers: NSEvent.ModifierFlags) -> Void

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        let modifiers = NSEvent.modifierFlags

        // loadObject 回调在任意队列;用串行队列保护汇总数组,避免数据竞争(Codex review)。
        let lock = DispatchQueue(label: "com.ccfco.Niche.drop")
        var collected: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.sync { collected.append(url) } }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = lock.sync { collected }
            guard !urls.isEmpty else { return }
            onDrop(urls, modifiers)
        }
        return true
    }
}
