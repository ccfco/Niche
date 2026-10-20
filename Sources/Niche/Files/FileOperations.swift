import AppKit
import UniformTypeIdentifiers

/// 文件操作命令层(spec §4.5):全部走系统 API,零自研文件引擎。每个方法对应表中一项,
/// 写操作前校验目标可写,删除一律走废纸篓(可恢复),并把可撤销操作记入 FileOpUndoManager。
///
/// iCloud / 文档型文件的读写用 NSFileCoordinator 协调(注③),否则与文件提供者/同步状态打架。
///
/// **批量 copy/move/paste 的执行在后台 Task**:`FileManager.copyItem/moveItem` 是同步阻塞调用,
/// 大文件/万级目录放主线程会冻结面板动画与键盘。主线程只负责冲突决议(先弹模态拿到结果再
/// 继续)、撤销记录与进度发布;单项内部不 chunked copy(那会滑向自研文件引擎),取消在项与项
/// 之间生效。
@MainActor
final class FileOperations {
    let undo: FileOpUndoManager
    /// 异步路径(recycle 完成回调等无法 throws 上抛)的失败出口,由宿主接到可见提示。
    var onError: ((_ title: String, _ error: Error) -> Void)?
    /// 操作级进度(主线程回调);nil = 当前无操作。宿主接到 PanelModel 显示底栏进度行。
    var onProgress: ((FileOperationProgress?) -> Void)?

    /// 当前在途批量操作。同一时刻只允许一个,避免两个 copy/move 在目标目录互相踩。
    private var activeTask: Task<Void, Error>?
    var isBusy: Bool { activeTask != nil }

    init(undo: FileOpUndoManager) {
        self.undo = undo
    }

    // MARK: - 打开 / 显示

    func open(_ url: URL) { NSWorkspace.shared.open(url) }

    func open(_ url: URL, withApplicationAt appURL: URL) {
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
    }

    /// 在 Finder 中显示(spec:NSWorkspace.activateFileViewerSelecting,完全一致)。
    func revealInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: - 删除到废纸篓(带 Finder 同款音效+动画;记录 undo 映射)

    func trash(_ urls: [URL]) {
        NSWorkspace.shared.recycle(urls) { [weak self] mapping, error in
            Task { @MainActor in
                for (original, trashed) in mapping {
                    self?.undo.record(.init(kind: .trash(original: original, trashed: trashed)))
                }
                // 失败项不静默吞(CLAUDE.md:让问题暴露):日志 + 可见提示,部分失败也让用户知道。
                if let error {
                    Log.files.error("移到废纸篓部分失败:\(error.localizedDescription, privacy: .public)")
                    self?.onError?(String(localized: "无法移到废纸篓"), error)
                }
            }
        }
    }

    // MARK: - 重命名(就地编辑 + moveItem)

    @discardableResult
    func rename(_ url: URL, to newName: String) throws -> URL {
        let dest = url.deletingLastPathComponent().appendingPathComponent(newName)
        guard dest != url else { return url }
        try Self.coordinatedMove(from: url, to: dest)
        undo.record(.init(kind: .rename(from: url, to: dest)))
        return dest
    }

    // MARK: - 复制 / 移动(后台执行;同名冲突由 resolver 决定)

    /// 把若干源拷到目标目录。`resolve` 在遇到同名时返回处理方式(replace/keepBoth/skip),
    /// 由主线程弹模态;后台任务 await 它的结果后继续。
    func copy(_ urls: [URL], to directory: URL,
              resolve: @escaping @MainActor (String) -> ConflictResolution) async throws {
        try Self.ensureWritable(directory)
        try await run(kind: .copy, items: urls) { src, record in
            guard let dest = await Self.resolvedDestination(for: src, in: directory, resolve: resolve) else { return }
            if FileManager.default.fileExists(atPath: dest.path) {
                // 同一物理文件(源经符号链接路径指向 dest 本体):先 trash 会把真身丢进废纸篓,
                // 随后从已悬空的 src 拷贝必然失败 —— 净效果是"复制"反而弄丢用户文件。跳过。
                if Self.isSameFile(src, dest) { return }
                if let trashed = try Self.trashReplaced(dest) { await record(trashed) }
            }
            try Self.coordinatedCopy(from: src, to: dest)
            await record(.init(kind: .copy(created: dest)))
        }
    }

