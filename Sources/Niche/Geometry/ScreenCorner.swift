import CoreGraphics

/// 屏幕四角热角(对齐 macOS 原生 Hot Corners 心智,系统设置里就有同款交互,复用用户已有习惯)。
/// 热角只做 hover 触发,不支持拖拽迎上(同原生 Hot Corners 一样不支持拖拽) —— 见 HotZoneController。
enum ScreenCorner: String, CaseIterable, Codable {
    case topLeft, topRight, bottomLeft, bottomRight

    var title: String {
        switch self {
        case .topLeft: return String(localized: "左上角")
        case .topRight: return String(localized: "右上角")
        case .bottomLeft: return String(localized: "左下角")
        case .bottomRight: return String(localized: "右下角")
        }
    }

    /// 命中矩形(全局坐标,原点左下)。size 是正方形边长,贴着屏幕物理角落。
    func rect(in screenFrame: CGRect, size: CGFloat = 16) -> CGRect {
        let x = self == .topLeft || self == .bottomLeft ? screenFrame.minX : screenFrame.maxX - size
        let y = self == .bottomLeft || self == .bottomRight ? screenFrame.minY : screenFrame.maxY - size
        return CGRect(x: x, y: y, width: size, height: size)
    }
}
