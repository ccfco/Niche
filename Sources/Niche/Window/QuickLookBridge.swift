import AppKit
import QuickLookUI

/// Quick Look 预览桥接(spec §4.5 完全一致 + §4.6:QLPreviewPanel 是 app 级共享面板,
/// SwiftUI-primary 架构需 AppKit 桥接;且预览前对 iCloud dataless 文件**显式下载**再交给预览)。
///
/// 同时驱动 AutoHideCoordinator 的 .quickLook 抑制源:预览活跃期间瞬态面板不自动收回
/// (QLPreviewPanel becomeKey 会让面板 resignKey,若不抑制会出现"预览浮空、面板已收回")。
@MainActor
final class QuickLookController: NSObject {
    private let autoHide: AutoHideCoordinator
    private var urls: [URL] = []
    private var index = 0
    private var closeObserver: NSObjectProtocol?
    /// 监听 QL 内 ←→ 翻页(currentPreviewItemIndex 变化)是否已注册,避免重复 add/remove KVO。
    private var observingIndex = false
    /// 正在为哪个 index 下载 dataless 目标:防同 index 双触发(同步推送 + selectionCancellable 异步)
    /// 与快速翻页时重复起轮询 Task。本地文件不经此(同步即切)。
    private var pendingDownloadIndex: Int?
    /// 被 KVO 观察的 QL 面板弱引用:供 deinit 移除 observer,避免在 nonisolated deinit 里调
    /// @MainActor 的 QLPreviewPanel.shared()(消除隔离告警 + 守 deinit 红线)。
    private weak var observedPanel: QLPreviewPanel?

    /// 宿主面板当前层级提供者(由 NicheController 注入):QL present 时抬到「宿主 +1」浮于面板之上。
    /// 返回 nil(宿主面板不存在)则不抬层级,保留 QL 系统默认 —— 不臆造一个可能盖住菜单/通知的高层。
    var hostWindowLevel: (() -> NSWindow.Level?)?
    /// QL 内翻页 → 回写面板选中(NicheController 据此把选中停在最后预览项)。
    var onIndexChange: ((Int) -> Void)?
    /// dataless 按需下载起止/失败(URL = 面板条目原 URL,即 FileItem.ID):宿主据此显示 cell
    /// spinner 与失败提示 —— 与双击打开路径对称,空格预览不再是"静默等 30s、失败无声"的黑箱。
    var onDownloadBegin: ((URL) -> Void)?
    var onDownloadEnd: ((URL) -> Void)?
    var onDownloadFailed: ((URL, Error) -> Void)?
    /// 预览请求代次:下载期间用户关预览/关面板/再次请求 → 旧 Task 的 present 作废(防迟到的
    /// 下载完成把已关的预览重新拉起)。
    private var previewGeneration = 0
    /// 正在为初次预览下载的条目(同一文件重复按空格去重;与翻页路径的 pendingDownloadIndex 分账)。
    private var pendingPreviewURL: URL?

    init(autoHide: AutoHideCoordinator) {
        self.autoHide = autoHide
        super.init()
    }

    /// 兜底:控制器释放前若仍在 observing,移除 KVO / 通知 observer(Apple KVO 要求释放前显式移除)。
    /// deinit 是 nonisolated —— 只做 observer 移除,不调 @MainActor 方法(守 CLAUDE.md deinit 红线)。
    deinit {
        if observingIndex { observedPanel?.removeObserver(self, forKeyPath: "currentPreviewItemIndex") }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }

    /// 当前预览面板窗口(供 AutoHideCoordinator.ownedWindows 排除"焦点转到预览窗口")。
    var previewPanel: NSWindow? {
        QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil
    }

    /// QL 当前是否由本控制器驱动且可见(用于选中跟随 / 内容刷新的前置判定)。
    var isActive: Bool {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() else { return false }
        return panel.isVisible && panel.dataSource === self
    }

