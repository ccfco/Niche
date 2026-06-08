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
    /// 被 KVO 观察的 QL 面板弱引用:供 deinit 移除 observer,避免在 nonisolated deinit 里调
    /// @MainActor 的 QLPreviewPanel.shared()(消除隔离告警 + 守 deinit 红线)。
    private weak var observedPanel: QLPreviewPanel?

    /// 宿主面板当前层级提供者(由 NicheController 注入):QL present 时抬到「宿主 +1」浮于面板之上。
    /// 返回 nil(宿主面板不存在)则不抬层级,保留 QL 系统默认 —— 不臆造一个可能盖住菜单/通知的高层。
    var hostWindowLevel: (() -> NSWindow.Level?)?
    /// QL 内翻页 → 回写面板选中(NicheController 据此把选中停在最后预览项)。
    var onIndexChange: ((Int) -> Void)?

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
        self.urls = urls
        self.index = index

        Task {
            do {
                // 仅对当前要看的这个文件按需下载,不递归、不批量(§4.1.2)。
                try await ICloudStatus.ensureDownloaded(urls[index])
            } catch {
                // 下载失败/超时:不把 dataless URL 交给 Quick Look(spec §4.1.2:等可用后再预览)。
                return
            }
            present()
        }
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
    func syncCurrentIndex(_ newIndex: Int) {
        guard isActive, urls.indices.contains(newIndex), let panel = QLPreviewPanel.shared() else { return }
        guard panel.currentPreviewItemIndex != newIndex else { return }
        index = newIndex
        panel.currentPreviewItemIndex = newIndex
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
        urls[index] as NSURL   // NSURL 符合 QLPreviewItem
    }
}

extension QuickLookController: QLPreviewPanelDelegate {
    /// 把方向键等交回给我们的网格(MVP 直接让 QL 处理上下张切换即可,返回 false 用默认)。
    func previewPanel(_ panel: QLPreviewPanel, handle event: NSEvent) -> Bool { false }
}
