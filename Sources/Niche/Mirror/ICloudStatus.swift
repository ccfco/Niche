import Foundation

/// iCloud Drive 占位符(dataless)语义(spec §4.1.2)。iCloud 目录与普通目录是两套数据源语义。
///
/// 要点:
/// - **不主动下载**:列目录会列出未下载占位文件,绝不为出缩略图后台静默触发整文件下载。
/// - **判 dataless 不靠 .icloud 后缀**:用 `ubiquitousItemDownloadingStatusKey`(FileItem.load 已做)。
/// - **状态走 NSMetadataQuery**,不靠 FSEvents(FSEvents 不可靠反映 iCloud 同步状态)。
/// - **预览 = 显式下载再交给 Quick Look**:点预览时先 startDownloadingUbiquitousItem + 等可用。
/// - **目录型占位不递归全量下载**。
@MainActor
final class ICloudStatus {
    /// 某目录是否在 iCloud(ubiquitous)。非 iCloud 目录不启动 NSMetadataQuery。
    static func isUbiquitous(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem ?? false
    }

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []

    /// 下载状态变化回调:传出本目录内各 URL 的"是否仍为 dataless"。镜像据此更新云占位图标。
    var onStatusChange: (([URL: Bool]) -> Void)?

    /// 监听某 iCloud 目录的下载/上传状态(非 iCloud 目录直接 no-op)。
    func startMonitoring(directory: URL) {
        stop()
        guard Self.isUbiquitous(directory) else { return }

        let query = NSMetadataQuery()
        query.searchScopes = [directory]
        query.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
        query.valueListAttributes = [NSMetadataUbiquitousItemDownloadingStatusKey]

        let center = NotificationCenter.default
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering,
                     NSNotification.Name.NSMetadataQueryDidUpdate] {
            let token = center.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.emit() }
            }
            observers.append(token)
        }
        self.query = query
        query.start()
    }

    func stop() {
        query?.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        query = nil
    }

    deinit {
        query?.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func emit() {
        guard let query else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }

        var map: [URL: Bool] = [:]
        for i in 0..<query.resultCount {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL
            else { continue }
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            let isDataless = status != NSMetadataUbiquitousItemDownloadingStatusCurrent
            map[url.standardizedFileURL] = isDataless
        }
        onStatusChange?(map)
    }

    // MARK: - 预览前显式下载(不递归目录)

    /// 下载超时的可读错误(此前抛 CocoaError(.userCancelled),提示文案是"操作已取消"——
    /// 用户没取消任何东西,看不懂哪里出了问题)。
    enum DownloadError: LocalizedError {
        case timeout
        var errorDescription: String? { String(localized: "iCloud 下载超时,请检查网络后重试。") }
    }

    /// 显式请求下载一个占位文件,轮询到可用(spec §4.1.2:等可用后再把 URL 交给 QLPreviewPanel)。
    /// 目录型 item 不在此递归下载(调用方只对文件调用)。
    static func ensureDownloaded(_ url: URL, timeout: TimeInterval = 30) async throws {
        // 目录型 iCloud item 不递归全量下载(spec §4.1.2),直接返回交由逐层按需处理。
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { return }
        // 已是本地可用(或非 iCloud)直接返回。
        if !isDataless(url) { return }
        try FileManager.default.startDownloadingUbiquitousItem(at: url)

        // 单调时钟:墙钟 Date() 在系统休眠/用户改时间时会失真(deadline 提前或永不到),
        // ContinuousClock 单调递增、不受影响,与 Task.sleep 同源。
        let clock = ContinuousClock()
        let start = clock.now
        while clock.now - start < .seconds(timeout) {
            if !isDataless(url) { return }
            try await Task.sleep(nanoseconds: 200_000_000)  // 0.2s
        }
        throw DownloadError.timeout
    }

    /// 同步判 dataless(iCloud 占位、未下载)。供预览切换前判定走「同步即切」还是「先下后切」——
    /// 本地/非 iCloud 文件零延迟切换,dataless 才异步下载(§4.1.2)。
    static func isDataless(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey,
                                                       .ubiquitousItemDownloadingStatusKey])
        guard values?.isUbiquitousItem == true,
              let status = values?.ubiquitousItemDownloadingStatus else { return false }
        return status != .current
    }
}
