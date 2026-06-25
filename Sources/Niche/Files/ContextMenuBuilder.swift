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
    /// 「显示简介」入口:把选区交宿主经 FinderGetInfo 调起访达原生 Get Info 窗(右键与 ⌘I 共用此一处)。
    private let onShowInfo: ([URL]) -> Void
    /// 在瞬态面板可见时呈现模态(NSOpenPanel/NSAlert/冲突弹窗)的统一 bracket —— 宿主注入
    /// (NicheController.withModalContext):抑制 auto-hide + 临时降级 panel.level 防遮挡。
    /// 菜单动作里凡跑 runModal 的都经它,杜绝"只有 addFolder 配对、右键模态被面板盖住"。
    private let presentModal: (() -> Void) -> Void
    private var context: Context?

    init(ops: FileOperations, autoHide: AutoHideCoordinator,
         onRequestRename: @escaping (URL) -> Void,
         onShowInfo: @escaping ([URL]) -> Void,
         presentModal: @escaping (() -> Void) -> Void) {
        self.ops = ops
        self.autoHide = autoHide
        self.onRequestRename = onRequestRename
        self.onShowInfo = onShowInfo
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
        add(menu, "新建文件夹", #selector(doNewFolder), symbol: "folder.badge.plus")
        let paste = NSMenuItem(title: "粘贴", action: #selector(doPaste), keyEquivalent: "")
        paste.target = self
        paste.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
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

        add(menu, "打开", #selector(doOpen), symbol: "arrow.up.forward.app")
        if !multiple, let first = ctx.selection.first {
            menu.addItem(openWithSubmenu(for: first))
        }
        add(menu, "在 Finder 中显示", #selector(doReveal), symbol: "folder")
        add(menu, "显示简介", #selector(doShowInfo), symbol: "info.circle")
        menu.addItem(.separator())

        if !multiple {
            add(menu, "重命名", #selector(doRename), symbol: "pencil")
        }
        add(menu, "拷贝", #selector(doCopy), symbol: "square.on.square")
        add(menu, "复制路径", #selector(doCopyPath), symbol: "doc.on.clipboard")
        add(menu, "移动到…", #selector(doMoveTo), symbol: "arrowshape.turn.up.right")
        menu.addItem(.separator())

        add(menu, "压缩", #selector(doCompress), symbol: "doc.zipper")
        add(menu, "分享…", #selector(doShare), symbol: "square.and.arrow.up")
        // 外观行(自绘 TagColorRowView):一排标签色圆点;文件夹再带一行「自定义文件夹」。整体一个 NSView,
        // 圆点与文字共用左缘、不经 NSMenuItem 标题 —— 避免借标题触发的菜单宽度抖动/文字跑位。
        menu.addItem(.separator())
        let canCustomize = !multiple && ctx.selection.first.map(Self.isDirectory) == true
        menu.addItem(tagRowItem(ctx, canCustomize: canCustomize))
        menu.addItem(.separator())

        add(menu, "移到废纸篓", #selector(doTrash), symbol: "trash")
        return menu
    }

    /// symbol 非空时给该项配前置 SF Symbol(模板图像,自动跟随菜单文字色/选中高亮;对齐访达右键图标化)。
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, symbol: String? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
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
            // 子项用 App 自己的图标(对齐访达「打开方式」),缩到菜单图标尺寸,否则按原始大图显示。
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    /// 外观行(自绘 TagColorRowView):一排标签色圆点 + (文件夹)一行「自定义文件夹」。
    /// canCustomize=true(单个文件夹)时画并接管「自定义文件夹」行的点击,hover 圆点时该行显示灰色
    /// 「添加/移除 "X"」。整体自绘,圆点与文字共用左缘、不经 NSMenuItem 标题 → 无抖动/跑位。
    private func tagRowItem(_ ctx: Context, canCustomize: Bool) -> NSMenuItem {
        let item = NSMenuItem()
        let applied = appliedTags(ctx.selection)
        item.view = TagColorRowView(
            tags: TagPalette.standard,
            applied: applied,
            onToggle: { [weak self] name in self?.toggleTag(name, in: ctx.selection) },
            customize: canCustomize ? { [weak self] in self?.doCustomizeFolder() } : nil
        )
        return item
    }

    /// 选区"共有"的标签(交集)→ 决定哪些圆点画勾。标签读取走 FileItem.tags(of:)(清缓存单一权威)。
    private func appliedTags(_ selection: [URL]) -> Set<String> {
        guard let first = selection.first else { return [] }
        var common = Set(FileItem.tags(of: first))
        for url in selection.dropFirst() { common.formIntersection(FileItem.tags(of: url)) }
        return common
    }

    /// 切换标签:选区全部已有 → 整体移除;否则 → 给缺的补上(保留稳定序,新标签追加末尾)。
    private func toggleTag(_ name: String, in selection: [URL]) {
        let allHave = selection.allSatisfy { FileItem.tags(of: $0).contains(name) }
        for url in selection {
            var tags = FileItem.tags(of: url)
            if allHave {
                tags.removeAll { $0 == name }
            } else if !tags.contains(name) {
                tags.append(name)
            }
            do { try ops.setTags(tags, on: url) }
            catch {
                Log.files.error("切换标签失败:\(error.localizedDescription, privacy: .public)")
                presentFailure(title: "无法设置标签", error: error)
                return   // 多选逐项失败不连环弹窗,首错即止
            }
        }
    }

    // MARK: - 动作(每项调系统 API)

    @objc private func doOpen() { context?.selection.forEach { ops.open($0) } }

    @objc private func doOpenWith(_ sender: NSMenuItem) {
        guard let appURL = sender.representedObject as? URL,
              let target = context?.selection.first else { return }
        ops.open(target, withApplicationAt: appURL)
    }

    @objc private func doReveal() { if let urls = context?.selection { ops.revealInFinder(urls) } }

    /// 「显示简介」:把选区交宿主(onShowInfo)经 FinderGetInfo 驱动访达弹原生 Get Info 窗。
    @objc private func doShowInfo() { if let urls = context?.selection { onShowInfo(urls) } }

    /// 「不再提示」自定义文件夹引导的持久化键(系统 suppressionButton 状态)。
    private static let customizeHintSuppressedKey = "customizeFolderHintSuppressed"

    /// 选区首项是否目录(决定「自定义文件夹…」是否出现)。右键单次调用,同步读可接受。
    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    /// 「自定义文件夹…」:macOS 26 文件夹外观(符号/emoji/颜色)是 Finder 私有面板 —— 既非
    /// NSService,AppleScript 字典也无对应命令(实测 26.5),**无法编程弹起**。故把文件夹在访达
    /// 中选中,由用户在访达右键用系统「自定义文件夹」完成。首次弹一次带「不再提示」的引导(系统
    /// 原生 suppressionButton),消除"只是选中、没弹面板"的落差;勾选后此后静默 reveal。
    /// alert 在 reveal 前弹(Niche 仍前台),经 presentModal 防瞬态面板遮挡。
    @objc private func doCustomizeFolder() {
        guard let url = context?.selection.first else { return }
        if UserDefaults.standard.bool(forKey: Self.customizeHintSuppressedKey) {
            ops.revealInFinder([url])
            return
        }
        presentModal {
            let alert = NSAlert()
            alert.messageText = "在访达中自定义文件夹"
            alert.informativeText = "Niche 会在访达中选中此文件夹。在访达里右键选择「自定义文件夹」,即可设置符号、emoji 或颜色。"
            alert.addButton(withTitle: "打开访达")
            alert.addButton(withTitle: "取消")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "不再提示"
            let response = alert.runModal()
            // 勾了「不再提示」即记住意图(无论本次去不去访达),下次直接 reveal。
            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(true, forKey: Self.customizeHintSuppressedKey)
            }
            guard response == .alertFirstButtonReturn else { return }
            ops.revealInFinder([url])
        }
    }

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
