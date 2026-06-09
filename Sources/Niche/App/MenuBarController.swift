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

    /// 自绘菜单栏图标:实心「刘海剪影」——MacBook 屏幕顶部中央那块标志性下凸区。
    /// 这是 Niche 的本体符号(产品就叫"刘海原生"),单色实心在 18pt 必然清晰,且一眼是刘海、
    /// 不会被误认成下载/文件夹。形状=顶部贴边小圆角、底部两角大圆角的下凸块;`isTemplate` 单色自适应。
    private static func makeIcon() -> NSImage {
        let h: CGFloat = 18
        let image = NSImage(size: NSSize(width: h * 1.15, height: h), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let W = rect.width * 0.74, H = rect.height * 0.64
            let x0 = rect.midX - W / 2
            let topY = rect.maxY - rect.height * 0.10
            let botY = topY - H
            let rTop = max(1.2, rect.width * 0.07)
            let rBot = rect.width * 0.34
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x0 + rTop, y: topY))
            p.addArc(tangent1End: CGPoint(x: x0 + W, y: topY), tangent2End: CGPoint(x: x0 + W, y: botY), radius: rTop)
            p.addArc(tangent1End: CGPoint(x: x0 + W, y: botY), tangent2End: CGPoint(x: x0, y: botY), radius: rBot)
            p.addArc(tangent1End: CGPoint(x: x0, y: botY), tangent2End: CGPoint(x: x0, y: topY), radius: rBot)
            p.addArc(tangent1End: CGPoint(x: x0, y: topY), tangent2End: CGPoint(x: x0 + W, y: topY), radius: rTop)
            p.closeSubpath()
            ctx.addPath(p); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
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
