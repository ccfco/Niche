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

    private lazy var actions = PanelActions(
        onOpen: { [weak self] in self?.open($0) },
        onTogglePin: { [weak self] in self?.togglePin() },
        onAddFolder: { [weak self] in self?.addFolder() },
        onRemoveFolder: { [weak self] in self?.removeFolder($0) },
        onQuickLook: { [weak self] urls, index in self?.quickLook.preview(urls: urls, at: index) }
    )
    private lazy var transient = NotchExpansion(model: model, actions: actions)
    private lazy var pinned = PinnedPanelController(model: model, actions: actions)

    private var resignObserver: NSObjectProtocol?
    private var screenCancellable: AnyCancellable?

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

    // MARK: - 文件操作(M1 仅打开;M3 补全)

    private func open(_ item: FileItem) {
        NSWorkspace.shared.open(item.url)
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
