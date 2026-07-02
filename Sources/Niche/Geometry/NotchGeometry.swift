import CoreGraphics

/// 刘海几何推导(spec §4.2:无"刘海 rect"直接 API,靠 safeAreaInsets + auxiliaryTopLeft/Right
/// 自行推导)。纯函数,可单测;坐标系按 AppKit 全局坐标(原点左下,top = maxY)。
enum NotchGeometry {
    /// 推导结果:有刘海 → 刘海矩形;无刘海 → 顶部中央回退矩形。
    enum Resolution: Equatable {
        /// 真实刘海矩形(用于热区贴合刘海)。
        case notch(CGRect)
        /// 无刘海:顶部中央回退矩形(spec §4.2:外接屏无 notch 回退顶部中央)。
        case fallbackTopCenter(CGRect)

        /// 取出矩形(不关心来源时)。
        var rect: CGRect {
            switch self {
            case let .notch(r), let .fallbackTopCenter(r): return r
            }
        }
        var hasNotch: Bool {
            if case .notch = self { return true }
            return false
        }
    }

    /// 由屏幕与安全区参数推导。
    /// - Parameters:
    ///   - screenFrame: 屏幕 frame(全局坐标,原点左下)。
    ///   - safeAreaTop: 顶部被遮挡厚度(`NSScreen.safeAreaInsets.top`);有刘海时 > 0。
    ///   - auxiliaryLeftWidth / auxiliaryRightWidth: 刘海两侧可用区宽度
    ///     (`auxiliaryTopLeftArea?.width` / `auxiliaryTopRightArea?.width`);无刘海为 nil。
    ///   - menubarHeight: 菜单栏高度,作为无刘海回退矩形的高度。
    ///   - widthScale: 无刘海回退矩形的宽度缩放(设置页滑杆,默认 1.0)。真实刘海宽度贴合物理刘海,
    ///     不受此项影响 —— 缩放只解决"大外接屏上固定宽度显得窄"这一件事。
    static func resolve(
        screenFrame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryLeftWidth: CGFloat?,
        auxiliaryRightWidth: CGFloat?,
        menubarHeight: CGFloat,
        widthScale: CGFloat = 1.0
    ) -> Resolution {
        // 有刘海的判据:两侧 aux 宽度均存在且 safeAreaTop > 0。
        if let left = auxiliaryLeftWidth, let right = auxiliaryRightWidth, safeAreaTop > 0 {
            let notchWidth = screenFrame.width - left - right
            if notchWidth > 0 {
                let rect = CGRect(
                    x: screenFrame.midX - notchWidth / 2,
                    y: screenFrame.maxY - safeAreaTop,
                    width: notchWidth,
                    height: safeAreaTop
                )
                return .notch(rect)
            }
        }

        // 无刘海:顶部中央回退,宽度按屏宽比例算(16%,夹在 160~480pt 之间防止小屏太窄/大屏离谱宽),
        // 再乘用户滑杆缩放;高度取菜单栏高度(至少 1pt 防退化)。
        let baseWidth = min(max(screenFrame.width * 0.16, 160), 480)
        let fallbackWidth = baseWidth * widthScale
        let height = max(menubarHeight, 1)
        let rect = CGRect(
            x: screenFrame.midX - fallbackWidth / 2,
            y: screenFrame.maxY - height,
            width: fallbackWidth,
            height: height
        )
        return .fallbackTopCenter(rect)
    }

    /// 由刘海/回退矩形派生"触发热区"矩形:横向略放宽、纵向覆盖到菜单栏底,便于 hover/拖拽命中。
    /// 热区不能太大以免误触,也不能只贴刘海以致难命中 —— 这里横向各扩 `horizontalPadding`。
    static func hotZoneRect(from resolution: Resolution, horizontalPadding: CGFloat = 12) -> CGRect {
        let base = resolution.rect
        return base.insetBy(dx: -horizontalPadding, dy: 0)
    }
}
