import SwiftUI

/// 网格视图(spec §4.4)。M1:只读展示 + 选中态 + 双击打开;键盘导航走 PanelModel。
struct FileGridView: View {
    @ObservedObject var model: PanelModel
    let edge: EdgeMetrics
    /// 双击/Return 打开条目(由上层接系统 API)。
    var onOpen: (FileItem) -> Void = { _ in }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: edge.itemSpacing)],
                      spacing: edge.itemSpacing) {
                ForEach(Array(model.sortedItems.enumerated()), id: \.element.id) { index, item in
                    FileCellView(item: item, isSelected: model.selection.index == index, edge: edge)
                        .onTapGesture(count: 2) { onOpen(item) }
                        .onTapGesture { model.selection = GridSelection(index: index) }
                }
            }
            .padding(edge.panelPadding)
        }
        .overlay {
            if model.sortedItems.isEmpty {
                EmptyStateView(kind: .empty)
            }
        }
    }
}
