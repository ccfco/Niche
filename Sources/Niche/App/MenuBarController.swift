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
        button.image = Self.makeNotchIcon()
        button.image?.accessibilityDescription = "Niche"
    }

    /// 自绘菜单栏图标:横向 MacBook 刘海轮廓(宽扁圆角矩形 + 顶边中央凹口),描边风格。
    /// 用 `drawingHandler` 懒绘制天然适配 Retina/深浅色重绘;`isTemplate` 让系统只取 alpha 形状
    /// 自动上色——描边版的 alpha 是笔画像素带、墨量轻,和 wifi/电池等线性菜单栏邻居权重一致
    /// (实心填充块在一排线性图标里偏重、显突兀,故选描边)。
    /// 凹口走「统一带凹口轮廓路径」:把顶边中央的下凹缺口直接编进圆角矩形外轮廓,描边时缺口
    /// 自然显现,无需 `.clear` 掏空。`addArc(tangent1End:tangent2End:radius:)` 沿折线拐点自动倒角。
    /// 比例 1.18:1、凹口宽 30%/深 22%、描边 ~h*0.10,按 18pt 菜单栏高度调校,该尺寸下凹口仍清晰。
    private static func makeNotchIcon() -> NSImage {
        let h: CGFloat = 18
        let size = NSSize(width: h * 1.18, height: h)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let lineW = max(1.6, h * 0.10)
            let inset = lineW / 2 + h * 0.05
            let r = rect.insetBy(dx: inset, dy: inset)
            let c = r.width * 0.17
            let nW = r.width * 0.30, nH = r.height * 0.22
            let nx = r.midX - nW / 2
            let nc = min(nH * 0.4, c * 0.7)

            let outline = CGMutablePath()
            let start = CGPoint(x: r.midX, y: r.minY) // 底边中点起笔(底边无凹口,起点最稳)
            outline.move(to: start)
            // 顺时针拐点(x, y, 倒角半径);凹口四角用小半径 nc,屏幕四角用 c
            let corners: [(CGFloat, CGFloat, CGFloat)] = [
                (r.maxX, r.minY, c), (r.maxX, r.maxY, c),
                (nx + nW, r.maxY, nc), (nx + nW, r.maxY - nH, nc),
                (nx, r.maxY - nH, nc), (nx, r.maxY, nc),
                (r.minX, r.maxY, c), (r.minX, r.minY, c),
            ]
            for i in 0..<corners.count {
                let cur = CGPoint(x: corners[i].0, y: corners[i].1)
                let nxt = i + 1 < corners.count ? CGPoint(x: corners[i + 1].0, y: corners[i + 1].1) : start
                outline.addArc(tangent1End: cur, tangent2End: nxt, radius: corners[i].2)
            }
            outline.closeSubpath()

            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(lineW)
            ctx.addPath(outline)
            ctx.strokePath()
            return true
        }
        image.isTemplate = true
        return image
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
