import SwiftUI
import UniformTypeIdentifiers

/// 网格视图(spec §4.4)。展示 + 选中 + 双击打开/下钻 + 拖出 + 右键 + 就地重命名 + 拖入落地。
struct FileGridView: View {
    @ObservedObject var model: PanelModel
    let edge: EdgeMetrics
    var actions = PanelActions()

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: edge.itemSpacing)],
                      spacing: edge.itemSpacing) {
                ForEach(Array(model.sortedItems.enumerated()), id: \.element.id) { index, item in
                    cell(index: index, item: item)
                }
            }
            .padding(edge.panelPadding)
        }
        .overlay {
            if model.sortedItems.isEmpty {
                EmptyStateView(kind: .empty)
            }
        }
        // 拖入落地:Niche 自己执行 copy/move(读修饰键 + 卷判定,spec §4.5 注②)。
        .onDrop(of: [.fileURL], delegate: FileDropDelegate(onDrop: actions.onDropURLs))
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
            }
        )
        .onTapGesture(count: 2) { activate(item) }
        .onTapGesture { model.selection = GridSelection(index: index) }
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
