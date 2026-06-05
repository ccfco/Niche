import AppKit
import Combine

/// 顶层编排:把触发热区、瞬态(DNK)/常驻(PinnedPanel)两个呈现宿主、焦点抑制模型、
/// 镜像数据源、Quick Look 接成一个可切换的窗口状态机(spec §4.6)。
@MainActor
final class NicheController {
    private let environment: AppEnvironment
    private let screens = ScreenObserver()
    private let model = PanelModel()
    private let autoHide = AutoHideCoordinator()
    private let hotZone = HotZoneController()
    private let volumes = VolumeMonitor()
    private lazy var quickLook = QuickLookController(autoHide: autoHide)
    private let undoManager = FileOpUndoManager()
    private lazy var ops = FileOperations(undo: undoManager)
    private lazy var contextMenu = ContextMenuBuilder(
        ops: ops, autoHide: autoHide,
        onRequestRename: { [weak self] url in self?.model.beginRename(url) }
    )

    private lazy var actions = PanelActions(
        onOpen: { [weak self] in self?.open($0) },
        onTogglePin: { [weak self] in self?.togglePin() },
        onAddFolder: { [weak self] in self?.addFolder() },
        onRemoveFolder: { [weak self] in self?.removeFolder($0) },
        onQuickLook: { [weak self] urls, index in self?.quickLook.preview(urls: urls, at: index) },
        onContextMenu: { [weak self] urls, anchor in self?.makeContextMenu(urls, anchor) },
        onDropURLs: { [weak self] urls, modifiers in self?.handleDrop(urls, modifiers: modifiers) },
        onRename: { [weak self] url, newName in self?.rename(url, to: newName) ?? false },
        onCopy: { [weak self] urls in self?.ops.copyToPasteboard(urls) },
        onCut: { [weak self] urls in self?.ops.cut(urls) },
        onCopyPath: { [weak self] urls in self?.ops.copyPaths(urls) },
        onTrash: { [weak self] urls in self?.ops.trash(urls) },
        onPaste: { [weak self] in self?.paste() },
        onUndo: { [weak self] in self?.ops.undoLast() }
    )
    private lazy var transient = NotchExpansion(model: model, actions: actions)
    private lazy var pinned = PinnedPanelController(model: model, actions: actions)

    private var resignObserver: NSObjectProtocol?
    private var screenCancellable: AnyCancellable?
    private var renameCancellable: AnyCancellable?

    init(environment: AppEnvironment) {
        self.environment = environment
        wire()
        placeHotZone()
        rebuildMirrors()
    }

    deinit {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    // MARK: - 接线

    private func wire() {
        hotZone.onTrigger = { [weak self] draggingFile in
            self?.present(draggingFile: draggingFile)
        }
        autoHide.onShouldHide = { [weak self] in
            Task { await self?.hideTransient() }
        }
        // ownedWindows:瞬态面板本体 + Quick Look 预览面板(失焦判定排除"焦点转到自己派生窗口")。
        // 右键菜单/重命名 popup 在 M3 并入。
        autoHide.ownedWindows = { [weak self] in
            [self?.transient.panel, self?.quickLook.previewPanel].compactMap { $0 }
        }
        screenCancellable = screens.$generation
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.placeHotZone() }

        // 卷卸载/挂载转发给各 mirror(spec §4.1.1:卷消失 → 空态;回来 → 用户回该 tab 自动重连)。
        volumes.onUnmount = { [weak self] url in
            self?.model.mirrors.forEach { $0.volumeDidUnmount(url) }
        }
        volumes.onMount = { [weak self] url in
            self?.model.mirrors.forEach { $0.volumeDidMount(url) }
        }

        // 就地重命名进行中 → .renaming 抑制瞬态面板 auto-hide(spec §4.6)。
        renameCancellable = model.$renamingItemID
            .removeDuplicates()
            .sink { [weak self] id in
                guard let self else { return }
                if id != nil { self.autoHide.begin(.renaming) } else { self.autoHide.end(.renaming) }
            }
    }

    private func placeHotZone() {
        guard let screen = screens.activeScreen else { return }
        hotZone.place(on: screens.resolution(for: screen))
    }

    // MARK: - 呈现/收回(瞬态)

    func toggle() {
        if model.windowMode == .pinned, pinned.isVisible {
            pinned.hide()
        } else if transient.isExpanded {
            Task { await hideTransient() }
        } else {
            present(draggingFile: false)
        }
    }

    private func present(draggingFile: Bool) {
        guard let screen = screens.activeScreen else { return }
        model.windowMode = .transient
        model.armCurrent()   // 打开面板 = 用户动作,可触发当前 tab 的 TCC 探针
        Task {
            await transient.expand(on: screen)
            observeTransientFocus()
        }
    }

