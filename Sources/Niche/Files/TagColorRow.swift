import AppKit

/// 右键菜单里的「一排可点彩色圆点」—— 复刻 Finder 原生标签行(主菜单内直接点色 toggle)。
///
/// 复刻的细节(对齐访达):
/// - 已打标签:圆点画白勾。
/// - hover 未打的:圆点**放大** + 画白 `+`。
/// - hover 已打的:圆点**放大** + 白勾转白 `×`。
/// - 点击即 toggle 并收起菜单。
///
/// 为何自绘 NSView:NSMenu 没有"内联多按钮行"的现成项,Finder 也是用自定义视图项实现这排圆点。
@MainActor
final class TagColorRowView: NSView {
    private let tags: [(name: String, color: NSColor)]
    /// 当前选区"共有"的标签名(交集)→ 画勾。
    private let applied: Set<String>
    /// 点击某色回调(切换),宿主据此 add/remove。
    private let onToggle: (String) -> Void

    private var hovered: Int?

    // 几何。只有一行圆点(已去掉 hover 文字行),行高 = 圆点 + 上下留白。
    private let inset: CGFloat = 17
    private let diameter: CGFloat = 16
    private let gap: CGFloat = 11
    private let hoverGrow: CGFloat = 3      // hover 时直径增量(放大感)
    private let dotsCenterY: CGFloat = 14   // 圆点中心 y(自底),行内垂直居中
    private let totalHeight: CGFloat = 28   // 仅一行圆点 + 上下留白

    /// 系统字形染白(applied 标记 / hover 的 +、×)—— 用系统字形而非手画,边缘才干净、和 Finder 一致。
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

    init(tags: [(name: String, color: NSColor)], applied: Set<String>, onToggle: @escaping (String) -> Void) {
        self.tags = tags
        self.applied = applied
        self.onToggle = onToggle
        let width = inset * 2 + CGFloat(tags.count) * diameter + CGFloat(max(0, tags.count - 1)) * gap
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: totalHeight))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    /// 第 i 个圆点的矩形(hover 时放大,中心不变)。
    private func circleRect(_ i: Int, hover: Bool) -> NSRect {
        let d = diameter + (hover ? hoverGrow : 0)
        let cx = inset + diameter / 2 + CGFloat(i) * (diameter + gap)
        return NSRect(x: cx - d / 2, y: dotsCenterY - d / 2, width: d, height: d)
    }

    /// 命中:就近圆(带 slop,便于点中)。用非放大态矩形判定,避免放大后边界抖动。
    private func index(at point: NSPoint) -> Int? {
        for i in tags.indices where circleRect(i, hover: false).insetBy(dx: -gap / 2, dy: -4).contains(point) { return i }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, tag) in tags.enumerated() {
            let isHover = hovered == i
            let isApplied = applied.contains(tag.name)
            let r = circleRect(i, hover: isHover)

            // 彩色实心圆。
            tag.color.setFill()
            NSBezierPath(ovalIn: r).fill()

            // 极细描边圈:给浅色点(黄/灰)在浅菜单上以定义,深色点上几乎不可见。
            NSColor.black.withAlphaComponent(0.10).setStroke()
            let edge = NSBezierPath(ovalIn: r.insetBy(dx: 0.25, dy: 0.25))
            edge.lineWidth = 0.5
            edge.stroke()

            // 中心字形:hover 未打→+,hover 已打→×,非 hover 已打→√,其余无。
            let glyph: NSImage? = isHover
                ? (isApplied ? Self.whiteCross : Self.whitePlus)
                : (isApplied ? Self.whiteCheck : nil)
            if let glyph {
                let s = glyph.size
                glyph.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2,
                                      width: s.width, height: s.height))
            }
        }
    }

    // MARK: hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let i = index(at: convert(event.locationInWindow, from: nil))
        if i != hovered { hovered = i; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil { hovered = nil; needsDisplay = true }
    }

    // MARK: 点击

    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        // 先关菜单再回调:Finder 语义点色即应用并收起;关菜单驱动 auto-hide 抑制正常解除。
        enclosingMenuItem?.menu?.cancelTracking()
        onToggle(tags[i].name)
    }
}
