import Foundation
import Combine

/// 一个绑定文件夹的镜像数据源(spec §4.1):指向磁盘真实状态,实时同步,容忍外部改/删/移。
///
/// 把以下编织成一个 per-tab 状态机:
/// - bookmark 解析(普通 bookmark,非 security-scoped;追踪重命名/移动)
/// - TCC 授权(探针绑用户动作 §4.1.1;失败 → permissionDenied 引导)
/// - FSEvents arm 时序(**先建流再快照** §4.1.1;事件不可信 → 重扫快照 diff)
/// - RootChanged → 重解析 bookmark + 重建流
/// - 卷卸载 → volumeUnmounted 空态,重挂载自动重连
/// - iCloud dataless 状态(NSMetadataQuery,§4.1.2)
@MainActor
final class DirectoryMirror: ObservableObject {
    enum State: Equatable {
        case idle               // 未 arm(tab 尚未打开 —— 不偷偷列受保护目录)
        case loading
        case ready
        case permissionDenied   // TCC 被拒,需引导授权
        case volumeUnmounted(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var items: [FileItem] = []

    let binding: FolderBinding
    /// 绑定根目录(bookmark 解析所得,不随下钻变化)。
    private(set) var rootURL: URL
    /// 当前展示的目录(spec §4.7 ⌘↓ 进子目录 / ⌘↑ 回上级;下钻不越过 rootURL)。
    private(set) var currentDirectory: URL

    /// 兼容旧引用:当前被监听/展示的目录。
    var resolvedURL: URL { currentDirectory }

    /// 是否可回上级(未在根目录)。
    var canGoUp: Bool { currentDirectory.standardizedFileURL != rootURL.standardizedFileURL }

    var showHidden: Bool {
        didSet { if showHidden != oldValue, case .ready = state { refresh() } }
    }

    private var stream: FSEventStreamWrapper?
    private let icloud = ICloudStatus()
    private var snapshot = DirectorySnapshot(items: [])
    private var datalessOverride: [URL: Bool] = [:]
    private var armed = false
    /// FSEvents 流是否成功建立(失败 → 无实时同步,需手动 refresh)。
    private(set) var isWatching = false

    init(binding: FolderBinding, showHidden: Bool) {
        self.binding = binding
        self.showHidden = showHidden
        let root = Self.resolve(binding) ?? binding.url
        self.rootURL = root
        self.currentDirectory = root
        icloud.onStatusChange = { [weak self] map in self?.applyDatalessOverride(map) }
    }

    // MARK: - 目录下钻 / 回上级(spec §4.7)

    /// 进入子目录(下钻):重置选择由 UI 负责;重建流 + 重扫。
    /// 校验目标确是目录且仍在 rootURL 之内(防外部/拖拽传入越界 URL 跳出绑定根)。
    func enter(_ subdirectory: URL) {
        let target = subdirectory.standardizedFileURL
        let isDir = (try? target.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? target.hasDirectoryPath
        guard isDir, Self.contains(ancestor: rootURL, descendant: target) else { return }
        currentDirectory = target
        rearmCurrentDirectory()
    }

    /// 回上级(不越过 rootURL)。
    func goUp() {
        guard canGoUp else { return }
        currentDirectory = currentDirectory.deletingLastPathComponent().standardizedFileURL
        rearmCurrentDirectory()
    }

    private func rearmCurrentDirectory() {
        guard armed else { return }
        startStream()
        captureAndPublish()
        icloud.stop()
        startICloudIfNeeded()
    }

    deinit { stream?.stop() }

    // MARK: - arm(绑定用户显式动作:打开 tab / 点授权)

    /// 打开 tab 时调用。**这是一次真实访问**,会触发受保护目录的 TCC 弹窗 —— 必须由用户动作驱动。
    func arm() {
        guard !armed else { return }
        armAttempt()
    }

    /// 用户点"点此授权并重试":先开系统隐私设置(首拒后系统不再弹),再重试探针。
    func reauthorize() {
        TCCAccess.openPrivacySettings()
        armAttempt()
    }

    /// 卷重新挂载且用户回到该 tab:重试。
    func retryIfPossible() {
        guard case .volumeUnmounted = state else { return }
        armAttempt()
    }

    private func armAttempt() {
        state = .loading

        // 卷已卸载?进入空态(保留绑定,不删)。
        guard VolumeMonitor.isVolumeMounted(for: resolvedURL) else {
            state = .volumeUnmounted(resolvedURL.lastPathComponent)
            return
        }
        // TCC 探针(真实访问):失败即引导。
        guard TCCAccess.probe(resolvedURL) else {
            state = .permissionDenied
            return
        }

        // arm 顺序 = 先建流再快照(§4.1.1),处理"建流到快照之间"的事件。
        startStream()
        guard captureAndPublish() else { return }   // 失败保留 captureAndPublish 设的错误态,不覆盖成 ready
        startICloudIfNeeded()
        armed = true
        // state 已由 captureAndPublish 设为 .ready,不再无条件覆盖
    }

    // MARK: - FSEvents

    private func startStream() {
        stream?.stop()
        let wrapper = FSEventStreamWrapper(path: currentDirectory.path) { [weak self] batch in
            self?.handle(batch)
        }
        isWatching = wrapper.start()
        stream = wrapper
    }

    private func handle(_ batch: FSEventBatch) {
        if batch.unmounted, !VolumeMonitor.isVolumeMounted(for: resolvedURL) {
            stream?.stop(); stream = nil
            state = .volumeUnmounted(resolvedURL.lastPathComponent)
            return
        }
        if batch.rootChanged {
            // 根目录自身被移动/重命名:重解析 bookmark 到新位置,重置到根并重建流,
            // 同时重绑 iCloud query 到新位置(否则仍监听旧目录)。
            if let newURL = Self.resolve(binding) {
                rootURL = newURL
                currentDirectory = newURL
            }
            startStream()
            icloud.stop()
            startICloudIfNeeded()
        }
        // 无论 needsFullRescan 还是普通变化,一律重扫快照 + diff(不信任增量,§4.1.1)。
        captureAndPublish()
    }

    // MARK: - 快照

    /// 重扫目录、与旧快照 diff、发布。任何变化都走这条路径(镜像靠比对而非增量信任)。
    @discardableResult
    private func captureAndPublish() -> Bool {
        guard let fresh = try? DirectorySnapshot.capture(directory: resolvedURL, showHidden: showHidden) else {
            // 列目录失败:可能授权被撤销或卷消失。
            if !VolumeMonitor.isVolumeMounted(for: resolvedURL) {
                state = .volumeUnmounted(resolvedURL.lastPathComponent)
            } else {
                state = .permissionDenied
            }
            return false
        }
        snapshot = fresh
        publishItems()
        if case .ready = state {} else { state = .ready }
        return true
    }

    func refresh() { captureAndPublish() }

    private func publishItems() {
        // 合并 iCloud 实时 dataless 覆盖(NSMetadataQuery 比 resourceValues 更及时)。
        items = snapshot.fileItems.map { item in
            guard let override = datalessOverride[item.url.standardizedFileURL],
                  override != item.isDataless else { return item }
            return FileItem(
                url: item.url, name: item.name, isDirectory: item.isDirectory,
                isHidden: item.isHidden, size: item.size, modificationDate: item.modificationDate,
                contentType: item.contentType, isDataless: override, tags: item.tags
            )
        }
    }

    // MARK: - iCloud

    private func startICloudIfNeeded() {
        guard ICloudStatus.isUbiquitous(resolvedURL) else { return }
        icloud.startMonitoring(directory: resolvedURL)
    }

    private func applyDatalessOverride(_ map: [URL: Bool]) {
        datalessOverride = map
        if case .ready = state { publishItems() }
    }

    // MARK: - 卷监听联动(由 NicheController 的 VolumeMonitor 转发)

    func volumeDidUnmount(_ volumeURL: URL) {
        guard Self.contains(ancestor: volumeURL, descendant: rootURL) else { return }
        stream?.stop(); stream = nil
        isWatching = false
        state = .volumeUnmounted(rootURL.lastPathComponent)
    }

    func volumeDidMount(_ volumeURL: URL) {
        guard case .volumeUnmounted = state,
              Self.contains(ancestor: volumeURL, descendant: rootURL) else { return }
        // 卷回来了但不主动列(可能受保护)——等用户回到该 tab 触发 retryIfPossible。
    }

    /// 路径包含判定:descendant 是否等于 ancestor 或在其之下(按标准化路径组件边界,
    /// 避免 `/Volumes/Data` 误命中 `/Volumes/Data2`)。
    static func contains(ancestor: URL, descendant: URL) -> Bool {
        let a = ancestor.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let d = descendant.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard d.count >= a.count else { return false }
        return Array(d.prefix(a.count)) == a
    }

    // MARK: - bookmark 解析(普通 bookmark,非 security-scoped)

    private static func resolve(_ binding: FolderBinding) -> URL? {
        if let data = binding.bookmarkData {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                return url
            }
        }
        return binding.url
    }

    /// 为一个 URL 生成普通 bookmark(添加绑定时用,追踪后续移动/重命名)。
    static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}
