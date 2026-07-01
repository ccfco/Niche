import AppKit
import Combine

/// 菜单栏图标 + 下拉菜单。提供"呼出 Niche / 设置… / 退出"等入口,并作为全局快捷键兜底
/// 之外的常驻可见触发点(spec §4.2:菜单栏图标是可选触发位置之一)。
@MainActor
final class MenuBarController {
    private let environment: AppEnvironment
    private let statusItem: NSStatusItem
    private let onToggle: () -> Void
    private let onOpenSettings: () -> Void
    private var updateCancellable: AnyCancellable?

    init(environment: AppEnvironment, onToggle: @escaping () -> Void,
         onOpenSettings: @escaping () -> Void) {
        self.environment = environment
        self.onToggle = onToggle
        self.onOpenSettings = onOpenSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()
        statusItem.menu = makeMenu()

        // latestRelease 变化时重建菜单(有新版 → 加更新区;已是最新 → 去掉更新区)。
        updateCancellable = UpdateChecker.shared.$latestRelease
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.statusItem.menu = self?.makeMenu() }
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = Self.makeIcon()
        button.image?.accessibilityDescription = "Niche"
    }

    /// 自绘菜单栏图标:实心「刘海文件夹」——文件夹剪影,标签(tab)挪到正中央、做成刘海下凸形状。
    /// 一眼是文件夹(文件快速访问,不被误认成下载/托盘),而「居中刘海 tab」是 Niche 独有签名
    /// (普通文件夹 tab 在左上):文件 × 刘海合成一个标志。单色实心剪影,18pt 清晰。
    private static func makeIcon() -> NSImage {
        let h: CGFloat = 18
        let image = NSImage(size: NSSize(width: h * 1.08, height: h), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let r = rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.07)
            let yB = r.minY
            let yBT = r.minY + r.height * 0.70
            let yT = r.maxY
            let tabW = r.width * 0.42
            let txL = r.midX - tabW / 2, txR = r.midX + tabW / 2
            let bc = r.width * 0.13
            let tc = r.width * 0.085
            let corners: [(CGFloat, CGFloat, CGFloat)] = [
                (r.maxX, yB, bc), (r.maxX, yBT, bc),
                (txR, yBT, tc), (txR, yT, tc), (txL, yT, tc), (txL, yBT, tc),
                (r.minX, yBT, bc), (r.minX, yB, bc),
            ]
            let p = CGMutablePath()
            let start = CGPoint(x: r.midX, y: yB)
            p.move(to: start)
            for i in 0..<corners.count {
                let cur = CGPoint(x: corners[i].0, y: corners[i].1)
                let nxt = i + 1 < corners.count ? CGPoint(x: corners[i + 1].0, y: corners[i + 1].1) : start
                p.addArc(tangent1End: cur, tangent2End: nxt, radius: corners[i].2)
            }
            p.closeSubpath()
            ctx.addPath(p); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "呼出 Niche"), action: #selector(togglePanel), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())

        // 有新版本时在设置前插入更新区。
        if let release = UpdateChecker.shared.latestRelease {
            let badge = menu.addItem(
                withTitle: String(localized: "新版本可用：\(release.displayVersion)"),
                action: nil, keyEquivalent: ""
            )
            badge.isEnabled = false
            let install = NSMenuItem(title: String(localized: "安装更新"), action: #selector(installUpdate), keyEquivalent: "")
            install.target = self
            menu.addItem(install)
            menu.addItem(.separator())
        }

        let settings = menu.addItem(withTitle: String(localized: "设置…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "退出 Niche"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func togglePanel() {
        onToggle()
    }

    /// 打开自管设置窗口。不能再走 `showSettingsWindow:` 私有选择子 —— macOS 14+ 系统已封禁
    /// (点了没反应,控制台提示改用 SettingsLink),设置窗口已 AppKit 自管(SettingsWindowController)。
    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func installUpdate() {
        UpdateChecker.shared.installUpdate()
    }
}
