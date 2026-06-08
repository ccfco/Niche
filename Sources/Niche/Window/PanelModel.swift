import SwiftUI
import Combine

/// 面板内容的共享状态(ObservableObject)。瞬态(DNK)与常驻(PinnedPanel)两个呈现宿主
/// 绑定**同一个** PanelModel —— Pin 切换时内容状态不丢(spec §4.6)。
///
/// 多 tab:每个绑定文件夹一个 DirectoryMirror(镜像数据源)。当前 tab 的 mirror 驱动网格。
@MainActor
final class PanelModel: ObservableObject {
    @Published private(set) var mirrors: [DirectoryMirror] = []
    @Published var currentTab: Int = 0
    @Published var selection = GridSelection(index: nil)
    @Published var sortOrder = FileSortOrder.default
    @Published var showHidden: Bool = UserDefaults.standard.bool(forKey: "niche.showHidden") {
        didSet { mirrors.forEach { $0.showHidden = showHidden } }
    }
    @Published var windowMode: WindowMode = .transient
    @Published var columns = 4
    /// 视图模式(列表/图标),持久化。列表=原生 Table(像访达);图标=网格。
    @Published var viewMode: FileViewMode = FileViewMode.load() {
        didSet { viewMode.save() }
    }
    /// 正在就地重命名的条目(spec §4.5 就地编辑 UI;§4.6 .renaming 抑制隐藏)。
    @Published var renamingItemID: FileItem.ID?

    /// 只订阅当前 tab 的 mirror,避免后台 tab 的 FSEvents 触发无效面板刷新。
    private var currentMirrorCancellable: AnyCancellable?

    var currentMirror: DirectoryMirror? {
        mirrors.indices.contains(currentTab) ? mirrors[currentTab] : nil
    }

    /// 当前 tab 的镜像状态(空态/授权/卷卸载由 UI 据此切换)。
    var currentState: DirectoryMirror.State { currentMirror?.state ?? .idle }

    /// 当前 tab 经排序的可见条目。
    var sortedItems: [FileItem] {
        (currentMirror?.items ?? []).sorted(by: sortOrder.comparator())
    }

    var selectedItem: FileItem? {
        guard let idx = selection.index, sortedItems.indices.contains(idx) else { return nil }
        return sortedItems[idx]
    }

    // MARK: - tab/镜像管理

    /// 用绑定列表重建镜像(增删/重排文件夹后调用)。
    /// 按 binding id 保留"当前正在看的文件夹"(`selecting` 显式指定则优先);只有原绑定被删才回退 clamp。
    /// 这样设置页重排不会让当前 tab 静默跳到另一个文件夹,新增也能精确选中(Codex review)。
    func rebuildMirrors(from bindings: [FolderBinding], selecting preferredID: FolderBinding.ID? = nil) {
        let desiredID = preferredID ?? currentMirror?.binding.id
        mirrors = bindings.map { DirectoryMirror(binding: $0, showHidden: showHidden) }
        if let desiredID, let index = mirrors.firstIndex(where: { $0.binding.id == desiredID }) {
            currentTab = index
        } else {
            currentTab = min(currentTab, max(0, mirrors.count - 1))
        }
        subscribeToCurrent()
        // 不在此 arm:rebuild 可能发生在启动期,arm 会列目录触发 TCC,违反"权限按需触发、
        // 不启动弹"(spec §4.1.1)。arm 由调用方(面板可见时)或 selectTab/present 驱动。
    }

    /// 切换 tab:arm 目标 mirror(打开 tab = 用户显式动作,可触发 TCC §4.1.1)。
    func selectTab(_ index: Int) {
        guard mirrors.indices.contains(index) else { return }
        currentTab = index
        selection = GridSelection(index: nil)
        subscribeToCurrent()
        armCurrent()
    }

    /// 仅把当前 tab mirror 的变化转发给自身(刷新网格)。
    private func subscribeToCurrent() {
        currentMirrorCancellable = currentMirror?.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// arm 当前 tab 的 mirror(只在用户动作路径上调用,不在后台/启动偷偷 arm 受保护目录)。
    func armCurrent() {
        currentMirror?.arm()
    }

    func move(_ direction: GridSelection.Direction) {
        selection = selection.moved(direction, columns: columns, count: sortedItems.count)
    }

    func beginRename(_ url: URL) { renamingItemID = url }
    func endRename() { renamingItemID = nil }

    /// 当前选中项的 URL 集合(MVP 单选;多选基础设施留待后续)。
    var selectionURLs: [URL] { selectedItem.map { [$0.url] } ?? [] }
}
