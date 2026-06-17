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
    /// 在瞬态面板可见时呈现模态(NSOpenPanel/NSAlert/冲突弹窗)的统一 bracket —— 宿主注入
    /// (NicheController.withModalContext):抑制 auto-hide + 临时降级 panel.level 防遮挡。
    /// 菜单动作里凡跑 runModal 的都经它,杜绝"只有 addFolder 配对、右键模态被面板盖住"。
    private let presentModal: (() -> Void) -> Void
    private var context: Context?

    /// 标准 Finder 标签色(名称 + 圆点色)。此前 symbol 字段恒为 "circle.fill" 且从未用到(死数据);
    /// 改为携带颜色,菜单项用彩色圆点 image 呈现(#19)。
    private static let standardTags: [(name: String, color: NSColor)] = [
        ("红色", .systemRed), ("橙色", .systemOrange), ("黄色", .systemYellow),
        ("绿色", .systemGreen), ("蓝色", .systemBlue), ("紫色", .systemPurple), ("灰色", .systemGray),
    ]

    /// 标签彩色圆点:SF Symbol circle.fill 上 paletteColors 染色(与 Finder 标签圆点观感一致)。
    private static func tagDot(_ color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(paletteColors: [color])
        return NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    init(ops: FileOperations, autoHide: AutoHideCoordinator,
         onRequestRename: @escaping (URL) -> Void,
         presentModal: @escaping (() -> Void) -> Void) {
        self.ops = ops
        self.autoHide = autoHide
        self.onRequestRename = onRequestRename
        self.presentModal = presentModal
    }

    /// 构建一个配置好(delegate 已设,驱动抑制)的菜单,交给 NSView.menu(for:) 由 AppKit 弹出。
    func makeMenu(for context: Context) -> NSMenu {
        self.context = context
        let menu = build(context)
        menu.delegate = self
        return menu
    }

    /// 背景(空白处)菜单:新建文件夹 / 粘贴(无剪贴板文件时禁用)。复用同一 delegate 驱动抑制。
    /// directory = 当前目录(新建/粘贴落点);selection 空。
    func makeBackgroundMenu(directory: URL, anchorView: NSView) -> NSMenu {
        self.context = Context(selection: [], directory: directory, anchorView: anchorView)
        let menu = NSMenu()
        menu.autoenablesItems = false   // 自行控制「粘贴」启用态(否则只要 target 响应就恒启用)
        add(menu, "新建文件夹", #selector(doNewFolder))
        let paste = NSMenuItem(title: "粘贴", action: #selector(doPaste), keyEquivalent: "")
        paste.target = self
        paste.isEnabled = ops.canPaste
        menu.addItem(paste)
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
            item.image = Self.tagDot(tag.color)   // 彩色圆点(#19)
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

    /// 「移动到…」:NSOpenPanel 选目标。经 presentModal(withModalContext):模态期间抑制 auto-hide
    /// + 临时降级 panel.level,否则瞬态面板会盖住选目录对话框(此前漏配,只有 addFolder 做了降级)。
    /// 失败弹可见提示(此前 try? 静默吞错:目标只读/磁盘满时文件原地不动、用户无任何反馈)。
    @objc private func doMoveTo() {
        guard let ctx = context else { return }
        presentModal {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = "移动到此"
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            do { try ops.move(ctx.selection, to: dest, resolve: ConflictPrompt.ask) }
            catch {
                Log.files.error("移动到失败:\(error.localizedDescription, privacy: .public)")
                presentFailure(title: "无法移动到所选位置", error: error)
            }
        }
    }

    @objc private func doCompress() {
        guard let ctx = context else { return }
        Task {
            do { try await ops.compress(ctx.selection, in: ctx.directory) }
            catch {
                Log.files.error("压缩失败:\(error.localizedDescription, privacy: .public)")
                presentFailure(title: "无法压缩", error: error)
            }
        }
    }

    @objc private func doSetTag(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String, let urls = context?.selection else { return }
        for url in urls {
            // 读现有标签失败按"无标签"处理(读不到不该挡写入);写入失败必须可见。
            let existing = (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
            let merged = Array(Set(existing + [tag]))
            do { try ops.setTags(merged, on: url) }
            catch {
                Log.files.error("设置标签失败:\(error.localizedDescription, privacy: .public)")
                presentFailure(title: "无法设置标签", error: error)
                return   // 多选逐项失败不连环弹窗,首错即止
            }
        }
    }

    @objc private func doClearTags() {
        for url in context?.selection ?? [] {
            do { try ops.setTags([], on: url) }
            catch {
                Log.files.error("清除标签失败:\(error.localizedDescription, privacy: .public)")
                presentFailure(title: "无法清除标签", error: error)
                return
            }
        }
    }

    @objc private func doShare() {
        guard let ctx = context else { return }
        ops.share(ctx.selection, relativeTo: ctx.anchorView.bounds, of: ctx.anchorView)
    }

    @objc private func doTrash() { if let urls = context?.selection { ops.trash(urls) } }

    // MARK: - 背景菜单动作(新建文件夹 / 粘贴,落点 = 当前目录)

    /// 新建文件夹后进入就地重命名(Finder 语义:新建即选中命名),复用 onRequestRename。
    @objc private func doNewFolder() {
        guard let dir = context?.directory else { return }
        do {
            let url = try ops.newFolder(in: dir)
            onRequestRename(url)
        } catch {
            Log.files.error("新建文件夹失败:\(error.localizedDescription, privacy: .public)")
            presentFailure(title: "无法新建文件夹", error: error)
        }
    }

    /// 粘贴:同名冲突会弹 ConflictPrompt 模态 → presentModal(抑制收回 + 降级面板防遮挡)。
    @objc private func doPaste() {
        guard let dir = context?.directory else { return }
        presentModal {
            do { try ops.paste(into: dir, resolve: ConflictPrompt.ask) }
            catch {
                Log.files.error("粘贴失败:\(error.localizedDescription, privacy: .public)")
                presentFailure(title: "无法粘贴", error: error)
            }
        }
    }

    /// 失败弹窗同走 presentModal:NSAlert 在瞬态模式下也会被面板遮挡(标签/新建等错误路径)。
    /// 嵌套调用(doMoveTo/doPaste 的 catch 已在 presentModal 内再调本方法)安全 —— withModalContext
    /// 保存/恢复当前 level,且 AutoHideCoordinator 抑制源已改引用计数,begin/end 平衡配对。
    private func presentFailure(title: String, error: Error) {
        presentModal { FailureAlert.present(title: title, error: error, autoHide: autoHide) }
    }
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