    func move(_ urls: [URL], to directory: URL,
              resolve: @escaping @MainActor (String) -> ConflictResolution) async throws {
        try Self.ensureWritable(directory)
        try await run(kind: .move, items: urls) { src, record in
            guard let dest = await Self.resolvedDestination(for: src, in: directory, resolve: resolve) else { return }
            if dest == src { return }
            if FileManager.default.fileExists(atPath: dest.path) {
                // 同 copy:路径不同但同一物理文件(符号链接)→ 移动是无意义自我移动,跳过,
                // 不能走 trashReplaced(那会把用户文件本体丢进废纸篓再 move 失败)。
                if Self.isSameFile(src, dest) { return }
                if let trashed = try Self.trashReplaced(dest) { await record(trashed) }
            }
            try Self.coordinatedMove(from: src, to: dest)
            await record(.init(kind: .move(from: src, to: dest)))
        }
    }

    /// 取消当前批量操作:在下一项开始前生效(单项 copyItem 不可中断)。
    func cancelCurrentOperation() {
        activeTask?.cancel()
    }

    // MARK: - 剪贴板(⌘X/C/V)

    /// 内部"剪切"标记:记下剪切的 URL 与剪贴板 changeCount,paste 时据此走 move(否则 copy)。
    /// (Finder 私有剪切标记跨 app 不可见,这里只在 Niche 内一致即可。)
    private var pendingCut: (urls: [URL], changeCount: Int)?

    func copyToPasteboard(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        pendingCut = nil
    }

    /// 剪切(⌘X):写剪贴板并标记为剪切,paste 时走 move。
    func cut(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        pendingCut = (urls, pb.changeCount)
    }

