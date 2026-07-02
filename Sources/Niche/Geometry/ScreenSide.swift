import CoreGraphics

/// 屏幕四边(边缘触发用)。不叫 `Edge`——撞 SwiftUI.Edge(CLAUDE.md 命名避坑)。
enum ScreenSide: String, CaseIterable, Codable {
    case top, bottom, left, right

    var title: String {
        switch self {
        case .top: return String(localized: "上边缘")
        case .bottom: return String(localized: "下边缘")
        case .left: return String(localized: "左边缘")
        case .right: return String(localized: "右边缘")
        }
    }

    /// 整条边的命中细条(全局坐标,原点左下),thickness 贴物理边。
    func stripRect(in screenFrame: CGRect, thickness: CGFloat = 4) -> CGRect {
        switch self {
        case .top:
            return CGRect(x: screenFrame.minX, y: screenFrame.maxY - thickness,
                          width: screenFrame.width, height: thickness)
        case .bottom:
            return CGRect(x: screenFrame.minX, y: screenFrame.minY,
                          width: screenFrame.width, height: thickness)
        case .left:
            return CGRect(x: screenFrame.minX, y: screenFrame.minY,
                          width: thickness, height: screenFrame.height)
        case .right:
            return CGRect(x: screenFrame.maxX - thickness, y: screenFrame.minY,
                          width: thickness, height: screenFrame.height)
        }
    }
}