    private func hideTransient() async {
        await transient.hide()
        teardownTransientFocusObserver()
    }

    private func observeTransientFocus() {
        teardownTransientFocusObserver()
        guard let panel = transient.panel else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.autoHide.handleResignKey(newKeyWindow: NSApp.keyWindow)
            }
        }
    }

    private func teardownTransientFocusObserver() {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }

    // MARK: - Pin 切换(瞬态 ↔ 常驻)

    private func togglePin() {
        model.windowMode == .pinned ? unpin() : pin()
    }

    private func pin() {
        let frame = transient.panel?.frame ?? defaultPinnedFrame()
        model.windowMode = .pinned
        Task {
            await hideTransient()
            pinned.show(at: frame)
        }
    }

    private func unpin() {
        model.windowMode = .transient
        pinned.hide()
        present(draggingFile: false)
    }

    private func defaultPinnedFrame() -> NSRect {
        guard let screen = screens.activeScreen else { return NSRect(x: 200, y: 200, width: 460, height: 320) }
        let r = screens.resolution(for: screen).rect
        return NSRect(x: r.midX - 230, y: r.minY - 340, width: 460, height: 320)
    }

    // MARK: - 文件操作(M3)

    private func open(_ item: FileItem) {
        ops.open(item.url)
    }

    /// 重命名提交;返回是否成功(失败 → cell 保持编辑态)。校验空名/同名/非法字符。
    private func rename(_ url: URL, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !trimmed.contains("/"), !trimmed.contains(":") else { return false }  // 非法字符
        guard trimmed != url.lastPathComponent else { return true }                 // 未改名,视为完成
        do {
            try ops.rename(url, to: trimmed)
            return true
        } catch {
            Log.files.error("重命名失败:\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func paste() {
        guard let dir = model.currentMirror?.currentDirectory else { return }
        do { try ops.paste(into: dir, resolve: ConflictPrompt.ask) }
        catch { Log.files.error("粘贴失败:\(error.localizedDescription, privacy: .public)") }
    }

    private func makeContextMenu(_ urls: [URL], _ anchor: NSView) -> NSMenu? {
        guard let dir = model.currentMirror?.currentDirectory else { return nil }
        return contextMenu.makeMenu(for: .init(selection: urls, directory: dir, anchorView: anchor))
    }

    /// 拖入落地:Niche 自己执行 copy/move(spec §4.5 注②)。按目标目录与**每个源**的卷 +
    /// 修饰键分别决策(混合同卷/跨卷来源要分别处理),并拦截"目录拖进自身子目录"的循环。
    private func handleDrop(_ urls: [URL], modifiers: NSEvent.ModifierFlags) {
        guard let dir = model.currentMirror?.currentDirectory else { return }
        let destStd = dir.standardizedFileURL

        let incoming = urls.filter { src in
            let srcStd = src.standardizedFileURL
            // 落点与源同目录:无意义的自我移动,跳过。
            if src.deletingLastPathComponent().standardizedFileURL == destStd { return false }
            // 目录拖进自身或其子目录:循环,拒绝。
            if DirectoryMirror.contains(ancestor: srcStd, descendant: destStd) { return false }
            return true
        }
        guard !incoming.isEmpty else { return }

        // 每个源单独按卷判定 copy/move,避免首项卷判定误伤跨卷项。
        var toCopy: [URL] = [], toMove: [URL] = []
        for src in incoming {
            switch DragSemantics.resolve(sameVolume: DragSemantics.isSameVolume(src, dir), modifiers: modifiers) {
            case .copy: toCopy.append(src)
            case .move: toMove.append(src)
            }
        }
        autoHide.begin(.dragging)
        defer { autoHide.end(.dragging) }
        do {
            if !toCopy.isEmpty { try ops.copy(toCopy, to: dir, resolve: ConflictPrompt.ask) }
            if !toMove.isEmpty { try ops.move(toMove, to: dir, resolve: ConflictPrompt.ask) }
        } catch {
            Log.files.error("拖入处理失败:\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 绑定文件夹管理

    private func rebuildMirrors() {
        model.rebuildMirrors(from: environment.bindingStore.bindings)
    }

    /// 添加文件夹:NSOpenPanel 选目录 → 生成普通 bookmark → 持久化 → 重建镜像。
    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "添加"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let bookmark = DirectoryMirror.makeBookmark(for: url)
        let binding = FolderBinding(bookmarkData: bookmark, path: url.path)
        environment.bindingStore.add(binding)
        rebuildMirrors()
        model.selectTab(environment.bindingStore.bindings.count - 1)
    }

    private func removeFolder(_ id: FolderBinding.ID) {
        environment.bindingStore.remove(id: id)
        rebuildMirrors()
    }
}
