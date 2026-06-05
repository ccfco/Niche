import AppKit
import Combine

/// 顶层编排:把触发热区、瞬态(DNK)/常驻(PinnedPanel)两个呈现宿主、焦点抑制模型
/// 接成一个可切换的窗口状态机(spec §4.6:Pin 是窗口模式切换,从第一行就做成状态机)。
///
/// M1 用单文件夹(用户主目录顶层)只读骨架验证窗口模型;M2 接入多 tab + 镜像数据源。
@MainActor
final class NicheController {
    private let environment: AppEnvironment
    private let screens = ScreenObserver()
    private let model = PanelModel()
    private let autoHide = AutoHideCoordinator()
    private let hotZone = HotZoneController()
    private lazy var transient = NotchExpansion(
        model: model, onOpen: { [weak self] in self?.open($0) },
        onTogglePin: { [weak self] in self?.togglePin() }
    )
    private lazy var pinned = PinnedPanelController(
        model: model, onOpen: { [weak self] in self?.open($0) },
        onTogglePin: { [weak self] in self?.togglePin() }
    )

    private var resignObserver: NSObjectProtocol?
    private var screenCancellable: AnyCancellable?

    init(environment: AppEnvironment) {
        self.environment = environment
        wire()
        placeHotZone()
        loadSkeletonFolder()
    }

    deinit {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
    }

    // MARK: - 接线

    private func wire() {
        hotZone.onTrigger = { [weak self] draggingFile in
            self?.present(draggingFile: draggingFile)
        }
        autoHide.onShouldHide = { [weak self] in
            Task { await self?.hideTransient() }
        }
        // ownedWindows:瞬态面板本体 +(M2/M3 接入的)派生辅助窗口(QuickLook/菜单/重命名)。
        // 失焦判定靠它排除"焦点只是转移到自己派生窗口"。辅助窗口在对应功能落地时并入。
        autoHide.ownedWindows = { [weak self] in
            [self?.transient.panel].compactMap { $0 }
        }
        // 屏幕参数变化:重新贴热区(接拔显示器、分辨率变化)。复用 ScreenObserver 的单一
        // observer(经 generation 发布),避免在此重复注册一个无法注销的 NotificationCenter observer。
        screenCancellable = screens.$generation
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.placeHotZone() }
    }

    private func placeHotZone() {
        guard let screen = screens.activeScreen else { return }
        hotZone.place(on: screens.resolution(for: screen))
    }

    // MARK: - 呈现/收回(瞬态)

    /// 公开入口:菜单栏"呼出"/全局快捷键调用。
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
        reload()
        Task {
            await transient.expand(on: screen)
            observeTransientFocus()
        }
    }

    private func hideTransient() async {
        await transient.hide()
        teardownTransientFocusObserver()
    }

    /// 瞬态面板的失焦监听:resignKey 时交给 AutoHideCoordinator 判定(排除辅助窗口/抑制源)。
    private func observeTransientFocus() {
        teardownTransientFocusObserver()
        guard let panel = transient.panel else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel, queue: .main
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
        // 取瞬态当前 frame 实现"原地变常驻";拿不到则用活跃屏刘海下方默认位置。
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

    // MARK: - M1 骨架数据

    private func loadSkeletonFolder() { reload() }

    /// M1:列用户主目录顶层(非 TCC 受保护,启动不弹权限,符合"不启动弹")。
    private func reload() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let snapshot = try? DirectorySnapshot.capture(directory: home, showHidden: model.showHidden)
        model.items = snapshot?.fileItems ?? []
    }
}
