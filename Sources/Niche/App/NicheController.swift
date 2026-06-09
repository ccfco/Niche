import AppKit
import Combine

/// 顶层编排:把触发热区、统一面板宿主(瞬态↔常驻同一窗口)、焦点抑制模型、
/// 镜像数据源、Quick Look 接成一个可切换的窗口状态机(spec §4.6)。
@MainActor
final class NicheController {
    private let environment: AppEnvironment
    private let screens = ScreenObserver()
    private let model = PanelModel()
    private let motion = MotionPreferences()
    private let autoHide = AutoHideCoordinator()
    private let hotZone = HotZoneController()
    private let volumes = VolumeMonitor()
    private let hotkey = GlobalHotkey()
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
        isQuickLookActive: { [weak self] in self?.quickLook.isActive ?? false },
        onQuickLookClose: { [weak self] in self?.quickLook.close() },
        onQuickLookSyncCursor: { [weak self] in
            guard let self, let index = self.model.cursorIndex else { return }
            self.quickLook.syncCurrentIndex(index)
        },
        onContextMenu: { [weak self] urls, anchor in self?.makeContextMenu(urls, anchor) },
        onContextMenuBackground: { [weak self] anchor in self?.makeBackgroundMenu(anchor) },
        onDropURLs: { [weak self] urls, modifiers in self?.handleDrop(urls, modifiers: modifiers) },
        onRename: { [weak self] url, newName in self?.rename(url, to: newName) ?? false },
        onCopy: { [weak self] urls in self?.ops.copyToPasteboard(urls) },
        onCut: { [weak self] urls in self?.ops.cut(urls) },
        onCopyPath: { [weak self] urls in self?.ops.copyPaths(urls) },
        onTrash: { [weak self] urls in self?.ops.trash(urls) },
        onPaste: { [weak self] in self?.paste() },
        onUndo: { [weak self] in self?.ops.undoLast() },
        onClose: { [weak self] in self?.closeFromKeyboard() },
        onDragBegin: { [weak self] in self?.autoHide.begin(.draggingOut) },
        onDragEnd: { [weak self] in self?.autoHide.end(.draggingOut) }
    )
    private lazy var panelController = PanelController(
        model: model, motion: motion, actions: actions
    )

    private var resignObserver: NSObjectProtocol?
    private var screenCancellable: AnyCancellable?
    private var renameCancellable: AnyCancellable?
    private var bindingsCancellable: AnyCancellable?
    private var selectionCancellable: AnyCancellable?
    private var quickLookContentCancellable: AnyCancellable?
    private var relayoutCancellable: AnyCancellable?

    init(environment: AppEnvironment) {
        self.environment = environment
        wire()
        hotZone.refreshPlacement()
        rebuildMirrors()
        hotkey.onTrigger = { [weak self] in self?.toggle() }
        hotkey.register()   // 默认 ⌥⌘Space 兜底呼出
    }

    deinit {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    // MARK: - 接线

    private func wire() {
        hotZone.onTrigger = { [weak self] _ in
            self?.present()
        }
        // 热区跟随鼠标换屏:给定屏 → 该屏刘海/回退几何的命中矩形。
        hotZone.resolveRect = { [weak self] screen in
            guard let self else { return nil }
            return NotchGeometry.hotZoneRect(from: self.screens.resolution(for: screen))
        }
        autoHide.onShouldHide = { [weak self] in
            self?.hideTransient()
        }
        // 抑制源(QL/菜单/重命名/拖拽)解除补隐时,重评鼠标当前位置而非盲目兑现 pendingHide:
        // 关 QL 后若鼠标已回面板走廊内则取消收回(否则关预览会连带把面板也收走,不符直觉)。
        autoHide.onReevaluate = { [weak self] in
            self?.panelController.reevaluateAutoHide()
        }
        // 瞬态鼠标离开"面板↔刘海"走廊 → 过抑制判定后收回(移开即收的主路径)。
        panelController.onMouseExitedTransient = { [weak self] in
            self?.autoHide.handleMouseLeave()
        }
        // ownedWindows:面板本体 + Quick Look 预览面板(失焦判定排除"焦点转到自己派生窗口")。
        // 右键菜单/重命名 popup 在 M3 并入。
        autoHide.ownedWindows = { [weak self] in
            [self?.panelController.panel, self?.quickLook.previewPanel].compactMap { $0 }
        }
        screenCancellable = screens.$generation
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.hotZone.refreshPlacement() }

        // 卷卸载/挂载转发给各 mirror(spec §4.1.1:卷消失 → 空态;回来 → 用户回该 tab 自动重连)。
        volumes.onUnmount = { [weak self] url in
            self?.model.mirrors.forEach { $0.volumeDidUnmount(url) }
        }
        volumes.onMount = { [weak self] url in
            self?.model.mirrors.forEach { $0.volumeDidMount(url) }
        }

        // Quick Look:浮于面板之上(取宿主当前层级 +1)+ 跟随选中双向同步(spec §4.5/§4.6)。
        quickLook.hostWindowLevel = { [weak self] in self?.panelController.panel?.level }
        // QL 内 ←→ 翻页 → 把光标(单选)移到该项(关闭后选中停在最后预览项)。相等守卫防与转发回环。
        // 有意设计:空格预览「全部条目从光标起」,翻页 = 在全集里导航 = 单选移动(与方向键一致,
        // Task D 验收「开预览后 ↑↓ 换文件」),故翻页坍缩多选为单选,不是 bug(Codex review)。
        quickLook.onIndexChange = { [weak self] index in
            guard let self, self.model.cursorIndex != index,
                  self.model.sortedItems.indices.contains(index) else { return }
            self.model.selectSingle(self.model.sortedItems[index].id)
        }
        // 光标变化 → 若 QL active 则跳到该项(syncCurrentIndex 内部判 active/相等,非 active 即 no-op)。
        // @Published 在 willSet 阶段发布,此刻 cursorID 仍是旧值 → 派生的 cursorIndex 会算出"上一个"
        // 光标,导致预览慢一拍(预览前一个对象)。故 receive(on:) 推迟到下一 runloop,读到新光标。
        selectionCancellable = model.$cursorID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, let index = self.model.cursorIndex else { return }
                self.quickLook.syncCurrentIndex(index)
            }
        // 内容(排序/目录下钻/FSEvents)变化 → QL active 时刷新预览列表并定位。objectWillChange 在变更
        // 前触发,故 receive(on:) 推迟到下一 runloop 让 sortedItems 反映新态;updateItems 内 urls 未变跳过。
        quickLookContentCancellable = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self, self.quickLook.isActive else { return }
                // 光标失效(预览项被外部删除 / 下钻进无选中目录)→ 关预览,而非 ?? 0 跳到第一项
                // (跳第一项会让用户莫名其妙地预览一个没选中的文件)。
                guard let index = self.model.cursorIndex else { self.quickLook.close(); return }
                self.quickLook.updateItems(self.model.sortedItems.map(\.url), current: index)
            }

        // 内容/视图模式/下钻态变化 → 面板高度自适应重算(#14)。objectWillChange 高频,但
        // relayoutHeight 内部高度无变化即跳过,选中等不改高度的变更天然 no-op。
        relayoutCancellable = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.panelController.relayoutHeight() }

        // 就地重命名进行中 → .renaming 抑制瞬态面板 auto-hide(spec §4.6)。
        renameCancellable = model.$renamingItemID
            .removeDuplicates()
            .sink { [weak self] id in
                guard let self else { return }
                if id != nil { self.autoHide.begin(.renaming) } else { self.autoHide.end(.renaming) }
            }

        // 增删/重排绑定(设置页或添加文件夹)→ 统一在此重建镜像(保持设置与面板一致)。
        bindingsCancellable = environment.bindingStore.$bindings
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let select = self.pendingSelectBindingID
                self.pendingSelectBindingID = nil
                self.rebuildMirrors(selecting: select)
            }
    }

    // MARK: - 呈现/收回(瞬态)

    func toggle() {
        // 已 Pin:全局快捷键切换常驻浮窗显/隐,不跌进瞬态分支(否则会把用户拽出 Pin 态)。
        if model.windowMode == .pinned {
            panelController.isVisible ? panelController.hide() : panelController.revealPinned()
            return
        }
        if panelController.isTransientShown {
            hideTransient()
        } else {
            present()
        }
    }

    private func present() {
        // 已 Pin:常驻浮窗才是当前 UI,热区/兜底呼出不应把状态机拽回瞬态(防御 hotZone 直连路径)。
        guard model.windowMode != .pinned else { return }
        // 幂等:面板已展开时重复呼出(hover 进面板再回刘海会再次跨界触发)应是 no-op,
        // 否则会重跑展开动画并重新 armCurrent() 触发 TCC 探针。
        guard !panelController.isTransientShown else { return }
        guard let screen = screens.activeScreen else { return }
        model.windowMode = .transient
        model.armCurrent()   // 打开面板 = 用户动作,可触发当前 tab 的 TCC 探针
        panelController.presentTransient(below: screens.resolution(for: screen), itemCount: model.sortedItems.count)
        observeTransientFocus()
    }

    private func hideTransient() {
        panelController.hide()
        teardownTransientFocusObserver()
    }

    private func observeTransientFocus() {
        teardownTransientFocusObserver()
        guard let panel = panelController.panel else { return }
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

    // MARK: - Pin 切换(瞬态 ↔ 常驻,同一窗口原地切模式)

    private func togglePin() {
        model.windowMode == .pinned ? unpin() : pin()
    }

    private func pin() {
        model.windowMode = .pinned
        teardownTransientFocusObserver()   // 常驻不靠 resignKey 收
        panelController.setPinned(true)    // 就地切模式,frame 不动
    }

    private func unpin() {
        model.windowMode = .transient
        panelController.setPinned(false)   // 就地回瞬态,恢复"移开即收";frame 不动
        observeTransientFocus()
    }

    /// ⌘W / Esc:未 pin 收回瞬态;已 pin 则隐藏常驻浮窗(spec §4.6)。
    private func closeFromKeyboard() {
        hideTransient()
    }

    // MARK: - 文件操作(M3)

    private func open(_ item: FileItem) {
        // dataless(iCloud 未下载)文件:先按需下载再交系统,期间 cell 显 spinner——不把未下载
        // URL 直接丢 NSWorkspace(否则可能打开占位/失败,spec §4.1.2,#13)。
        guard item.isDataless else { ops.open(item.url); return }
        // 去重:同一文件正在下载则忽略重复双击(否则起多个 Task,先结束者会提前清掉 spinner)。
        guard !model.downloadingIDs.contains(item.id) else { return }
        model.beginDownload(item.id)
        Task {
            defer { model.endDownload(item.id) }
            do {
                try await ICloudStatus.ensureDownloaded(item.url)
                ops.open(item.url)
            } catch {
                // 不静默吞错(CLAUDE.md):下载失败正面暴露给用户,而非只记日志后无声消失。
                Log.files.error("按需下载失败,未打开:\(error.localizedDescription, privacy: .public)")
                presentDownloadFailure(name: item.name, error: error)
            }
        }
    }

    /// 按需下载失败 → 可见提示(用户双击的动作失败必须让其知道,不靠隐形日志)。
    private func presentDownloadFailure(name: String, error: Error) {
        presentFailure(title: "无法下载「\(name)」", error: error)
    }

    /// 用户动作失败的统一可见提示(下载/拖入/未来的文件操作共用,不靠隐形日志吞错)。
    private func presentFailure(title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
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

    /// 空白处右键:背景菜单(新建文件夹 / 粘贴),落点 = 当前目录。
    private func makeBackgroundMenu(_ anchor: NSView) -> NSMenu? {
        guard let dir = model.currentMirror?.currentDirectory else { return nil }
        return contextMenu.makeBackgroundMenu(directory: dir, anchorView: anchor)
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
            // 不静默吞错(CLAUDE.md):拖入 copy/move 失败(权限/磁盘满/冲突)必须让用户知道,
            // 与双击下载失败提示对称,而非只记日志后无声消失。
            Log.files.error("拖入处理失败:\(error.localizedDescription, privacy: .public)")
            presentFailure(title: "无法移入文件", error: error)
        }
    }

    // MARK: - 绑定文件夹管理

    /// 重建镜像(保留/指定当前 tab)。若面板正显示,重新 arm 当前 mirror —— 否则绑定变更后
    /// 当前 tab 会停在 idle("载入中…")不扫描(Codex review:双重 rebuild 把已 arm 的重置)。
    private func rebuildMirrors(selecting id: FolderBinding.ID? = nil) {
        model.rebuildMirrors(from: environment.bindingStore.bindings, selecting: id)
        if isPanelVisible { model.armCurrent() }
    }

    private var isPanelVisible: Bool {
        panelController.isVisible
    }

    /// 添加文件夹:NSOpenPanel 选目录 → 生成普通 bookmark → 持久化。
    /// 重建由 bindingStore.$bindings 的订阅统一驱动(selecting 新 id),避免双重 rebuild。
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
        pendingSelectBindingID = binding.id   // 让随后的订阅重建选中这个新文件夹
        environment.bindingStore.add(binding)
    }

    private func removeFolder(_ id: FolderBinding.ID) {
        environment.bindingStore.remove(id: id)
    }

    private var pendingSelectBindingID: FolderBinding.ID?
}
