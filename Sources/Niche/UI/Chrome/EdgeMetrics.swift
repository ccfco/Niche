import CoreGraphics

/// Chrome 单旋钮(spec §4.5 / CLAUDE.md chrome 纪律):**间距/圆角由单一旋钮派生,
/// 禁止组件硬编码 padding/cornerRadius**。所有间距、圆角从 `base` 等比派生,达成统一
/// 的 Liquid Glass 节奏。组件只引用 `EdgeMetrics` 的派生值,不写魔法数。
struct EdgeMetrics: Equatable {
    /// 基准单位(pt)。改它,全局间距/圆角等比缩放。
    let base: CGFloat

    static let standard = EdgeMetrics(base: 8)

    init(base: CGFloat) { self.base = base }

    /// 面板外缘内边距。
    var panelPadding: CGFloat { base * 1.5 }
    /// 网格条目之间的间距。
    var itemSpacing: CGFloat { base }
    /// 组件内部紧凑间距(图标-文字等)。
    var innerSpacing: CGFloat { base * 0.5 }
    /// 区块/底栏与内容的分隔间距。
    var sectionSpacing: CGFloat { base * 2 }

    /// 面板外壳圆角(= NSGlassEffectView.cornerRadius = 窗面玻璃 shell)。
    /// base*3=24:贴近系统浮层(Control Center 16),且与底栏按钮 cornerControl(16)
    /// 同心 —— shell(24) = control(16) + gap(8)。借鉴 Clipin cornerShell。
    var panelCornerRadius: CGFloat { base * 3 }
    /// 条目/卡片圆角。
    var itemCornerRadius: CGFloat { base * 1.25 }
    /// 控件(按钮/胶囊)圆角。
    var controlCornerRadius: CGFloat { base }

    // MARK: 底栏玻璃按钮(同心圆体系,借鉴 Clipin)
    // 同心仅在「内层比外层正好内缩一个 gap」时成立:shell(24)−gap(8)=control(16)。
    // 故底栏按钮须用 base*2 圆角、并距面板边 gap(=itemSpacing 8),才与窗角同心。

    /// 底栏玻璃按钮圆角。base*2=16,与外壳 24 同心(24−8)。
    var footerControlCornerRadius: CGFloat { base * 2 }
    /// 按钮 hover 高亮相对玻璃边的内缩量 —— 高亮比按钮小一圈、露一圈玻璃 rim。
    /// 纯渲染细节,远小于最小网格单位,刻意不挂 base。
    var footerHoverRimInset: CGFloat { 2 }

    /// 网格单元目标宽度。网格列数计算与面板标准宽度共用同一来源(禁两处魔法数 84)。
    var cellWidth: CGFloat { base * 10.5 }   // 8 * 10.5 = 84
}
