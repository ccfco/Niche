import AppKit

/// 自拼右键菜单(spec §4.5 / §8.3:用 NSMenu 覆盖 ~95% 常用项,每项调系统 API;
/// Finder 右键菜单本体与 Get Info 是系统硬边界,不做)。
///
/// 菜单 open/close 驱动 AutoHideCoordinator 的 .contextMenu 抑制源(spec §4.6:菜单展开时
/// 暂停瞬态面板 auto-hide)。
@MainActor
final class ContextMenuBuilder: NSObject, NSMenuDelegate {
    struct Context {
        var selection: [URL]      // 右键作用的条目(单选或多选)
        var directory: URL        // 当前目录(用于"压缩到此/移动到此")
        var anchorView: NSView    // 分享 picker 相对定位用
    }

    private let ops: FileOperations
    private let autoHide: AutoHideCoordinator
    private let onRequestRename: (URL) -> Void
    private var context: Context?

    /// 标准 Finder 标签色。
    private static let standardTags: [(name: String, symbol: String)] = [
        ("红色", "circle.fill"), ("橙色", "circle.fill"), ("黄色", "circle.fill"),
        ("绿色", "circle.fill"), ("蓝色", "circle.fill"), ("紫色", "circle.fill"), ("灰色", "circle.fill"),
    ]

    init(ops: FileOperations, autoHide: AutoHideCoordinator, onRequestRename: @escaping (URL) -> Void) {
        self.ops = ops
        self.autoHide = autoHide
        self.onRequestRename = onRequestRename
    }

    /// 构建一个配置好(delegate 已设,驱动抑制)的菜单,交给 NSView.menu(for:) 由 AppKit 弹出。
    func makeMenu(for context: Context) -> NSMenu {
        self.context = context
        let menu = build(context)
        menu.delegate = self
        return menu
    }

    // MARK: - NSMenuDelegate(驱动抑制隐藏)

    func menuWillOpen(_ menu: NSMenu) { autoHide.begin(.contextMenu) }
    func menuDidClose(_ menu: NSMenu) { autoHide.end(.contextMenu) }

    // MARK: - 菜单构建

    private func build(_ ctx: Context) -> NSMenu {
        let menu = NSMenu()
        let multiple = ctx.selection.count > 1

        add(menu, "打开", #selector(doOpen))
        if !multiple, let first = ctx.selection.first {
            menu.addItem(openWithSubmenu(for: first))
        }
        add(menu, "在 Finder 中显示", #selector(doReveal))
        menu.addItem(.separator())

        if !multiple {
            add(menu, "重命名", #selector(doRename))
        }
        add(menu, "拷贝", #selector(doCopy))
        add(menu, "复制路径", #selector(doCopyPath))
        add(menu, "移动到…", #selector(doMoveTo))
        menu.addItem(.separator())

        add(menu, "压缩", #selector(doCompress))
        menu.addItem(tagsSubmenu())
        add(menu, "分享…", #selector(doShare))
        menu.addItem(.separator())

        add(menu, "移到废纸篓", #selector(doTrash))
        return menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func openWithSubmenu(for url: URL) -> NSMenuItem {
        let parent = NSMenuItem(title: "打开方式", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: url)
        for appURL in appURLs.prefix(12) {
            let name = FileManager.default.displayName(atPath: appURL.path)
            let item = NSMenuItem(title: name, action: #selector(doOpenWith(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = appURL
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private func tagsSubmenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "标签", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for tag in Self.standardTags {
            let item = NSMenuItem(title: tag.name, action: #selector(doSetTag(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tag.name
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let clear = NSMenuItem(title: "清除标签", action: #selector(doClearTags), keyEquivalent: "")
        clear.target = self
        submenu.addItem(clear)
        parent.submenu = submenu
        return parent
    }

    // MARK: - 动作(每项调系统 API)

    @objc private func doOpen() { context?.selection.forEach { ops.open($0) } }

    @objc private func doOpenWith(_ sender: NSMenuItem) {
        guard let appURL = sender.representedObject as? URL,
              let target = context?.selection.first else { return }
        ops.open(target, withApplicationAt: appURL)
    }

    @objc private func doReveal() { if let urls = context?.selection { ops.revealInFinder(urls) } }

    @objc private func doRename() {
        if let url = context?.selection.first { onRequestRename(url) }
    }

    @objc private func doCopy() { if let urls = context?.selection { ops.copyToPasteboard(urls) } }

    @objc private func doCopyPath() { if let urls = context?.selection { ops.copyPaths(urls) } }

    @objc private func doMoveTo() {
        guard let ctx = context else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "移动到此"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? ops.move(ctx.selection, to: dest, resolve: ConflictPrompt.ask)
    }

    @objc private func doCompress() {
        guard let ctx = context else { return }
        Task {
            do { try await ops.compress(ctx.selection, in: ctx.directory) }
            catch { Log.files.error("压缩失败:\(error.localizedDescription, privacy: .public)") }
        }
    }

    @objc private func doSetTag(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String, let urls = context?.selection else { return }
        for url in urls {
            let existing = (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
            let merged = Array(Set(existing + [tag]))
            try? ops.setTags(merged, on: url)
        }
    }

    @objc private func doClearTags() {
        context?.selection.forEach { try? ops.setTags([], on: $0) }
    }

    @objc private func doShare() {
        guard let ctx = context else { return }
        ops.share(ctx.selection, relativeTo: ctx.anchorView.bounds, of: ctx.anchorView)
    }

    @objc private func doTrash() { if let urls = context?.selection { ops.trash(urls) } }
}

/// 同名冲突的 NSAlert 提示(replace/keepBoth/skip),供 FileOperations 的 resolver 调用。
enum ConflictPrompt {
    @MainActor
    static func ask(name: String) -> ConflictResolution {
        let alert = NSAlert()
        alert.messageText = "「\(name)」已存在"
        alert.informativeText = "目标位置已有同名项,如何处理?"
        alert.addButton(withTitle: ConflictResolution.replace.localizedTitle)
        alert.addButton(withTitle: ConflictResolution.keepBoth.localizedTitle)
        alert.addButton(withTitle: ConflictResolution.skip.localizedTitle)
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .replace
        case .alertSecondButtonReturn: return .keepBoth
        default:                       return .skip
        }
    }
}
