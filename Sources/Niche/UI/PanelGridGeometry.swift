import CoreGraphics

/// 图标网格与面板宿主共用的几何 authority。
///
/// 文件名可读宽度是硬约束，列数是派生结果：屏幕变窄或图标变大时先减列，禁止为了维持
/// 固定列数继续压缩名称。PanelController 用它算窗口尺寸/行数，FileGridView 用它画真实列数，
/// 两边必须始终调用同一公式，否则键盘跨行和面板高度会与画面脱节。
enum PanelGridGeometry {
    static let preferredColumns = 6

    static func minimumCellWidth(edge: EdgeMetrics) -> CGFloat {
        edge.base * 14   // 112pt；扣除两层 4pt 内边距后，文件名仍约有 96pt。
    }

    static func cellWidthFloor(iconSize: CGFloat, edge: EdgeMetrics) -> CGFloat {
        max(minimumCellWidth(edge: edge), iconSize + edge.base * 4)
    }

    static func preferredPanelWidth(edge: EdgeMetrics) -> CGFloat {
        CGFloat(preferredColumns) * minimumCellWidth(edge: edge)
            + CGFloat(preferredColumns - 1) * edge.itemSpacing
            + edge.panelPadding * 2
    }

    /// 常见屏幕取 736pt；窄屏保留 16pt 双侧余量并让列数自然下降，绝不越过可视区。
    static func panelWidth(visibleWidth: CGFloat, edge: EdgeMetrics) -> CGFloat {
        let fitsScreen = max(1, visibleWidth - edge.sectionSpacing * 2)
        return min(preferredPanelWidth(edge: edge), fitsScreen)
    }

    static func columnCount(panelWidth: CGFloat, iconSize: CGFloat, edge: EdgeMetrics) -> Int {
        let usable = max(1, panelWidth - edge.panelPadding * 2)
        let floor = cellWidthFloor(iconSize: iconSize, edge: edge)
        return max(1, Int((usable + edge.itemSpacing) / (floor + edge.itemSpacing)))
    }
}
