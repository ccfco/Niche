import AppKit

/// 菜单栏图标 + 下拉菜单。提供"呼出 Niche / 设置… / 退出"等入口,并作为全局快捷键兜底
/// 之外的常驻可见触发点(spec §4.2:菜单栏图标是可选触发位置之一)。
@MainActor
final class MenuBarController {
    private let environment: AppEnvironment
    private let statusItem: NSStatusItem
    private let onToggle: () -> Void

    init(environment: AppEnvironment, onToggle: @escaping () -> Void) {
        self.environment = environment
        self.onToggle = onToggle
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()
        statusItem.menu = makeMenu()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = Self.makeIcon()
        button.image?.accessibilityDescription = "Niche"
    }

    /// 自绘菜单栏图标:深色「刘海梁」(顶边带中央凹口) + 蓝橙渐变下箭头——「从刘海滑出取用」的意象。
    /// 彩色图标 `isTemplate = false`:深/浅背景都显同一套色(不反色),故箭头用蓝橙渐变、刘海梁用中性深灰,
    /// 保证两种菜单栏背景下都有对比度。凹口用 `.clear` 掏空 alpha(缺口透出背景),渐变箭头先 clip 再 draw。
    private static func makeIcon() -> NSImage {
        let h: CGFloat = 18
        let image = NSImage(size: NSSize(width: h, height: h), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let r = rect.insetBy(dx: rect.width * 0.10, dy: rect.width * 0.10)

            // 刘海梁(深灰圆角横条)
            ctx.setFillColor(NSColor(white: 0.30, alpha: 1).cgColor)
            let beam = NSRect(x: r.minX + r.width * 0.10, y: r.maxY - r.height * 0.22,
                              width: r.width * 0.80, height: r.height * 0.20)
            ctx.addPath(CGPath(roundedRect: beam, cornerWidth: beam.height * 0.45,
                               cornerHeight: beam.height * 0.45, transform: nil))
            ctx.fillPath()

            // 顶边中央凹口 —— 掏空 alpha
            ctx.saveGState(); ctx.setBlendMode(.clear)
            let nW = r.width * 0.22, nH = beam.height * 0.7
            ctx.addPath(CGPath(roundedRect: CGRect(x: r.midX - nW / 2, y: beam.maxY - nH, width: nW, height: nH + 1),
                               cornerWidth: nH * 0.4, cornerHeight: nH * 0.4, transform: nil))
            ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath(); ctx.restoreGState()

            // 蓝→橙渐变下箭头(杆+头),先 clip 到箭头路径再画渐变
            let arrow = downArrowPath(cx: r.midX, topY: r.maxY - r.height * 0.30,
                                      botY: r.minY + r.height * 0.14, w: r.width * 0.44, shaft: 0.38)
            guard let grad = NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.55, blue: 1.0, alpha: 1),
                                                 NSColor(srgbRed: 1.0, green: 0.50, blue: 0.15, alpha: 1)]) else { return false }
            ctx.saveGState(); ctx.addPath(arrow); ctx.clip()
            grad.draw(in: r, angle: -90); ctx.restoreGState()
            return true
        }
        image.isTemplate = false // 彩色图标:不让系统按模板单色重绘
        return image
    }

    /// 下箭头(竖杆 + 倒三角头)路径,在以 cx 为中心、顶 topY、底 botY、总宽 w 的范围内;shaft 为杆宽占比。
    private static func downArrowPath(cx: CGFloat, topY: CGFloat, botY: CGFloat, w: CGFloat, shaft: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let total = topY - botY, headH = total * 0.55, shaftW = w * shaft
        p.addRect(CGRect(x: cx - shaftW / 2, y: botY + headH, width: shaftW, height: total - headH))
        p.move(to: CGPoint(x: cx - w / 2, y: botY + headH))
        p.addLine(to: CGPoint(x: cx + w / 2, y: botY + headH))
        p.addLine(to: CGPoint(x: cx, y: botY))
        p.closeSubpath()
        return p
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "呼出 Niche", action: #selector(togglePanel), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Niche", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func togglePanel() {
        onToggle()
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
