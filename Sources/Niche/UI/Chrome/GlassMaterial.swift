import SwiftUI

/// 面板表面 = macOS 26 原生整窗 Liquid Glass,由窗口 `contentView` 的 `NSGlassEffectView`
/// 承担(见 PanelController),内容靠 vibrancy 直接坐其上、SwiftUI **不再叠任何背景** ——
/// 旧的 `NSVisualEffectView` + `masksToBounds` 是「边缘发糊发灰」的根:透明窗按半透内容
/// alpha 形状算阴影 → 糊成灰雾。改用 NSGlassEffectView 后内容层必须透明,玻璃才透得出来。
/// 仅无障碍降透明/增对比时换不透明纯色(此时玻璃本就不该透)。
struct PanelSurface: View {
    @EnvironmentObject private var motion: MotionPreferences

    var body: some View {
        if motion.prefersOpaque {
            Color(nsColor: .windowBackgroundColor)
        } else {
            Color.clear   // 窗面玻璃(NSGlassEffectView)透出,内容不盖底
        }
    }
}

extension View {
    /// 面板根视图背景:常态透明(让窗面玻璃透出),仅 a11y 降透明时填不透明色。
    func panelBackground() -> some View {
        background(PanelSurface())
    }
}