    /// 剪贴板当前是否有可粘贴的文件 URL(用于背景菜单「粘贴」项的启用判定)。
    var canPaste: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: nil)
    }

    /// 粘贴(⌘V):剪贴板内容粘到目标目录。若来自本 app 的剪切(changeCount 未变)→ move,否则 copy。
    func paste(into directory: URL,
               resolve: @escaping @MainActor (String) -> ConflictResolution) async throws {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        if let cut = pendingCut, cut.changeCount == NSPasteboard.general.changeCount {
            pendingCut = nil
            try await move(urls, to: directory, resolve: resolve)
        } else {
            try await copy(urls, to: directory, resolve: resolve)
        }
    }

    /// 复制路径(⌥⌘C):写 POSIX 路径到 utf8 文本,多选换行拼接(与 Finder "Copy as Pathname" 一致)。
    /// 同 copyToPasteboard 清 pendingCut:本操作已 clearContents 替换剪贴板,先前 ⌘X 的剪切 URL
    /// 不再在板上,剪切标记必须失效(否则残留污染状态,与 copyToPasteboard 不对称)。
    func copyPaths(_ urls: [URL]) {
        let text = urls.map(\.path).joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        pendingCut = nil
    }

    // MARK: - 新建文件夹

    @discardableResult
    func newFolder(in directory: URL, name: String = String(localized: "未命名文件夹")) throws -> URL {
        try Self.ensureWritable(directory)
        // 目标尚不存在,appendingPathComponent 拼出的是无尾斜杠 URL;而镜像快照
        // (contentsOfDirectory)对目录产出带尾斜杠 URL,FileItem.id 按 `URL ==` 比对会不相等
        // → 新建后 selectSingle/beginRename 全部落空(重命名框永不出现)。创建成功后重构为
        // 带目录 hint 的 URL,与快照 id 同构。
        let proposed = ConflictResolver.uniqueURL(for: directory.appendingPathComponent(name), in: directory)
        try FileManager.default.createDirectory(at: proposed, withIntermediateDirectories: false)
        let dest = URL(fileURLWithPath: proposed.path, isDirectory: true)
        undo.record(.init(kind: .copy(created: dest)))   // 撤销 = 删除该空文件夹(进废纸篓)
        return dest
    }

    // MARK: - 分享(系统分享菜单本体)

    func share(_ urls: [URL], relativeTo rect: NSRect, of view: NSView) {
        guard !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls)
        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    // MARK: - 压缩(调系统 ditto,结果与 Finder 一致)

    /// 压缩:ditto 跑在后台(不阻塞主线程),完成后回主线程记录 undo。
    /// 单项操作无法给字节级比例,UI 用 indeterminate;取消只在启动前生效(ditto 不经 chunked 循环)。
    func compress(_ urls: [URL], in directory: URL) async throws {
        try Self.ensureWritable(directory)
        guard activeTask == nil else { throw FileOperationError.busy }
        let archiveName = urls.count == 1
            ? urls[0].deletingPathExtension().lastPathComponent + ".zip"
            : String(localized: "归档.zip")
        let dest = ConflictResolver.uniqueURL(for: directory.appendingPathComponent(archiveName), in: directory)

        onProgress?(.init(kind: .compress, completed: 0, total: 1, currentName: dest.lastPathComponent))
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            // ditto -c -k --sequesterRsrc --keepParent <inputs...> <archive>
            var args = ["-c", "-k", "--sequesterRsrc", "--keepParent"]
            args.append(contentsOf: urls.map(\.path))
            args.append(dest.path)
            process.arguments = args
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        activeTask = task
        defer {
            activeTask = nil
            onProgress?(nil)
        }
        try await task.value
        undo.record(.init(kind: .copy(created: dest)))
    }

    // MARK: - Finder 标签(读写系统彩色标记)

    func setTags(_ tags: [String], on url: URL) throws {
        // 元数据写也走 NSFileCoordinator(iCloud/文档型文件需协调,注③)。
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var thrown: Error?
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            do {
                var values = URLResourceValues()
                values.tagNames = tags
                var mutable = coordinatedURL
                try mutable.setResourceValues(values)
            } catch { thrown = error }
        }
        if let coordinationError { throw coordinationError }
        if let thrown { throw thrown }
    }

    // MARK: - Undo

    /// 撤销最近一次操作(失败上抛,由宿主弹可见提示;栈空返回 nil 静默 —— 无事可撤不是错误)。
    @discardableResult
    func undoLast() throws -> FileOperationRecord? {
        try undo.undoLast()
    }

    /// 重做最近一次撤销(⇧⌘Z;语义同 undoLast:失败上抛、栈空静默)。
    @discardableResult
    func redoLast() throws -> FileOperationRedoRecord? {
        try undo.redoLast()
    }

    // MARK: - 内部:批量执行

    /// 逐项在后台跑,主线程只做进度/撤销记录/冲突决议。`record` 由操作方在数据已落盘(或
    /// 目标已被移废纸篓)的当下调用,保证中途失败时已完成步骤仍可撤销。
    private func run(
        kind: FileOperationProgress.Kind,
        items: [URL],
        operation: @escaping @Sendable (_ url: URL,
                                          _ record: @escaping @MainActor @Sendable (FileOperationRecord) async -> Void) async throws -> Void
    ) async throws {
        guard !items.isEmpty else { return }
        guard activeTask == nil else { throw FileOperationError.busy }
        let total = items.count
        onProgress?(.init(kind: kind, completed: 0, total: total,
                          currentName: items.first?.lastPathComponent))

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                for (index, url) in items.enumerated() {
                    try Task.checkCancellation()
                    await MainActor.run { [weak self] in
                        self?.onProgress?(.init(kind: kind, completed: index, total: total,
                                                currentName: url.lastPathComponent))
                    }
                    let record: @MainActor @Sendable (FileOperationRecord) async -> Void = { [weak self] record in
                        self?.undo.record(record)
                    }
                    try await operation(url, record)
                    await MainActor.run { [weak self] in
                        self?.onProgress?(.init(kind: kind, completed: index + 1, total: total,
                                                currentName: url.lastPathComponent))
                    }
                }
            } catch {
                await MainActor.run { [weak self] in self?.onProgress?(nil) }
                throw error
            }
            await MainActor.run { [weak self] in self?.onProgress?(nil) }
        }
        activeTask = task
        defer { activeTask = nil }
        try await task.value
    }

    // MARK: - 内部:冲突 / 可写校验

    /// 计算目标 URL:无冲突→原名;有冲突→按 resolver(replace 原名覆盖 / keepBoth 改名 / skip nil)。
    /// resolver 是 MainActor 闭包(弹 NSAlert),后台任务 await 它,不阻塞主线程的其他工作。
    nonisolated private static func resolvedDestination(
        for src: URL, in directory: URL,
        resolve: @escaping @MainActor (String) -> ConflictResolution
    ) async -> URL? {
        let name = src.lastPathComponent
        let proposed = directory.appendingPathComponent(name)
        guard ConflictResolver.hasConflict(name: name, in: directory) else { return proposed }
        switch await resolve(name) {
        case .replace:  return proposed
        case .keepBoth: return ConflictResolver.uniqueURL(for: proposed, in: directory)
        case .skip:     return nil
        }
    }

    /// "替换"前把被替换的目标移废纸篓(可恢复,不真删 §4.5),并返回 undo 记录 —— 否则被替换的
    /// 原文件无法恢复(Codex review:严重数据丢失)。LIFO 下先 undo 新文件再恢复旧文件。
    nonisolated private static func trashReplaced(_ url: URL) throws -> FileOperationRecord? {
        var trashedURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
        guard let trashed = trashedURL as URL? else { return nil }
        return FileOperationRecord(kind: .trash(original: url, trashed: trashed))
    }

    /// 写操作前校验目标目录可写(spec 拖拽红线)。
    nonisolated private static func ensureWritable(_ directory: URL) throws {
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    /// 按文件系统身份(volume+inode)判同一物理文件:路径字符串比较挡不住"路径**中间**含
    /// 符号链接"的同文件情形(中间组件由内核解析,两路径取到同一 inode)。**末端组件本身是
    /// symlink 时取的是链接自身身份**(实测 /var vs /private/var 不等)—— 这是有意保留:
    /// 链接与其目标是两个文件系统对象,"用链接替换同名目标"经过冲突确认弹窗,与 Finder 一致。
    /// 任一侧取不到身份(目标不存在等)视为不同文件。
    nonisolated private static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        guard let ra = (try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier,
              let rb = (try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier
        else { return false }
        return ra.isEqual(rb)
    }

    // MARK: - 内部:NSFileCoordinator 协调的读写(注③)

    nonisolated private static func coordinatedCopy(from src: URL, to dst: URL) throws {
        try coordinate(reading: src, writing: dst) {
            try FileManager.default.copyItem(at: $0, to: $1)
        }
    }

    /// 移动用双写协调:源 `.forMoving`、目标 `.forReplacing`(Codex review:move 应做移动写协调)。
    nonisolated private static func coordinatedMove(from src: URL, to dst: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var thrown: Error?
        coordinator.coordinate(writingItemAt: src, options: .forMoving,
                               writingItemAt: dst, options: .forReplacing,
                               error: &coordinationError) { newSrc, newDst in
            do { try FileManager.default.moveItem(at: newSrc, to: newDst) }
            catch { thrown = error }
        }
        if let coordinationError { throw coordinationError }
        if let thrown { throw thrown }
    }

    nonisolated private static func coordinate(reading src: URL, writing dst: URL,
                                               _ body: (URL, URL) throws -> Void) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var thrown: Error?
        coordinator.coordinate(readingItemAt: src, options: .withoutChanges,
                               writingItemAt: dst, options: .forReplacing,
                               error: &coordinationError) { newSrc, newDst in
            do { try body(newSrc, newDst) } catch { thrown = error }
        }
        if let coordinationError { throw coordinationError }
        if let thrown { throw thrown }
    }
}