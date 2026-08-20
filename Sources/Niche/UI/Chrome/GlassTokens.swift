import SwiftUI

/// 面板内部状态层强度的单一来源。外壳承担玻璃，内部 chrome 与文件条目只画轻量状态底。
enum GlassTokens {
    /// 工具栏按钮三态：按下 > 激活 > hover > 静止。
    static let pressed: Double = 0.12
    static let active: Double = 0.09
    static let hover: Double = 0.055

    /// 条目 hover 只提供方向感；整格强调色只留给真正的拖放目标。
    static let hoverFill: Double = 0.035
    static let dropTargetFill: Double = 0.14
    /// 文件名本身的选中 / 展开状态，避免把图标、元信息一起包成大卡片。
    static let filenameSelectionFill: Double = 0.22
    static let filenameHoverFill: Double = 0.07

    /// 玻璃按钮静止态强度(无叠加)。
    static let idle: Double = 0
}
