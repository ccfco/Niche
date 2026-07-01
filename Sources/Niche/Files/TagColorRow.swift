import AppKit

/// 右键菜单里的「外观行」—— 一排可点彩色圆点(标签色);文件夹再带一行「自定义文件夹」。
///
/// 复刻 Finder 原生标签行 + 自定义文件夹项,**整体自绘成一个 NSView**,且**不经 NSMenuItem 标题**——
/// 后者(借 item.title 显示 hover 提示)会因改标题触发 NSMenu 重算宽度而抖动 / 截断 / 文字跑位,
/// 是反复踩中的坑;自绘只 `needsDisplay` 重画、view 尺寸 init 时定死,从根上免疫,所以 hover 文字
/// 与"不抖动"本就能共存(把文字画在固定宽度视图内部即可)。
///
/// 对齐 = 镜像系统菜单的两条真实列(对齐其他菜单项):
/// - **文字列 `textColumnX`**:圆点左缘、「自定义文件夹」文字、hover 提示文字都落这一列(= 其他项文字起点)。
/// - **图标列 `iconColumnX`**:tag 图标落这一列(= 其他项 SF 图标起点,在文字列左侧)。
///
/// 交互:
/// - 圆点:hover 放大 + 画白 `+`(未打)/`×`(已打);非 hover 已打画白勾;点击 toggle 标签。
/// - hover 某圆点时,下方「自定义文件夹」行临时显示灰色「添加/移除 "X"」(对齐访达)。
/// - 「自定义文件夹」行(仅文件夹):hover 高亮 + 点击引导到访达。
@MainActor
final class TagColorRowView: NSView {
    private let tags: [(name: String, color: NSColor)]
    /// 当前选区"共有"的标签名(交集)→ 画勾。
    private let applied: Set<String>
    /// 点击某色回调(切换),宿主据此 add/remove。
    private let onToggle: (String) -> Void
    /// 非 nil = 文件夹:多画一行「自定义文件夹」并接管其点击;nil = 文件:仅圆点行。
    private let customize: (() -> Void)?

    private var hovered: Int?              // 当前 hover 的圆点 index
    private var hoveredCustomize = false   // 鼠标是否在「自定义文件夹」行

    // 几何。两条对齐系统菜单真实列(见类型注释):圆点左缘 / 文字 = 文字列;tag 图标 = 图标列。
    // ⚠️ 系统菜单的图标列 / 文字列 x 无公开 API 可查(NSMenuItemView 私有),只能按 macOS 实测值定,
    //    像素级跟随访达;换大版本若漂位,改这两个常量即可(单一旋钮,不散落各处)。
    private let iconColumnX: CGFloat = 20   // 图标列:tag 图标左缘,对齐其他项 SF 图标
    private let textColumnX: CGFloat = 41   // 文字列:圆点左缘 / 文字左缘,对齐其他项文字
    private let diameter: CGFloat = 13
    private let gap: CGFloat = 10
    private let hoverGrow: CGFloat = 2.5    // hover 时直径增量(放大感)
    private let dotRowH: CGFloat = 26       // 圆点行高度
    private let customizeRowH: CGFloat = 24 // 「自定义文件夹」行高度(仅文件夹)
    private let hPadding: CGFloat = 6       // 自定义行 hover 高亮的左右内缩
    private let trailingPad: CGFloat = 16   // 内容右侧留白(决定 view / 菜单宽度)

    /// 圆点中心 y(自底):文件夹时圆点在上半(让出下方自定义行),文件时居中单行。
    private var dotsCenterY: CGFloat { (customize == nil ? 0 : customizeRowH) + dotRowH / 2 }

    private static let menuFont = NSFont.menuFont(ofSize: 0)

