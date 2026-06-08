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
                // 键盘移动光标 → 滚动跟随,保持光标项可见(spec §4.7 手感)。
                .onChange(of: model.cursorIndex) { _, index in
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
        // 点空白处取消选中(#6):最底层透明命中层,只接落空的左键,不抢 cell(cell 在上层)。
        .background(
            Color.clear.contentShape(Rectangle()).onTapGesture { model.clearSelection() }
        )
        // 空白处右键 → 背景菜单(新建文件夹/粘贴)。置于内容之下:cell 自带 RightClickCatcher 在上层
        // 优先认领落到条目上的右键,gap/空白处的右键穿透到此(catcher 只认右键,不挡左键/拖入)。
        .background(RightClickCatcher(makeMenu: { actions.onContextMenuBackground($0) }))
        // 拖入落地:Niche 自己执行 copy/move(读修饰键 + 卷判定,spec §4.5 注②);实时角标见 dropUpdated。
        .onDrop(of: [.fileURL], delegate: FileDropDelegate(
            onDrop: actions.onDropURLs,
            targetDirectory: { model.currentMirror?.currentDirectory }
        ))
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
            isSelected: model.selectedIDs.contains(item.id),
            isRenaming: model.renamingItemID == item.id,
            edge: edge,
            onRenameCommit: { newName in
                // 失败(空名/非法字符)保持编辑态(Codex review)。
                if actions.onRename(item.url, newName) { model.endRename() }
            },
            onRenameCancel: { model.endRename() },
            makeContextMenu: { anchor in
                // 右键未选中的项 → 单选它;已在多选内 → 保留多选(菜单作用于整组)。
                if !model.selectedIDs.contains(item.id) { model.selectSingle(item.id) }
                return actions.onContextMenu(model.selectionURLs, anchor)
            },
            onClick: { flags in handleClick(item.id, flags) },
            onActivate: { activate(item) },
            onDragBegin: actions.onDragBegin,
            onDragEnd: actions.onDragEnd,
            // 拖已选中项 → 拖整组多选;拖未选中项 → 仅该项(Finder 语义)。
            dragURLs: { model.selectedIDs.contains(item.id) ? model.selectionURLs : [item.url] }
        )
    }

    /// 图标模式点击选中:⌘ 离散切换 / ⇧ 区间 / 普通单选(对齐 Finder;列表由原生 Table 处理)。
    private func handleClick(_ id: FileItem.ID, _ flags: NSEvent.ModifierFlags) {
        if flags.contains(.command) { model.toggle(id) }
        else if flags.contains(.shift) { model.selectRange(to: id) }
        else { model.selectSingle(id) }
    }

    private func activate(_ item: FileItem) {
        if item.isDirectory {
            model.currentMirror?.enter(item.url)
            model.clearSelection()
        } else {
            actions.onOpen(item)
        }
    }
}

/// 拖入处理:从 providers 取 file URL,读当前修饰键,交宿主执行(宿主据当前目录算卷/语义)。
/// dropUpdated 实时返回 copy/move 角标(#9):拖拽期间 file URL 通常可从拖拽专用剪贴板同步读到 →
/// 据「同卷/跨卷 + 修饰键」算操作,与访达一致;读不到(如 file promise)按 copy;目标不可写 forbidden。
struct FileDropDelegate: DropDelegate {
    let onDrop: (_ urls: [URL], _ modifiers: NSEvent.ModifierFlags) -> Void
    /// 落点目录(算同卷/跨卷与可写判定)。
    var targetDirectory: () -> URL? = { nil }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    /// 实时角标:⌥ 复制 / ⌘ 移动(修饰键优先);无修饰按同卷 move、跨卷 copy;目标不可写 forbidden。
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let dir = targetDirectory() else {
            return DropProposal(operation: .copy)   // 无落点信息:保守 copy(不静默移动)
        }
        // dropUpdated 随鼠标高频触发:按「拖拽剪贴板 changeCount + 目标目录」缓存卷判定 + 可写性,
        // 整段拖拽期间命中即 O(1),避免每次都 readObjects + 逐源查卷 + access(Codex review)。
        let (writable, sameVolume) = DropPreflightCache.shared.resolve(dir: dir)
        // 目标不可写 → 禁止落入(与访达只读目录的禁止角标一致;写保护执行层 ensureWritable 仍兜底)。
        guard writable else { return DropProposal(operation: .forbidden) }
        switch DragSemantics.resolve(sameVolume: sameVolume, modifiers: NSEvent.modifierFlags) {
        case .copy: return DropProposal(operation: .copy)
        case .move: return DropProposal(operation: .move)
        }
    }

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

/// 拖入角标预判缓存:dropUpdated 随鼠标高频触发,而拖拽来源(剪贴板)与目标目录在整段拖拽里
/// 通常不变。按「拖拽剪贴板 changeCount + 目标目录路径」缓存(可写性, 同卷判定),命中即免去重复
/// readObjects + 逐源 resourceValues + access(Codex review)。拖拽串行且事件在主线程,单例够用。
private final class DropPreflightCache {
    static let shared = DropPreflightCache()

    private var changeCount = Int.min
    private var dirPath = ""
    private var cached: (writable: Bool, sameVolume: Bool?) = (true, nil)

    func resolve(dir: URL) -> (writable: Bool, sameVolume: Bool?) {
        let pb = NSPasteboard(name: .drag)
        let cc = pb.changeCount
        if cc == changeCount, dir.path == dirPath { return cached }

        let writable = FileManager.default.isWritableFile(atPath: dir.path)
        let sources = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        let sameVolume = aggregateSameVolume(sources: sources, dir: dir)

        changeCount = cc
        dirPath = dir.path
        cached = (writable, sameVolume)
        return cached
    }

    /// 混合来源保守判定:任一跨卷 → false(整体 copy);全同卷 → true(move);含未知/空 → nil(copy)。
    private func aggregateSameVolume(sources: [URL], dir: URL) -> Bool? {
        guard !sources.isEmpty else { return nil }
        let results = sources.map { DragSemantics.isSameVolume($0, dir) }
        if results.contains(false) { return false }
        if results.allSatisfy({ $0 == true }) { return true }
        return nil
    }
}
