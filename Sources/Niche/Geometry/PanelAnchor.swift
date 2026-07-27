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

    /// 触发去重意义上的「同锚点」(纯函数,回归测试钉住):present 的幂等守卫只吞同锚点重复触发
    /// (hover 进面板再回刘海的重复跨界),异触发区 = 用户想让面板挪过去,必须重新 present。
    /// 判等只比「面板会落在哪」的决定要素,不比整个携带值:
    /// - `.top` 只比 midX/minY(targetFrame 只用这两项;widthScale 调宽热区不挪面板,不算异锚点);
    /// - `.side` 忽略鼠标位置(同一条边即同锚点,鼠标微移不该反复重放动画)。
    /// 本函数不含屏幕身份(`.side`/`.corner` 携带值区分不了异屏同侧/同角),
    /// 异屏判定由 `shouldSwallowTrigger` 比对屏 frame 承担,两者必须配套使用。
    static func isSameTriggerTarget(_ a: PanelAnchor, _ b: PanelAnchor) -> Bool {
        switch (a, b) {
        case let (.top(r1), .top(r2)): return r1.midX == r2.midX && r1.minY == r2.minY
        case let (.side(sideA, _), .side(sideB, _)): return sideA == sideB
        default: return a == b
        }
    }

    /// 触发到达时是否该吞掉(纯函数,回归测试钉住):
    /// - 无已展开瞬态(含收回动画中,anchor 传 nil)→ 不吞(收回中重触发 = 把面板叫回来);
    /// - 已展开但脱锚(unpin 回瞬态后 lastAnchor 为 nil)→ 吞,热区触发不把浮着的面板拽回锚点;
    /// - 已展开且有锚 → 仅「同屏 + 同锚点」吞,异屏/异触发区重新 present 把面板挪过去
    ///   (修「跨屏呼出被吞、面板滞留旧屏」;屏幕身份靠 frame 比对,锚点携带值不含它)。
    static func shouldSwallowTrigger(
        current: (anchor: PanelAnchor?, screenFrame: CGRect)?,
        target: PanelAnchor, targetScreenFrame: CGRect
    ) -> Bool {
        guard let current else { return false }
        guard let anchor = current.anchor else { return true }
        return current.screenFrame == targetScreenFrame && isSameTriggerTarget(anchor, target)
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