    /// 预览一组 URL(通常是当前可见排序后的条目),定位到 index。
    /// dataless 文件先显式下载到本地再预览(§4.1.2:等可用后再把 URL 交给 QLPreviewPanel)。
    func preview(urls: [URL], at index: Int) {
        guard !urls.isEmpty, urls.indices.contains(index) else { return }
        let itemURL = urls[index]   // 面板条目原 URL(= FileItem.ID),spinner 挂在该 cell 上
        // 同一文件下载中重复按空格:no-op(与双击打开的 downloadingIDs 去重同理)——否则旧
        // Task 的 defer onDownloadEnd 会提前清掉 spinner,且双 Task 重复轮询(Codex review)。
        guard pendingPreviewURL != itemURL else { return }
        self.urls = urls
        self.index = index
        previewGeneration += 1
        let gen = previewGeneration

        Task {
            do {
                // 仅对当前要看的这个文件按需下载,不递归、不批量(§4.1.2)。下载合同必须作用于
                // **解析后的目标**:alias 指向 dataless iCloud 目标时,只下 alias 自身(本地 45B)
                // 等于没下,数据源解析出的 dataless 目标会绕过下载直接丢给 QL(Codex review)。
                let target = Self.resolvedForPreview(itemURL)
                if ICloudStatus.isDataless(target) {
                    pendingPreviewURL = itemURL
                    onDownloadBegin?(itemURL)
                    defer {
                        onDownloadEnd?(itemURL)
                        if pendingPreviewURL == itemURL { pendingPreviewURL = nil }
                    }
                    try await ICloudStatus.ensureDownloaded(target)
                }
            } catch {
                // 下载失败/超时:不把 dataless URL 交给 Quick Look(spec §4.1.2),且必须可见
                // (与双击打开路径对称)—— 此前 catch { return } 静默,用户按空格后 30s 无任何动静。
                // 已被新请求/关面板作废的旧失败不弹(迟到的过期提示只会让用户困惑)。
                if gen == previewGeneration { onDownloadFailed?(itemURL, error) }
                return
            }
            // 下载期间预览被关闭/被新请求顶替 → 不再拉起(防迟到 present 重开预览)。
            guard gen == previewGeneration else { return }
            present()
        }
    }

    /// 主动关闭预览(键盘单一权威的空格 toggle / Esc 关入口)。
    /// orderOut 不发 NSWindow.willClose,故显式走 handleClose 清理;handleClose 幂等(Set.remove +
    /// observer nil 守卫),与原生关闭(Esc/红点 → willClose)路径重入也安全。
    func close() {
        cancelPendingPreview()
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() else { return }
        panel.orderOut(nil)
        handleClose()
    }

    /// 作废"下载中、QL 尚未呈现"的预览请求:面板收回(Esc/⌘W/自动隐藏)时必须调——
    /// 此时 QL 不可见,close() 的 orderOut 路径走不到,迟到的下载完成会把 QL 凭空弹出来
    /// 浮在已收起的面板原位(Codex review)。
    func cancelPendingPreview() {
        previewGeneration += 1
    }

