import SwiftUI

/// 玻璃三态高亮强度的单一来源(chrome 纪律延伸:不止间距/圆角,**叠加高亮的 opacity 也禁组件
/// 各写魔法数**)。此前 0.25/0.22/0.16/0.12/0.09 散落在 FooterGlassButtonStyle / FolderTabsView /
/// FileCellView,改值要四处找。收口到此:三态强度统一,玻璃语言一致(#16)。
enum GlassTokens {
    /// 玻璃按钮叠加 `Color.primary` 的三态强度:按下 > 激活(常驻高亮)> hover > 静止(0)。
    static let pressed: Double = 0.16
    static let active: Double = 0.12
    static let hover: Double = 0.09

    /// 条目选中态填充(强调色 tint,像访达蓝选中);hover 提示用更淡的中性灰。
    static let selectionFill: Double = 0.18
    static let hoverFill: Double = 0.08

    /// 玻璃按钮静止态强度(无叠加)。
    static let idle: Double = 0
}
