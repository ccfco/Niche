import SwiftUI

/// 面板表面背景 = 原生 `NSVisualEffectView`(访达/菜单/弹出框同款后置模糊材质),不是 SwiftUI
/// `.regularMaterial` —— 后者在杂乱壁纸上发灰发浊。`NSVisualEffectView` + `.behindWindow` 才是
/// 系统那种"通透干净"。圆角与锐利阴影由 PanelController 给窗口 contentView 图层做 masksToBounds。
/// 无障碍降级(降低透明度/增强对比度):换不透明纯色。
struct PanelSurface: View {
    @EnvironmentObject private var motion: MotionPreferences

    var body: some View {
        if motion.prefersOpaque {
            Color(nsColor: .windowBackgroundColor)
        } else {
            VisualEffectView(material: .menu)   // 干净浅色通透,浮层面板气质
        }
    }
}

/// 原生 NSVisualEffectView 包装:后置窗口模糊 + 系统材质。
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

extension View {
    /// 给面板根视图套原生 NSVisualEffectView 背景(圆角/阴影由窗口图层负责,这里只填材质)。
    func panelBackground() -> some View {
        background(PanelSurface())
    }
}