    private func present() {
        guard let panel = QLPreviewPanel.shared() else { return }
        autoHide.begin(.quickLook)
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = index
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
        // 抬到宿主面板之上:本面板处于异常高层(瞬态 .statusBar),QL 默认层级低会被压住,
        // 出现"预览在面板后面看不见"。设为宿主当前层级 +1(瞬态/常驻都覆盖);宿主缺失不抬。
        if let provider = hostWindowLevel, let hostLevel = provider() {
            panel.level = NSWindow.Level(rawValue: hostLevel.rawValue + 1)
        }
        beginObservingIndex(panel)

        // QLPreviewPanel 无 didClose 回调;观察其 NSWindow.willClose 释放抑制。
        // 先移除可能残留的旧 observer(连续预览时避免覆盖泄漏)。
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleClose() }
        }
    }

    // MARK: - 选中跟随(面板 ↔ QL 双向,各带相等守卫防回环)

    /// 面板选中变化 → QL 跳到该项(仅 active 且 index 有效且与当前不同)。
    /// 切换目标若是 dataless iCloud 占位 → 先显式下载再切(§4.1.2:等可用再交 QL,否则预览空白);
    /// 本地文件同步即切,保方向键即时跟随。
    func syncCurrentIndex(_ newIndex: Int) {
        guard isActive, urls.indices.contains(newIndex), let panel = QLPreviewPanel.shared() else { return }
        guard panel.currentPreviewItemIndex != newIndex else { return }
        index = newIndex
        downloadIfNeeded(at: newIndex) { panel.currentPreviewItemIndex = newIndex }
    }

    /// 切到 newIndex 前确保目标可用:本地/非 iCloud 文件同步执行 apply(零延迟,保方向键即时跟随);
    /// dataless 占位先显式下载再 apply,期间用户又翻走(index 变)或预览已关则放弃(防快速翻页乱序)。
    /// pendingDownloadIndex 防同 index 重复起轮询 Task(同步推送 + 异步 selectionCancellable 双触发)。
    private func downloadIfNeeded(at idx: Int, then apply: @escaping () -> Void) {
        let target = Self.resolvedForPreview(urls[idx])
        guard ICloudStatus.isDataless(target) else { apply(); return }
        guard pendingDownloadIndex != idx else { return }
        pendingDownloadIndex = idx
        let itemURL = urls[idx]
        onDownloadBegin?(itemURL)
        Task {
            defer {
                onDownloadEnd?(itemURL)
                if pendingDownloadIndex == idx { pendingDownloadIndex = nil }
            }
            do { try await ICloudStatus.ensureDownloaded(target) }
            catch {
                // 翻页目标下载失败也要可见:QL 此刻显示空白页,不提示用户只会以为预览坏了。
                onDownloadFailed?(itemURL, error)
                return
            }
            guard index == idx, isActive else { return }
            apply()
        }
    }

    /// 内容(排序/目录)变化 → 刷新 QL 列表并定位(urls 未变则跳过,避免无谓 reload 抖动)。
    func updateItems(_ newURLs: [URL], current: Int) {
        guard isActive, urls != newURLs, let panel = QLPreviewPanel.shared() else { return }
        urls = newURLs
        panel.reloadData()
        if urls.indices.contains(current) {
            index = current
            panel.currentPreviewItemIndex = current
        }
    }

    /// KVO 监听 QL 内 ←→ 翻页:Apple 私有属性未必 @objc dynamic(Swift keyPath observe 不保证
    /// 触发),用 ObjC 字符串 KVO 更稳。值变化 → onIndexChange 回写面板选中。
    private func beginObservingIndex(_ panel: QLPreviewPanel) {
        guard !observingIndex else { return }
        panel.addObserver(self, forKeyPath: "currentPreviewItemIndex", options: [.new], context: nil)
        observedPanel = panel
        observingIndex = true
    }

    private func endObservingIndex() {
        guard observingIndex else { return }
        observingIndex = false
        observedPanel?.removeObserver(self, forKeyPath: "currentPreviewItemIndex")
        observedPanel = nil
    }

    override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == "currentPreviewItemIndex",
              let newIndex = change?[.newKey] as? Int else { return }
        // QL KVO 回调线程无文档保证:主线程直接 assumeIsolated,否则跳主线程(Codex review,
        // 避免非主线程回调时 assumeIsolated runtime fatal)。
        if Thread.isMainThread {
            MainActor.assumeIsolated { self.handleIndexChange(newIndex) }
        } else {
            Task { @MainActor [weak self] in self?.handleIndexChange(newIndex) }
        }
    }

    private func handleIndexChange(_ newIndex: Int) {
        guard index != newIndex else { return }
        index = newIndex
        onIndexChange?(newIndex)
        // QL 自带翻页(工具栏箭头)切到 dataless 占位:QL 已切过去会显示空白 → 下载完 reloadData
        // 让 QL 重新拉到真内容。本地文件 QL 已正确显示,无需动作(不无谓 reloadData 闪烁)。
        guard urls.indices.contains(newIndex),
              ICloudStatus.isDataless(Self.resolvedForPreview(urls[newIndex])) else { return }
        downloadIfNeeded(at: newIndex) { QLPreviewPanel.shared()?.reloadData() }
    }

    private func handleClose() {
        autoHide.end(.quickLook)
        endObservingIndex()
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
    }
}

extension QuickLookController: QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel, previewItemAt index: Int) -> QLPreviewItem {
        Self.resolvedForPreview(urls[index]) as NSURL   // NSURL 符合 QLPreviewItem
    }

    /// alias/symlink 预览解析到真实目标(Finder 语义:预览替身看到的是目标内容,而非替身自身的
    /// 元信息)。仅对 alias 文件解析;非 alias 或解析失败原样返回——不臆造、不吞错地退回原 URL。
    private static func resolvedForPreview(_ url: URL) -> URL {
        let isAlias = (try? url.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile ?? false
        guard isAlias, let resolved = try? URL(resolvingAliasFileAt: url, options: []) else { return url }
        return resolved
    }
}

extension QuickLookController: QLPreviewPanelDelegate {
    /// 把方向键等交回给我们的网格(MVP 直接让 QL 处理上下张切换即可,返回 false 用默认)。
    func previewPanel(_ panel: QLPreviewPanel, handle event: NSEvent) -> Bool { false }
}
