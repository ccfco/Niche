import Foundation
import CoreServices

/// 一批 FSEvents 的聚合结果(spec §4.1.1:FSEvents 不是逐文件强一致流,事件会 coalesce/drop)。
///
/// 我们不信任增量,只用这些信号决定"要不要重扫 + 重新 snapshot diff":
struct FSEventBatch {
    /// 必须对相关子树全量重扫(MustScanSubDirs / UserDropped / KernelDropped / event-id wrap)。
    var needsFullRescan: Bool = false
    /// 被监听的根目录自身被移动/重命名(RootChanged)→ 需重解析 bookmark 并重建流。
    var rootChanged: Bool = false
    /// 卷挂载 / 卸载(外置卷/网络卷)。
    var mounted: Bool = false
    var unmounted: Bool = false
    /// 发生变化的路径(仅作提示,镜像最终以重扫快照为准)。
    var changedPaths: [String] = []
}

/// FSEvents C API 的 Swift 封装:监听一个目录,把聚合后的 FSEventBatch 投递到主线程。
///
/// 用 WatchRoot 标志以捕获根目录自身改名/移动(RootChanged);用 dispatch queue 驱动,
/// 回调里解析 flags 后 hop 回主线程。
final class FSEventStreamWrapper {
    private var stream: FSEventStreamRef?
    private let path: String
    private let queue = DispatchQueue(label: "com.ccfco.Niche.fsevents")
    private let onBatch: (FSEventBatch) -> Void

    init(path: String, onBatch: @escaping (FSEventBatch) -> Void) {
        self.path = path
        self.onBatch = onBatch
    }

    deinit { stop() }

    /// 建立并启动 stream。返回是否成功。
    @discardableResult
    func start(since: FSEventStreamEventId = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)) -> Bool {
        guard stream == nil else { return true }

        // 用 passRetained + context release 回调托管生命周期:FSEvents 持有一份 retain,
        // 流 Invalidate/Release 时调用 release 回调平衡。避免"流停止前仍有在途回调
        // takeUnretainedValue 命中已释放对象"的野指针(Codex review)。wrapper 另被
        // DirectoryMirror 强持有,不会因 release 在 stop() 中途析构。
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil,
            release: Self.releaseInfo,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagFileEvents
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &context,
            [path] as CFArray,
            since,
            0.3,                 // latency:0.3s 合并抖动
            flags
        ) else { return false }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        return FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // MARK: - C 回调

    /// context release 回调:平衡 passRetained 的那一份引用。
    private static let releaseInfo: CFAllocatorReleaseCallBack = { info in
        guard let info else { return }
        Unmanaged<FSEventStreamWrapper>.fromOpaque(info).release()
    }

    private static let callback: FSEventStreamCallback = {
        _, info, count, eventPaths, eventFlags, _ in
        guard let info else { return }
        let wrapper = Unmanaged<FSEventStreamWrapper>.fromOpaque(info).takeUnretainedValue()

        // kFSEventStreamCreateFlagUseCFTypes → eventPaths 是 CFArray<CFString>。
        let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []

        var batch = FSEventBatch()
        for i in 0..<count {
            let flag = Int(eventFlags[i])
            if flag & kFSEventStreamEventFlagMustScanSubDirs != 0
                || flag & kFSEventStreamEventFlagUserDropped != 0
                || flag & kFSEventStreamEventFlagKernelDropped != 0
                || flag & kFSEventStreamEventFlagEventIdsWrapped != 0 {
                batch.needsFullRescan = true
            }
            if flag & kFSEventStreamEventFlagRootChanged != 0 { batch.rootChanged = true }
            if flag & kFSEventStreamEventFlagMount != 0 { batch.mounted = true }
            if flag & kFSEventStreamEventFlagUnmount != 0 { batch.unmounted = true }
            if i < paths.count { batch.changedPaths.append(paths[i]) }
        }

        let onBatch = wrapper.onBatch
        DispatchQueue.main.async { onBatch(batch) }
    }
}