    /// 系统字形染白(applied 标记 / hover 的 +、×)—— 用系统字形而非手画,边缘干净、和 Finder 一致。
    private static func whiteGlyph(_ symbol: String, pointSize: CGFloat) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return nil }
        return NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)   // 把模板字形染成白
            return true
        }
    }
    private static let whiteCheck = whiteGlyph("checkmark", pointSize: 9)
    private static let whitePlus = whiteGlyph("plus", pointSize: 11)
    private static let whiteCross = whiteGlyph("xmark", pointSize: 10)

    init(tags: [(name: String, color: NSColor)], applied: Set<String>,
         onToggle: @escaping (String) -> Void, customize: (() -> Void)? = nil) {
        self.tags = tags
        self.applied = applied
        self.onToggle = onToggle
        self.customize = customize
        let dotsWidth = textColumnX + CGFloat(tags.count) * diameter
            + CGFloat(max(0, tags.count - 1)) * gap + trailingPad
        // 文件夹:还要容纳「自定义文件夹…」文字宽度,取较大者当 view 宽(custom view 宽度即菜单宽度锚)。
        var width = dotsWidth
        if customize != nil {
            let textW = (String(localized: "自定义文件夹…") as NSString).size(withAttributes: [.font: Self.menuFont]).width
            width = max(width, textColumnX + textW + trailingPad)   // 文字列起 + 文字 + 右留白
        }
        let height = (customize == nil ? 0 : customizeRowH) + dotRowH
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    /// 第 i 个圆点的矩形(hover 时放大,中心不变)。
    private func circleRect(_ i: Int, hover: Bool) -> NSRect {
        let d = diameter + (hover ? hoverGrow : 0)
        let cx = textColumnX + diameter / 2 + CGFloat(i) * (diameter + gap)
        return NSRect(x: cx - d / 2, y: dotsCenterY - d / 2, width: d, height: d)
    }

    /// 命中:就近圆(带 slop,便于点中)。用非放大态矩形判定,避免放大后边界抖动。
    private func index(at point: NSPoint) -> Int? {
        for i in tags.indices where circleRect(i, hover: false).insetBy(dx: -gap / 2, dy: -4).contains(point) { return i }
        return nil
    }

    /// 「自定义文件夹」行矩形(自底 0..customizeRowH);仅文件夹有效。
    private var customizeRect: NSRect { NSRect(x: 0, y: 0, width: bounds.width, height: customizeRowH) }

    /// 第 i 个色点的 hover 提示串(对齐访达「添加/移除 "X"」)。
    private func hintText(_ i: Int) -> String {
        let name = tags[i].name
        let verb = applied.contains(name) ? String(localized: "移除") : String(localized: "添加")
        return "\(verb) \u{201C}\(name)\u{201D}"
    }

    /// 「自定义文件夹」行的标签图标(SF tag,染成 color;对齐访达该项的标签图标)。按色现生成,菜单重绘不频繁。
    private func tagIcon(_ color: NSColor) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        guard let base = NSImage(systemSymbolName: "tag", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return nil }
        return NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)   // 模板字形染成 color
            return true
        }
    }

    /// 在自定义行内垂直居中画一行文字。
    private func drawRowText(_ text: String, x: CGFloat, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.menuFont, .foregroundColor: color]
        let h = (text as NSString).size(withAttributes: attrs).height
        (text as NSString).draw(at: NSPoint(x: x, y: (customizeRowH - h) / 2), withAttributes: attrs)
    }

    override func draw(_ dirtyRect: NSRect) {
        // 上半:彩色圆点
        for (i, tag) in tags.enumerated() {
            let isHover = hovered == i
            let isApplied = applied.contains(tag.name)
            let r = circleRect(i, hover: isHover)

            tag.color.setFill()
            NSBezierPath(ovalIn: r).fill()

            // 极细描边圈:给浅色点(黄/灰)在浅菜单上以定义,深色点上几乎不可见。
            NSColor.black.withAlphaComponent(0.10).setStroke()
            let edge = NSBezierPath(ovalIn: r.insetBy(dx: 0.25, dy: 0.25))
            edge.lineWidth = 0.5
            edge.stroke()

            let glyph: NSImage? = isHover
                ? (isApplied ? Self.whiteCross : Self.whitePlus)
                : (isApplied ? Self.whiteCheck : nil)
            if let glyph {
                let s = glyph.size
                glyph.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
            }
        }

        // 下半:「自定义文件夹」行(仅文件夹)
        guard customize != nil else { return }
        let highlighted = hoveredCustomize && hovered == nil
        if highlighted {   // hover 该行:画系统选中高亮圆角(对齐菜单项 hover 观感)
            let bg = customizeRect.insetBy(dx: hPadding, dy: 2)
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bg, xRadius: 5, yRadius: 5).fill()
        }
        if let h = hovered {
            // hover 某圆点:灰色提示「添加/移除 "X"」,无图标,落文字列(对齐圆点左缘与下方文字)——对齐访达。
            drawRowText(hintText(h), x: textColumnX, color: .secondaryLabelColor)
        } else {
            // 平时:tag 图标 @ 图标列、「自定义文件夹…」文字 @ 文字列(各自对齐其他菜单项);高亮时白、平时 label。
            let fg: NSColor = highlighted ? .white : .labelColor
            if let icon = tagIcon(fg) {
                let isz = icon.size
                icon.draw(in: NSRect(x: iconColumnX, y: (customizeRowH - isz.height) / 2, width: isz.width, height: isz.height))
            }
            drawRowText(String(localized: "自定义文件夹…"), x: textColumnX, color: fg)
        }
    }

    // MARK: hover / 命中

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self))
    }

    private func updateHover(_ p: NSPoint) {
        let inCustomize = customize != nil && customizeRect.contains(p)
        let dot = inCustomize ? nil : index(at: p)
        if dot != hovered || inCustomize != hoveredCustomize {
            hovered = dot
            hoveredCustomize = inCustomize
            needsDisplay = true
        }
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil || hoveredCustomize {
            hovered = nil; hoveredCustomize = false; needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // 先关菜单再回调:Finder 语义点即应用并收起;关菜单驱动 auto-hide 抑制正常解除。
        // 自定义行优先判定,与 updateHover 一致 —— 不依赖圆点 slop 与自定义行之间的几何余量。
        if customize != nil, customizeRect.contains(p) {
            enclosingMenuItem?.menu?.cancelTracking()
            customize?()
        } else if let i = index(at: p) {
            enclosingMenuItem?.menu?.cancelTracking()
            onToggle(tags[i].name)
        }
    }
}
