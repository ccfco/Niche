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

    init(autoHide: AutoHideCoordinator) {
        self.autoHide = autoHide
        super.init()
    }

    /// 当前预览面板窗口(供 AutoHideCoordinator.ownedWindows 排除"焦点转到预览窗口")。
    var previewPanel: NSWindow? {
        QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil
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

    private func handleClose() {
        autoHide.end(.quickLook)
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
