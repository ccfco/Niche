import CoreGraphics

/// 面板呼出锚点:触发源在哪,面板就从哪长出。统一驱动三件事——目标 frame(贴触发处)、
/// 生长/收回的细条(动画起点与终点)、走廊矩形(auto-hide 的 keep-alive 区,和面板 frame 取
/// union)。快捷键/菜单栏呼出沿用 .top(顶部中央),行为与历史一致。
///
/// 纯几何、可单测;坐标系按 AppKit 全局坐标(原点左下)。
enum PanelAnchor: Equatable {
    /// 刘海/顶部回退热区(rect = NotchGeometry Resolution.rect):居中贴顶,向下长出。
    case top(CGRect)
    /// 热角:面板贴该角显示,从角落长出。
    case corner(ScreenCorner, CGRect)
    /// 边缘触发:面板从该边、鼠标所在位置滑出(Dock/Slidepad 语义:哪里触发哪里出)。
    case side(ScreenSide, mouse: CGPoint)

    /// 目标 frame:贴锚点、夹取进可视区(visible = NSScreen.visibleFrame,避开菜单栏/Dock)。
    func targetFrame(panelSize: CGSize, visible: CGRect) -> CGRect {
        let w = panelSize.width, h = panelSize.height
        switch self {
        case let .top(rect):
            // 与历史 standardFrame 完全一致:刘海正下方居中,顶边贴刘海底。
            return CGRect(x: rect.midX - w / 2, y: rect.minY - h, width: w, height: h)
        case let .corner(corner, _):
            let x = (corner == .topLeft || corner == .bottomLeft) ? visible.minX : visible.maxX - w
            let y = (corner == .bottomLeft || corner == .bottomRight) ? visible.minY : visible.maxY - h
            return CGRect(x: x, y: y, width: w, height: h)
        case let .side(side, mouse):
            switch side {
            case .top:
                return CGRect(x: clampX(mouse.x - w / 2, w: w, visible: visible),
                              y: visible.maxY - h, width: w, height: h)
            case .bottom:
                return CGRect(x: clampX(mouse.x - w / 2, w: w, visible: visible),
                              y: visible.minY, width: w, height: h)
            case .left:
                return CGRect(x: visible.minX,
                              y: clampY(mouse.y - h / 2, h: h, visible: visible), width: w, height: h)
            case .right:
                return CGRect(x: visible.maxX - w,
                              y: clampY(mouse.y - h / 2, h: h, visible: visible), width: w, height: h)
            }
        }
    }

    /// 生长起点 / 收回终点:目标 frame 贴锚一侧的细条(窗口裁切露出玻璃,零 morph,同 present 机制)。
    func collapsedFrame(target: CGRect) -> CGRect {
        let t: CGFloat = 6
        switch self {
        case let .top(rect):
            // 与历史一致:刘海宽的小条,顶边贴面板顶。
            return CGRect(x: rect.midX - rect.width / 2, y: target.maxY - t, width: rect.width, height: t)
        case let .corner(corner, _):
            let s: CGFloat = 24
            let x = (corner == .topLeft || corner == .bottomLeft) ? target.minX : target.maxX - s
            let y = (corner == .bottomLeft || corner == .bottomRight) ? target.minY : target.maxY - s
            return CGRect(x: x, y: y, width: s, height: s)
        case let .side(side, _):
            switch side {
            case .top: return CGRect(x: target.minX, y: target.maxY - t, width: target.width, height: t)
            case .bottom: return CGRect(x: target.minX, y: target.minY, width: target.width, height: t)
            case .left: return CGRect(x: target.minX, y: target.minY, width: t, height: target.height)
            case .right: return CGRect(x: target.maxX - t, y: target.minY, width: t, height: target.height)
            }
        }
    }

    /// 走廊矩形(auto-hide keep-alive = 面板 frame ∪ 此矩形;union 是外接矩形,自动填平面板与
    /// 物理边之间的缝隙,如 Dock 高度)。
    func corridorRect(target: CGRect, screenFrame: CGRect) -> CGRect {
        switch self {
        case let .top(rect), let .corner(_, rect):
            return rect
        case let .side(side, _):
            // 从物理边到面板近边、横跨面板宽/高的一条(鼠标停在边上时仍在走廊内)。
            switch side {
            case .top:
                return CGRect(x: target.minX, y: target.maxY,
                              width: target.width, height: max(screenFrame.maxY - target.maxY, 4))
            case .bottom:
                return CGRect(x: target.minX, y: screenFrame.minY,
                              width: target.width, height: max(target.minY - screenFrame.minY, 4))
            case .left:
                return CGRect(x: screenFrame.minX, y: target.minY,
                              width: max(target.minX - screenFrame.minX, 4), height: target.height)
            case .right:
                return CGRect(x: target.maxX, y: target.minY,
                              width: max(screenFrame.maxX - target.maxX, 4), height: target.height)
            }
        }
    }

    /// 高度变化时的生长方向:底部锚定(下边缘/下角)保持底边不动向上长,其余保持顶边不动(现状)。
    var growsUpward: Bool {
        switch self {
        case .corner(.bottomLeft, _), .corner(.bottomRight, _), .side(.bottom, _): return true
        default: return false
        }
    }

    private func clampX(_ x: CGFloat, w: CGFloat, visible: CGRect) -> CGFloat {
        min(max(x, visible.minX), visible.maxX - w)
    }
    private func clampY(_ y: CGFloat, h: CGFloat, visible: CGRect) -> CGFloat {
        min(max(y, visible.minY), visible.maxY - h)
    }
}
