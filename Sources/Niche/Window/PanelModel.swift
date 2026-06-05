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
    @Published var showHidden = false {
        didSet { mirrors.forEach { $0.showHidden = showHidden } }
    }
    @Published var windowMode: WindowMode = .transient
    @Published var columns = 4
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

    /// 用绑定列表重建镜像(增删文件夹后调用)。保持当前 tab 在范围内。
    func rebuildMirrors(from bindings: [FolderBinding]) {
        mirrors = bindings.map { DirectoryMirror(binding: $0, showHidden: showHidden) }
        currentTab = min(currentTab, max(0, mirrors.count - 1))
        subscribeToCurrent()
        // 不在此 arm:rebuild 可能发生在启动期,arm 会列目录触发 TCC,违反"权限按需触发、
        // 不启动弹"(spec §4.1.1)。arm 只在 present()/selectTab() 等用户显式动作路径发生。
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
