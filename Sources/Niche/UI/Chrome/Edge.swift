import CoreGraphics

/// Chrome 单旋钮(spec §4.5 / CLAUDE.md chrome 纪律):**间距/圆角由单一旋钮派生,
/// 禁止组件硬编码 padding/cornerRadius**。所有间距、圆角从 `base` 等比派生,达成统一
/// 的 Liquid Glass 节奏。组件只引用 `Edge` 的派生值,不写魔法数。
struct Edge: Equatable {
    /// 基准单位(pt)。改它,全局间距/圆角等比缩放。
    let base: CGFloat

    static let standard = Edge(base: 8)

    init(base: CGFloat) { self.base = base }

    /// 面板外缘内边距。
    var panelPadding: CGFloat { base * 1.5 }
    /// 网格条目之间的间距。
    var itemSpacing: CGFloat { base }
    /// 组件内部紧凑间距(图标-文字等)。
    var innerSpacing: CGFloat { base * 0.5 }
    /// 区块/底栏与内容的分隔间距。
    var sectionSpacing: CGFloat { base * 2 }

    /// 面板整体圆角(与刘海 continuous squircle 衔接)。
    var panelCornerRadius: CGFloat { base * 2.5 }
    /// 条目/卡片圆角。
    var itemCornerRadius: CGFloat { base * 1.25 }
    /// 控件(按钮/胶囊)圆角。
    var controlCornerRadius: CGFloat { base }
}
