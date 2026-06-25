import AppKit
import SwiftUI

/// 下钻路径栏(#7/#8):给纯鼠标用户「我在哪」的可见位置 + 逐级回跳路径(竞品主力是纯鼠标)。
/// 仅在下钻后(canGoUp)显示;左侧「↑ 上级」玻璃按钮,右侧面包屑各段可点跳转,末段(当前)高亮不可点。
struct BreadcrumbBar: View {
    let components: [(name: String, url: URL)]
    let edge: EdgeMetrics
    var onUp: () -> Void = {}
    var onSelect: (URL) -> Void = { _ in }
    /// 段右键:对该祖先目录构建文件夹引用菜单(复制路径 / 在 Finder 中显示 / 显示简介);nil 不弹。
    /// 末段(当前目录)左键不可点,但右键可操作 —— 路径脊柱任意段一致。
    var onSegmentMenu: (URL) -> NSMenu? = { _ in nil }

    var body: some View {
        HStack(spacing: edge.innerSpacing) {
            Button(action: onUp) { Image(systemName: "chevron.up") }
                .buttonStyle(NicheFooterGlassButtonStyle(compact: true))
                .help("回上级目录")
                .accessibilityLabel("回上级目录")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: edge.innerSpacing) {
                    ForEach(Array(components.enumerated()), id: \.offset) { index, comp in
                        if index > 0 {
                            Image(systemName: "chevron.compact.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)   // 纯装饰分隔符
                        }
                        segment(name: comp.name, url: comp.url, isLast: index == components.count - 1)
                    }
                }
            }
        }
        .padding(.horizontal, edge.panelPadding)
        .padding(.vertical, edge.innerSpacing)
    }

    private func segment(name: String, url: URL, isLast: Bool) -> some View {
        Button { onSelect(url) } label: {
            Text(name)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(isLast ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .disabled(isLast)   // 当前目录不可点(已在此)
        // 右键:文件夹引用操作(末段不可左键点但可右键,路径脊柱任意段一致)。
        .overlay(RightClickCatcher { _ in onSegmentMenu(url) })
        .help(name)
        .accessibilityLabel(isLast ? "当前目录 \(name)" : "跳转到 \(name)")
    }
}
