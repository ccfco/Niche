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
        case missing            // 绑定目录已被删除/移动且 bookmark 追踪不到(≠权限被拒,
                                // 误报成 denied 会引导用户去系统设置白授权一通)
        case accessFailed       // 列目录失败但非权限/卷/缺失(并发删除中、磁盘 IO 错等):
                                // 不伪装成 TCC 被拒(引导授权无意义),暴露真实错误 + 留重试入口
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var items: [FileItem] = [] {
        didSet {
            Self.contentGeneration &+= 1
            itemsVersion = Self.contentGeneration
        }
    }
    /// 内容代次(PanelModel.sortedItems 的缓存键):数组逐元素比较太贵,代次即内容身份。
    /// 全局单调计数,避免"实例释放后新 mirror 复用同地址 + 代次同为初值"的脏缓存。
    private static var contentGeneration = 0
    private(set) var itemsVersion = 0

    let binding: FolderBinding
    /// 临时 tab(路径输入「前往」根外目录):不入 BindingStore、不持久化,单槽替换;
    /// 其余能力(文件操作/TCC/FSEvents/iCloud)与正式 tab 完全等价。
    let isTemporary: Bool
    /// 绑定根目录(bookmark 解析所得,不随下钻变化)。
    private(set) var rootURL: URL
    /// 当前展示的目录(spec §4.7 ⌘↓ 进子目录 / ⌘↑ 回上级;下钻不越过 rootURL)。
    private(set) var currentDirectory: URL

    /// 兼容旧引用:当前被监听/展示的目录。
    var resolvedURL: URL { currentDirectory }

    /// 是否可回上级(未在根目录)。
    var canGoUp: Bool { currentDirectory.standardizedFileURL != rootURL.standardizedFileURL }

    /// 面包屑:从绑定根到当前目录的可点路径(根用绑定显示名;下钻段用各级目录名)。
    /// 纯鼠标据此逐级回跳(#7/#8);在根时只有一项(根本身)。
    var breadcrumb: [(name: String, url: URL)] {
        let rootStd = rootURL.standardizedFileURL
        let curStd = currentDirectory.standardizedFileURL
        var result: [(name: String, url: URL)] = [(binding.displayName, rootStd)]
        // 下钻深度用「未解析符号链接」的标准化组件算:currentDirectory 始终由 rootURL 追加得到,
        // 同形相减即真实深度;解析对深度本就冗余(cur 与 root 同获相同符号链接展开),且软链就地
        // 下钻时解析会把 cur 跳到真实越界树、深度算错 —— 故与 canGoUp/containsUnresolved 同源用标准化形。
        let depth = curStd.pathComponents.count - rootStd.pathComponents.count
        let curComps = curStd.pathComponents
        guard depth > 0, curComps.count >= depth else { return result }
        var url = rootStd
        for comp in curComps.suffix(depth) {
            url.appendPathComponent(comp)
            result.append((comp, url))
        }
        return result
    }

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

    init(binding: FolderBinding, showHidden: Bool, isTemporary: Bool = false) {
        self.binding = binding
        self.showHidden = showHidden
        self.isTemporary = isTemporary
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
        // 软链就地下钻:目录判定软链感知(.isDirectoryKey 对软链本身报 false,需解析目标);
        // 越界判定用「未解析软链」的路径前缀(containsUnresolved),而非会解析叶子/中段软链跳出
        // 真实树的共享 contains —— 使指向越界目标的软链仍以「父级之下」表示参与面包屑/回上级,
        // 真实内容由文件系统跟随软链列出。
        guard Self.isNavigableDirectory(target),
              Self.containsUnresolved(ancestor: rootURL, descendant: target) else { return }
        currentDirectory = target
        rearmCurrentDirectory()
    }

    /// 是否「可下钻的目录」:普通目录,或指向目录的软链(Finder 双击进入语义)。
    /// `.isDirectoryKey` 对软链本身报 false,故软链须解析目标再判;指向文件的软链 → false(走打开)。
    static func isNavigableDirectory(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if v?.isDirectory == true { return true }
        if v?.isSymbolicLink == true {
            return (try? url.resolvingSymlinksInPath()
                .resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        return url.hasDirectoryPath
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

    /// 用户点"点此授权并重试":**先重试探针,仍被拒才开系统隐私设置**。
    /// 反过来(先开设置再立即重试)时序拧巴:此刻用户还没去开开关,重试必然失败,状态闪一下
    /// loading 又回 denied;而用户在系统设置开完开关回来再点时,探针直接成功、不再弹设置页。
    func reauthorize() {
        armAttempt()
        if case .permissionDenied = state {
            TCCAccess.openPrivacySettings()
        }
    }

    /// 卷重新挂载 / 目录从废纸篓恢复,且用户回到该 tab:重试。
    func retryIfPossible() {
        switch state {
        case .volumeUnmounted, .missing: armAttempt()
        // 非权限 IO 错:直接重列,不走 armAttempt 的 TCC 探针 —— probe 是 URL 版,对软链等会
        // 误失败再翻回 permissionDenied(captureAndPublish 已能跟随软链)。
        case .accessFailed: _ = captureAndPublish()
        default: return
        }
    }

    private func armAttempt() {
        invalidateInFlightScans()   // 早退分支(卷/缺失/TCC)直接定错误态,不能被迟到扫描覆盖成 ready
        state = .loading

        // 卷已卸载?进入空态(保留绑定,不删)。
        guard VolumeMonitor.isVolumeMounted(for: resolvedURL) else {
            state = .volumeUnmounted(VolumeMonitor.volumeDisplayName(for: resolvedURL))
            return
        }
        // 目录不存在(被删/移走且 bookmark 追踪不到):先于 TCC 探针判定 —— 探针对不存在
        // 路径同样失败,会误报 permissionDenied 引导用户白授权(stat 不受 TCC 限,可区分)。
        guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
            state = .missing
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
            invalidateInFlightScans()   // 卸载前已起飞的后台扫描不得回头把状态覆盖成 ready
            stream?.stop(); stream = nil
            isWatching = false
            state = .volumeUnmounted(VolumeMonitor.volumeDisplayName(for: resolvedURL))
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
        // FSEvents 路径走后台扫:大目录(数千文件)同步列目录会卡主线程,高频变更(解压/
        // 批量下载)时面板动画反复冻结(性能审计)。
        captureAndPublishAsync()
    }

    // MARK: - 快照

    /// 扫描代次:作废在途的后台扫描结果。任何一次扫描(同步或异步)都推进代次;
    /// 异步结果回主线程时代次已变(期间有过更新的扫描/下钻换了目录)即丢弃,防旧结果
    /// 覆盖新状态。@MainActor 串行,无锁。
    private var scanGeneration = 0
    /// 在途后台扫描(FSEvents 风暴合并:新事件取消未开扫的旧任务,已在扫的扫完被代次丢弃,
    /// 并发扫描数有界,不随事件频率堆积)。
    private var scanTask: Task<Void, Never>?

    /// 任何"绕过扫描直接定状态"的路径(armAttempt 早退 / 卷卸载通知)必须先调:
    /// 否则迟到的后台扫描结果会把刚设的错误态覆盖回 ready(Codex review)。
    private func invalidateInFlightScans() {
        scanGeneration &+= 1
    }

    /// 同步重扫(**仅用户动作路径**:arm / refresh / 下钻):立即扫、立即发布——
    /// beginRenameSafely(新建文件夹即时入列)等依赖 refresh 的同步语义,不能改异步。
    /// 重扫目录、与旧快照 diff、发布。镜像靠比对而非增量信任。
    @discardableResult
    private func captureAndPublish() -> Bool {
        scanGeneration &+= 1
        do {
            apply(try DirectorySnapshot.capture(directory: resolvedURL, showHidden: showHidden))
            return true
        } catch {
            applyCaptureFailure(error)
            return false
        }
    }

    /// 后台重扫(FSEvents 事件路径):capture 移到后台,回主线程后代次未变才发布。
    private func captureAndPublishAsync() {
        scanGeneration &+= 1
        let generation = scanGeneration
        let dir = resolvedURL
        let hidden = showHidden
        scanTask?.cancel()
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }   // 已被更新事件取代,省一次全量列目录
            let result = Result { try DirectorySnapshot.capture(directory: dir, showHidden: hidden) }
            await MainActor.run {
                guard let self, self.scanGeneration == generation else { return }
                switch result {
                case .success(let fresh): self.apply(fresh)
                case .failure(let error): self.applyCaptureFailure(error)
                }
            }
        }
    }

    private func apply(_ fresh: DirectorySnapshot) {
        snapshot = fresh
        publishItems()
        if case .ready = state {} else { state = .ready }
    }

    /// 列目录失败的统一归因:按"卷消失 → 目录被删 → 权限被拒 → 其它 IO 错"顺序。
    /// **关键:不再兜底把任何失败都当 permissionDenied** —— 误报会把用户引去 TCC 设置白跑
    /// (实测:软链 256/ENOTDIR、并发删除、磁盘错都非权限问题)。stat 不受 TCC 限,先据它分出
    /// 卷/缺失;再据 error 精确分出真权限错(isPermissionError),剩下归 accessFailed 暴露真因。
    private func applyCaptureFailure(_ error: Error?) {
        if !VolumeMonitor.isVolumeMounted(for: resolvedURL) {
            state = .volumeUnmounted(VolumeMonitor.volumeDisplayName(for: resolvedURL))
        } else if !FileManager.default.fileExists(atPath: resolvedURL.path) {
            state = .missing
        } else if let error, Self.isPermissionError(error) {
            state = .permissionDenied
        } else {
            Log.files.error("列目录失败(非权限):\(error?.localizedDescription ?? "未知", privacy: .public)")
            state = .accessFailed
        }
    }

    /// 列目录错误是否真为权限拒绝(TCC / POSIX)。实测样本:权限拒绝 = NSCocoaError 257
    /// (NSFileReadNoPermissionError),底层 POSIX EPERM(TCC) 或 EACCES(chmod);其它 IO 错
    /// (软链 256/ENOTDIR、不存在 260/ENOENT)均不算 —— 据此把"该引导授权"与"该暴露真因"分开。
    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError { return true }
        let posix = ns.domain == NSPOSIXErrorDomain ? ns : (ns.userInfo[NSUnderlyingErrorKey] as? NSError)
        if let posix, posix.domain == NSPOSIXErrorDomain,
           posix.code == Int(EPERM) || posix.code == Int(EACCES) { return true }
        return false
    }

    func refresh() { captureAndPublish() }

    private func publishItems() {
        // 合并 iCloud 实时 dataless 覆盖(NSMetadataQuery 比 resourceValues 更及时)。
        let merged = snapshot.fileItems.map { item in
            guard let override = datalessOverride[item.url.standardizedFileURL],
                  override != item.isDataless else { return item }
            return FileItem(
                url: item.url, name: item.name, isDirectory: item.isDirectory,
                isHidden: item.isHidden, size: item.size, modificationDate: item.modificationDate,
                contentType: item.contentType, isDataless: override, tags: item.tags,
                folderIconSignature: item.folderIconSignature
            )
        }
        // 内容没变不重赋值:FSEvents 重扫常是无关事件(同目录元数据抖动),原样赋值会
        // 空 bump itemsVersion(排序缓存白失效)+ 空发布(全面板白重渲染)(Codex review)。
        guard merged != items else { return }
        items = merged
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
        invalidateInFlightScans()   // 同 handle 卸载分支:迟到扫描不得覆盖卸载态
        stream?.stop(); stream = nil
        isWatching = false
        // 卷名取通知里的挂载点名,不取绑定目录末段(深层子目录会把子目录名当卷名展示)。
        state = .volumeUnmounted(volumeURL.lastPathComponent)
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

    /// 下钻越界判定:用「**未解析符号链接**」的标准化路径组件前缀。`currentDirectory` 始终由
    /// `rootURL` 追加组件得到、同形比较精确;软链就地下钻时(叶子/中段为软链)不因解析跳出真实树
    /// 而误判越界 —— 面包屑/回上级统一以 root 体系表示,真实内容由文件系统跟随软链列出。
    /// **与 `contains` 不可混用**:后者解析符号链接,服务拖拽环路防护/卷判定(需防 `..`/软链逃逸)。
    static func containsUnresolved(ancestor: URL, descendant: URL) -> Bool {
        let a = ancestor.standardizedFileURL.pathComponents
        let d = descendant.standardizedFileURL.pathComponents
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
