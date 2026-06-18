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
    /// 触发方式偏好(热区开关/hover 延迟/快捷键)单一真相源,设置页共绑。
    private let triggerPrefs = TriggerPreferences()
    /// 最近一次注册成功的快捷键(新键注册失败时回退用,保证兜底呼出永远有效)。
    private var lastGoodHotkey: HotkeyPreference?
    private lazy var quickLook = QuickLookController(autoHide: autoHide)
    private let undoManager = FileOpUndoManager()
    private lazy var ops = FileOperations(undo: undoManager)
    private lazy var contextMenu = ContextMenuBuilder(
        ops: ops, autoHide: autoHide,
        onRequestRename: { [weak self] url in self?.beginRenameSafely(url) },
        presentModal: { [weak self] body in
            guard let self else { body(); return }
            self.withModalContext(body)
        }
    )

    /// tab 栏「+」的添加菜单(选择文件夹 / 前往路径)与 tab 右键菜单(移除)。
    /// NSMenu+抑制,见 FolderTabMenus.swift。
    private lazy var addMenu = AddFolderMenuPresenter(
        autoHide: autoHide,
        onChooseFolder: { [weak self] in self?.addFolder() },
        onGoToPath: { [weak self] in self?.model.beginPathInput() }
    )
    private lazy var tabMenu = TabContextMenuPresenter(
        autoHide: autoHide,
        onRemove: { [weak self] id in self?.removeFolder(id) }
    )
    /// 底栏排序菜单(NSMenu+抑制),见 SortMenuPresenter.swift。
    private lazy var sortMenu = SortMenuPresenter(autoHide: autoHide, model: model)

    private lazy var actions = PanelActions(
        onOpen: { [weak self] in self?.open($0) },
        onTogglePin: { [weak self] in self?.togglePin() },
        onAddFolder: { [weak self] in self?.addFolder() },
        onAddMenu: { [weak self] anchor in self?.addMenu.present(from: anchor) },
        onTabMenu: { [weak self] id in self?.tabMenu.makeMenu(for: id) },
        onSortMenu: { [weak self] anchor in self?.sortMenu.present(from: anchor) },
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
        onDropURLs: { [weak self] urls, modifiers, destination in
            self?.handleDrop(urls, modifiers: modifiers, destination: destination)
        },
        onRename: { [weak self] url, newName in self?.rename(url, to: newName) ?? false },
        onCopy: { [weak self] urls in self?.ops.copyToPasteboard(urls) },
        onCut: { [weak self] urls in self?.ops.cut(urls) },
        onCopyPath: { [weak self] urls in self?.ops.copyPaths(urls) },
        onTrash: { [weak self] urls in self?.ops.trash(urls) },
        onPaste: { [weak self] in self?.paste() },
        onUndo: { [weak self] in self?.undoLast() },
        onRedo: { [weak self] in self?.redoLast() },
        onNewFolder: { [weak self] in self?.newFolderInCurrentDirectory() },
        onClose: { [weak self] in self?.closeFromKeyboard() },
        onOpenSettings: { [weak self] in self?.openSettings() },
        onGoToPath: { [weak self] input in self?.goToPath(input) ?? false },
        onPinTemporary: { [weak self] in self?.pinTemporary() },
        onMoveTab: { [weak self] from, to in self?.moveTab(from: from, to: to) },
        onDropFolders: { [weak self] urls, index in self?.dropFolders(urls, at: index) },
        onDragBegin: { [weak self] in self?.autoHide.begin(.draggingOut) },
        onDragEnd: { [weak self] in self?.autoHide.end(.draggingOut) },
        onIconSizeEditing: { [weak self] editing in
            editing ? self?.autoHide.begin(.iconSizeSlider) : self?.autoHide.end(.iconSizeSlider)
        }
    )
    private lazy var panelController = PanelController(
        model: model, motion: motion, actions: actions
    )
    /// 自管设置窗口(SwiftUI Settings scene 在 accessory app 无法编程打开,见 SettingsWindowController)。
    /// 注入同一个 PanelModel(showHidden 单真相源)与统一的 addFolder 路径。
    private lazy var settingsWindow = SettingsWindowController(
        environment: environment, model: model, triggerPrefs: triggerPrefs,
        onAddFolder: { [weak self] in self?.addFolder() }
    )

    /// 打开设置窗口(菜单栏「设置…」、主菜单 ⌘, 与面板内 ⌘, 共用入口)。
    func openSettings() {
        settingsWindow.show()
    }

    private var resignObserver: NSObjectProtocol?
    private var screenCancellable: AnyCancellable?
    private var renameCancellable: AnyCancellable?
    private var pathInputCancellable: AnyCancellable?
    private var renameSweepCancellable: AnyCancellable?
    private var bindingsCancellable: AnyCancellable?
    private var triggerPrefsCancellable: AnyCancellable?
    private var selectionCancellable: AnyCancellable?
    private var quickLookContentCancellable: AnyCancellable?
    private var relayoutCancellable: AnyCancellable?

    init(environment: AppEnvironment) {
        self.environment = environment
        wire()
        hotZone.refreshPlacement()
        rebuildMirrors()
        hotkey.onTrigger = { [weak self] in self?.toggle() }
        applyTriggerPreferences()   // 热区开关/延迟 + 注册快捷键(默认 ⌃⌥⌘Space 兜底呼出)
        // objectWillChange 在赋值前发布 → 推迟一拍读新值再应用。
        triggerPrefsCancellable = triggerPrefs.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.applyTriggerPreferences() }
    }

    /// 把触发偏好应用到触发系统。快捷键注册失败(撞系统占用等)→ 可见提示并回退到上一个
    /// 可用键(兜底呼出不能无声失效)。
    private func applyTriggerPreferences() {
        hotZone.isEnabled = triggerPrefs.hotZoneEnabled
        hotZone.setHoverDelay(triggerPrefs.hoverDelay)
        let pref = triggerPrefs.hotkey
        if pref == lastGoodHotkey { return }   // 热区项变化不必反复重注册同一热键
        if hotkey.register(keyCode: pref.keyCode, modifiers: pref.carbonModifiers) {
            lastGoodHotkey = pref
        } else {
            presentFailure(title: "无法注册快捷键 \(pref.display)",
                           error: HotkeyRegistrationError(display: pref.display))
            // 回退上一个可用键(写回偏好,设置页同步显示;sink 再触发时命中 == 守卫不再循环)。
            // 启动期第一发就失败(持久化了已被占用的键)→ 回退出厂默认。
            if let lastGoodHotkey, lastGoodHotkey != pref {
                triggerPrefs.hotkey = lastGoodHotkey
            } else if pref != .default {
                triggerPrefs.hotkey = .default
            }
        }
    }

    deinit {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    // MARK: - 接线

    private func wire() {
        // 异步文件操作(recycle 完成回调)失败 → 可见提示(throws 上抛不到的路径)。
        ops.onError = { [weak self] title, error in self?.presentFailure(title: title, error: error) }
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
        // QL dataless 按需下载起止/失败 → cell spinner + 可见提示(与双击打开路径对称,
        // 空格预览不再是"静默等 30s、失败无声"的黑箱)。URL 即 FileItem.ID。
        quickLook.onDownloadBegin = { [weak self] url in self?.model.beginDownload(url) }
        quickLook.onDownloadEnd = { [weak self] url in self?.model.endDownload(url) }
        quickLook.onDownloadFailed = { [weak self] url, error in
            Log.files.error("预览按需下载失败:\(error.localizedDescription, privacy: .public)")
            self?.presentFailure(title: "无法下载「\(url.lastPathComponent)」", error: error)
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

        // 路径输入条展开中 → .pathInput 抑制(输入路径常要对照别处,鼠标离开不该抽走面板)。
        pathInputCancellable = model.$pathInputVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                guard let self else { return }
                if visible { self.autoHide.begin(.pathInput) } else { self.autoHide.end(.pathInput) }
            }

        // 就地重命名进行中 → .renaming 抑制瞬态面板 auto-hide(spec §4.6)。
        renameCancellable = model.$renamingItemID
            .removeDuplicates()
            .sink { [weak self] id in
                guard let self else { return }
                if id != nil { self.autoHide.begin(.renaming) } else { self.autoHide.end(.renaming) }
            }
        // 重命名残留清扫:编辑期间条目被外部删除/改名(FSEvents 重扫后 id 消失),重命名框随
        // cell 一起卸载但 renamingItemID 还在 → .renaming 抑制源泄漏,面板永不自动收回。
        // 条目不在当前列表即结束重命名(endRename 触发上方 sink 解除抑制)。
        renameSweepCancellable = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self, let id = self.model.renamingItemID else { return }
                if !self.model.sortedItems.contains(where: { $0.id == id }) {
                    self.model.endRename()
                }
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
        // 隐藏时与 hideTransient 同口径收口(作废待呈现预览 + 关路径条),否则 .pathInput
        // 抑制源跨显/隐残留,unpin 后瞬态面板永不自动收(Codex review)。
        if model.windowMode == .pinned {
            if panelController.isVisible {
                quickLook.cancelPendingPreview()
                model.endPathInput()
                autoHide.end(.iconSizeSlider)   // 同 hideTransient:防 pinned 拖滑块中途隐藏致抑制泄漏,unpin 后瞬态永不收
                panelController.hide()
            } else {
                panelController.revealPinned()
            }
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
        quickLook.cancelPendingPreview()   // 收面板即作废"下载中未呈现"的预览(防迟到弹出)
        model.endPathInput()               // 路径条随面板收口,否则 .pathInput 抑制源跨次泄漏
        model.invalidatePendingRename()    // 作废在途的慢速单击延迟重命名,防收起后回调泄漏 .renaming 抑制
        autoHide.end(.iconSizeSlider)      // 拖滑块中途被强关 → onEditingChanged(false) 不触发,在此收口
                                           // 防 .iconSizeSlider 跨次泄漏(end 对未配对调用幂等);松手再 end 也短路
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

    /// 在瞬态面板可见时呈现任意模态(NSOpenPanel / NSAlert / 冲突弹窗)的**统一**入口:
    /// ① 挂 `.modalDialog` 抑制(模态成 key + 鼠标移去都会触发收回,不抑制则模态期间面板被挤走);
    /// ② 把 panel.level 临时降到 `.floating` —— 瞬态级别(`.statusBar`≈25)高于模态级别(≈8),不降则
    ///    Niche 面板浮在模态上方遮挡它(选目录/冲突确认看不见)。runModal 同步阻塞,body 返回后 defer
    ///    立即恢复,无竞态。**所有模态点共用此一处**,杜绝"只有 addFolder 配对、其余漏配"的散落 bug。
    /// 保存/恢复**当前** level(非写死),嵌套(body 内再调本方法或 presentFailure)与 pinned 态都安全。
    func withModalContext(_ body: () -> Void) {
        autoHide.begin(.modalDialog)
        let saved = panelController.panel?.level
        if saved != nil { panelController.panel?.level = .floating }
        defer {
            if let saved { panelController.panel?.level = saved }
            autoHide.end(.modalDialog)
        }
        body()
    }

    /// 用户动作失败的统一可见提示(下载/拖入/文件操作共用,不靠隐形日志吞错)。
    /// 走 withModalContext:提示期间抑制收回 + 降级面板让 NSAlert 不被遮挡。
    private func presentFailure(title: String, error: Error) {
        withModalContext { FailureAlert.present(title: title, error: error, autoHide: autoHide) }
    }

    /// ⌘Z 撤销:栈空静默(无事可撤不是错误);恢复失败弹提示(记录留栈顶,修正后可重试)。
    private func undoLast() {
        do { try ops.undoLast() }
        catch {
            Log.files.error("撤销失败:\(error.localizedDescription, privacy: .public)")
            presentFailure(title: "无法撤销", error: error)
        }
    }

    /// ⇧⌘Z 重做:语义与撤销对称(栈空静默,失败弹提示且记录留栈可重试)。
    private func redoLast() {
        do { try ops.redoLast() }
        catch {
            Log.files.error("重做失败:\(error.localizedDescription, privacy: .public)")
            presentFailure(title: "无法重做", error: error)
        }
    }

    /// ⌘⇧N 新建文件夹(落点 = 当前目录,与背景右键菜单同款:新建即就地重命名)。
    private func newFolderInCurrentDirectory() {
        guard let dir = model.currentMirror?.currentDirectory else { return }
        do {
            let url = try ops.newFolder(in: dir)
            beginRenameSafely(url)
        } catch {
            Log.files.error("新建文件夹失败:\(error.localizedDescription, privacy: .public)")
            presentFailure(title: "无法新建文件夹", error: error)
        }
    }

    /// 进入就地重命名前确保条目已在镜像里:新建文件夹靠 FSEvents 异步重扫入列,而重命名残留
    /// 清扫(renameSweep)会把"不在 sortedItems 里的 renamingItemID"立即清掉 —— 不先同步
    /// refresh,新建后的重命名框会被清扫秒杀(出现一帧就消失)。顺带选中该项(Finder 语义)。
    private func beginRenameSafely(_ url: URL) {
        if !model.sortedItems.contains(where: { $0.id == url }) {
            model.currentMirror?.refresh()
        }
        model.selectSingle(url)
        model.beginRename(url)
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

    /// ⌘V 粘贴:同名冲突会弹 ConflictPrompt 模态 → withModalContext(抑制收回 + 降级面板防遮挡);
    /// 失败弹可见提示(此前只记日志,用户视角"按了没反应")。
    private func paste() {
        guard let dir = model.currentMirror?.currentDirectory else { return }
        withModalContext {
            do { try ops.paste(into: dir, resolve: ConflictPrompt.ask) }
            catch {
                Log.files.error("粘贴失败:\(error.localizedDescription, privacy: .public)")
                presentFailure(title: "无法粘贴", error: error)
            }
        }
    }

    // MARK: - 路径输入(前往,spec:specs/2026-06-10-niche-path-input-design.md)

    /// 提交「前往」。返回 false = 路径不存在/非法(输入条显错留条)。
    /// 目录:当前 tab 根内 → 当前 mirror 下钻(上下文/面包屑完整);根外 → 临时 tab(单槽)。
    /// 文件:默认 app 打开 + 收面板(用完即走)。进入受保护目录由用户显式输入驱动,符合
    /// "TCC 按需触发"不变量(arm 在 openTemporary/enter 的用户动作路径上)。
    private func goToPath(_ input: String) -> Bool {
        switch PathCompleter.resolve(input) {
        case .missing:
            return false
        case let .file(url):
            model.endPathInput()
            hideTransient()
            openExternalFile(url)
            return true
        case let .directory(url):
            model.endPathInput()
            // 已有正式 tab 覆盖该路径 → 切过去下钻(不开重复的临时 tab);当前 tab 优先。
            let formals = ([model.currentMirror].compactMap { $0 } + model.mirrors)
                .filter { !$0.isTemporary }
            if let host = formals.first(where: {
                DirectoryMirror.contains(ancestor: $0.rootURL, descendant: url)
            }) {
                if let index = model.mirrors.firstIndex(where: { $0 === host }),
                   index != model.currentTab {
                    model.selectTab(index)   // 切 tab 即 arm(用户动作)
                }
                host.enter(url)              // enter 自校验仍在根内;url == 根时回到根
                model.clearSelection()
            } else {
                model.openTemporary(url)
            }
            return true
        }
    }

    /// 前往的目标是文件:默认 app 打开。dataless iCloud 占位先显式下载(与 open(_:) 同理,
    /// 但条目不在任何镜像里、面板已收,无 cell 可挂 spinner;失败仍要可见提示)。
    private func openExternalFile(_ url: URL) {
        guard ICloudStatus.isDataless(url) else { ops.open(url); return }
        Task {
            do {
                try await ICloudStatus.ensureDownloaded(url)
                ops.open(url)
            } catch {
                Log.files.error("前往目标下载失败:\(error.localizedDescription, privacy: .public)")
                presentFailure(title: "无法下载「\(url.lastPathComponent)」", error: error)
            }
        }
    }

    /// 把临时 tab 钉成正式绑定:生成 bookmark 入 BindingStore,随后的订阅重建会让临时槽
    /// 让位给同路径正式 tab(rebuildMirrors 的去重逻辑),并精确选中它。
    private func pinTemporary() {
        guard let temp = model.temporaryMirror else { return }
        let url = temp.rootURL
        let binding = FolderBinding(bookmarkData: DirectoryMirror.makeBookmark(for: url), path: url.path)
        pendingSelectBindingID = binding.id
        environment.bindingStore.add(binding)
    }

    /// 拖动重排正式 tab:保持当前选中文件夹(按 binding.id 重选,不跳 tab),走 BindingStore.move
    /// 持久化。重建由 bindingStore.$bindings 订阅统一驱动(与增删同路径)。
    private func moveTab(from: Int, to: Int) {
        pendingSelectBindingID = model.currentMirror?.binding.id
        environment.bindingStore.move(from: IndexSet(integer: from), to: to)
    }

    /// 拖文件夹进 tab 栏 → 固定为常驻绑定。只接文件夹,去重已绑定路径;按落点 index 定位插入,
    /// 选中落点处第一个。复用 pinTemporary 同款 bookmark + pendingSelect 路径,重建由 $bindings 订阅统一驱动。
    private func dropFolders(_ urls: [URL], at index: Int?) {
        let existing = Set(environment.bindingStore.bindings.map(\.path))
        let folders = urls.filter { url in
            guard !url.path.isEmpty, !existing.contains(url.path) else { return false }
            var isDir: ObjCBool = false   // FileManager 命中真实文件系统:跨进程 resourceValues 不可靠
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
        guard !folders.isEmpty else { return }
        let newBindings = folders.map {
            FolderBinding(bookmarkData: DirectoryMirror.makeBookmark(for: $0), path: $0.path)
        }
        pendingSelectBindingID = newBindings.first?.id   // 选中落点处第一个(松手即看到它被选中)
        if let index {
            environment.bindingStore.insert(newBindings, at: index)   // 定位插入到光标落点
        } else {
            environment.bindingStore.add(newBindings)                 // 几何未就绪:末尾追加兜底
        }
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
    /// destination = 显式落点(拖到目录格子/行上,Finder 语义:落进那个文件夹);nil = 当前目录。
    private func handleDrop(_ urls: [URL], modifiers: NSEvent.ModifierFlags, destination: URL?) {
        guard let dir = destination ?? model.currentMirror?.currentDirectory else { return }
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
        model.clearDropTarget()   // 落地即收口高亮(列表多列 region 的计数不依赖逐一 exit)

        // 与 dropUpdated 角标共用同一聚合决策(混合来源任一跨卷 → 整体 copy):角标说什么就
        // 做什么。此前逐源各自决策,混合时角标显 copy、同卷项却被 move(Codex review)。
        let sameVolume = DragSemantics.aggregateSameVolume(sources: incoming, destination: dir)
        let operation = DragSemantics.resolve(sameVolume: sameVolume, modifiers: modifiers)
        autoHide.begin(.dragging)
        defer { autoHide.end(.dragging) }
        // 冲突弹窗(ConflictPrompt)同走 withModalContext:否则瞬态模式下 NSAlert 被面板遮挡。
        withModalContext {
            do {
                switch operation {
                case .copy: try ops.copy(incoming, to: dir, resolve: ConflictPrompt.ask)
                case .move: try ops.move(incoming, to: dir, resolve: ConflictPrompt.ask)
                }
            } catch {
                // 不静默吞错(CLAUDE.md):拖入 copy/move 失败(权限/磁盘满/冲突)必须让用户知道,
                // 与双击下载失败提示对称,而非只记日志后无声消失。
                Log.files.error("拖入处理失败:\(error.localizedDescription, privacy: .public)")
                presentFailure(title: "无法移入文件", error: error)
            }
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
        withModalContext {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "添加"
            guard panel.runModal() == .OK, let url = panel.url else { return }

            let bookmark = DirectoryMirror.makeBookmark(for: url)
            let binding = FolderBinding(bookmarkData: bookmark, path: url.path)
            pendingSelectBindingID = binding.id   // 让随后的订阅重建选中这个新文件夹
            environment.bindingStore.add(binding)
        }
    }

    private func removeFolder(_ id: FolderBinding.ID) {
        environment.bindingStore.remove(id: id)
    }

    private var pendingSelectBindingID: FolderBinding.ID?
}
