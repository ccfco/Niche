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
        // 末段(当前目录)= 纯标签而非 Button:左键天然不可点、无障碍不报"可激活按钮"。不用
        // `.disabled(isLast)` 抑制一个 Button —— `.disabled` 会把 isEnabled=false 传导给随后的
        // `.overlay`,可能让 RightClickCatcher 静默收不到右键(末段右键就废了);用结构分叉根治。
        Group {
            if isLast {
                Text(name).foregroundStyle(.primary)
            } else {
                Button { onSelect(url) } label: { Text(name).foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .font(.caption)
        .lineLimit(1)
        // 右键:文件夹引用操作(路径脊柱任意段一致,末段亦可右键;overlay 在 disabled 语义之外)。
        .overlay(RightClickCatcher { _ in onSegmentMenu(url) })
        .help(name)
        .accessibilityLabel(isLast ? "当前目录 \(name)" : "跳转到 \(name)")
    }
}
