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
    /// 选中条目 id 集合(多选,#5)。UI 据此画选中态;ops/拖出/QuickLook 用 selectionURLs。
    @Published private(set) var selectedIDs: Set<FileItem.ID> = []
    /// 键盘光标 / Quick Look 预览目标 / 激活(回车·双击)目标。单选时 = 该项;多选时 = 最近一次落点。
    @Published private(set) var cursorID: FileItem.ID?
    /// ⇧ 区间选择的锚点(单选/⌘点重置;⇧ 从锚点拉到光标)。
    private var anchorID: FileItem.ID?
    /// 排序态持久化(底栏菜单 / Table 表头共写此真相源,重启保留)。
    @Published var sortOrder = FileSortOrder.load() {
        didSet { sortOrder.save() }
    }
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
    /// 正在按需下载(dataless 双击打开)的条目:cell 显 spinner,不把未下载 URL 直接丢系统(#13)。
    @Published private(set) var downloadingIDs: Set<FileItem.ID> = []

    func beginDownload(_ id: FileItem.ID) { downloadingIDs.insert(id) }
    func endDownload(_ id: FileItem.ID) { downloadingIDs.remove(id) }

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

    /// 光标项(键盘焦点 / 预览 / 激活目标)。
    var cursorItem: FileItem? {
        guard let id = cursorID else { return nil }
        return sortedItems.first { $0.id == id }
    }

    /// 光标在当前排序后条目中的下标(供 Quick Look 定位 / 自动滚动)。
    var cursorIndex: Int? {
        guard let id = cursorID else { return nil }
        return sortedItems.firstIndex { $0.id == id }
    }

    /// 选中项(按当前排序顺序)。
    var selectedItems: [FileItem] {
        sortedItems.filter { selectedIDs.contains($0.id) }
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
        clearSelection()
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

    // MARK: - 选中(多选,#5/#6)

    /// 单选(普通点击 / 无修饰方向键):只选该项,重置光标与锚点。
    func selectSingle(_ id: FileItem.ID) {
        selectedIDs = [id]
        cursorID = id
        anchorID = id
    }

    /// 切换(⌘ 点击):离散增删该项,光标与锚点移到该项。
    func toggle(_ id: FileItem.ID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
        cursorID = id
        anchorID = id
    }

    /// 区间(⇧ 点击 / ⇧ 方向键):从锚点到该项(按当前排序顺序)整段选中,光标移到该项,锚点不动。
    func selectRange(to id: FileItem.ID) {
        let order = sortedItems.map(\.id)
        let anchor = anchorID ?? cursorID ?? id
        guard let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) else {
            selectSingle(id); return
        }
        let range = a <= b ? a...b : b...a
        selectedIDs = Set(order[range])
        cursorID = id
        anchorID = anchor
    }

    /// 全选(⌘A):选当前目录全部可见条目。
    func selectAll() {
        let order = sortedItems.map(\.id)
        selectedIDs = Set(order)
        cursorID = order.last
        anchorID = order.first
    }

    /// 清空选中(点空白 / 切 tab / 下钻)。
    func clearSelection() {
        selectedIDs = []
        cursorID = nil
        anchorID = nil
    }

    /// 列表原生 Table 的 Set selection 回写:镜像到模型 + 据增量推断光标。
    func syncListSelection(_ ids: Set<FileItem.ID>) {
        let added = ids.subtracting(selectedIDs)
        let baseIdx = cursorIndex ?? 0   // 旧光标下标(更新 selectedIDs 前算)
        selectedIDs = ids
        if !added.isEmpty {
            // Set 无序:在新增项里按 sortedItems 顺序取「距旧光标最远」者作为新光标(= ⇧ 扩展的 lead
            // 端 / ⌘ 点的唯一新增项),避免 Set.first 不确定导致 Quick Look 定位漂移(Codex review)。
            let order = sortedItems.map(\.id)
            cursorID = added
                .compactMap { id in order.firstIndex(of: id).map { (id: id, dist: abs($0 - baseIdx)) } }
                .max { $0.dist < $1.dist }?.id
        } else if cursorID == nil || !ids.contains(cursorID!) {
            cursorID = sortedItems.first { ids.contains($0.id) }?.id
        }
        anchorID = cursorID
    }

    /// 方向键移动光标。extend=⇧(从锚点拉区间);否则单选移动。
    /// 列表模式有效列数恒为 1(一维),图标模式用真实网格列数(避免列表 ↑↓ 按图标列跳多行 #1)。
    func moveCursor(_ direction: GridSelection.Direction, extend: Bool) {
        let order = sortedItems
        guard !order.isEmpty else { clearSelection(); return }
        let cols = viewMode == .list ? 1 : columns
        let current = cursorIndex
        let moved = GridSelection(index: current).moved(direction, columns: cols, count: order.count)
        guard let newIndex = moved.index, order.indices.contains(newIndex) else { return }
        let newID = order[newIndex].id
        if extend { selectRange(to: newID) } else { selectSingle(newID) }
    }

    func beginRename(_ url: URL) { renamingItemID = url }
    func endRename() { renamingItemID = nil }

    /// 选中项 URL 集合(多选;按当前排序顺序)。拷贝 / 拖出 / 废纸篓 / 右键作用于此。
    var selectionURLs: [URL] { selectedItems.map(\.url) }
}
