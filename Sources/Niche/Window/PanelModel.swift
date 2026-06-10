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
    /// 隐藏文件偏好的**唯一真相源**:面板 eye 按钮与设置页共绑此属性,didSet 同步镜像并持久化
    /// (此前设置页用 @AppStorage 另存一份:设置页改了面板无感、面板切了重启即丢)。
    @Published var showHidden: Bool = UserDefaults.standard.bool(forKey: "niche.showHidden") {
        didSet {
            mirrors.forEach { $0.showHidden = showHidden }
            UserDefaults.standard.set(showHidden, forKey: "niche.showHidden")
        }
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

    /// 拖入悬停的目录条目(目录格子/行是独立落点,悬停高亮提示"会落进这个文件夹")。
    /// 两模式共用单一真相;列表模式一行四列各是独立 drop region,同 id 计数避免列间切换闪烁。
    @Published private(set) var dropTargetID: FileItem.ID?
    private var dropTargetCount = 0

    /// 拖入悬停进/出某目录条目。同一条目可被多个 region 报告(列表的名称/大小/种类/日期列),
    /// 进出顺序不保证配对有序,计数归零才清除高亮。
    func setDropTarget(_ id: FileItem.ID, targeted: Bool) {
        if targeted {
            if dropTargetID == id { dropTargetCount += 1 } else { dropTargetID = id; dropTargetCount = 1 }
        } else if dropTargetID == id {
            dropTargetCount -= 1
            if dropTargetCount <= 0 { dropTargetID = nil; dropTargetCount = 0 }
        }
    }

    /// 落地/取消后无条件收口高亮:performDrop 只回报一次 exit,列表多列 region 重叠瞬间松手
    /// 时计数可能残留 > 0,靠减一清不掉(Codex review)。
    func clearDropTarget() {
        dropTargetID = nil
        dropTargetCount = 0
    }

    // MARK: - 路径输入(前往,spec:specs/2026-06-10-niche-path-input-design.md)

    /// 路径输入条是否展开(⌘⇧G / 键入 `/`、`~` 弹出;Esc/前往成功收起)。
    @Published private(set) var pathInputVisible = false
    /// 弹出时带入的首字符(键入 `/`、`~` 触发时不丢第一击)。
    private(set) var pathInputInitial = ""
    /// 聚焦代次:条已开但焦点回到列表后再次 ⌘⇧G/键入 `/` → 自增让输入框重新夺焦
    /// (NSView 无法被 model 直接夺焦,经 updateNSView 对比代次驱动)。
    private(set) var pathInputFocusToken = 0

    func beginPathInput(initial: String = "") {
        pathInputInitial = initial
        pathInputFocusToken += 1
        pathInputVisible = true
    }

    func endPathInput() {
        pathInputVisible = false
        pathInputInitial = ""
    }

    /// 只订阅当前 tab 的 mirror,避免后台 tab 的 FSEvents 触发无效面板刷新。
    private var currentMirrorCancellable: AnyCancellable?

    var currentMirror: DirectoryMirror? {
        mirrors.indices.contains(currentTab) ? mirrors[currentTab] : nil
    }

    /// 当前 tab 的镜像状态(空态/授权/卷卸载由 UI 据此切换)。
    var currentState: DirectoryMirror.State { currentMirror?.state ?? .idle }

    /// 排序结果缓存:sortedItems 是高频派生属性(一次按键/重渲染内 body、光标、键盘权威
    /// 会各取数次),localizedStandard 比较昂贵,大目录下每次全排序可感卡顿(性能审计)。
    /// 键 =(mirror 身份, 内容代次, 排序规则),任一变化才重排。
    private var sortedCache: (mirror: ObjectIdentifier, version: Int, order: FileSortOrder, value: [FileItem])?

    /// 当前 tab 经排序的可见条目。
    var sortedItems: [FileItem] {
        guard let mirror = currentMirror else { return [] }
        let id = ObjectIdentifier(mirror)
        if let cache = sortedCache, cache.mirror == id,
           cache.version == mirror.itemsVersion, cache.order == sortOrder {
            return cache.value
        }
        let sorted = mirror.items.sorted(by: sortOrder.comparator())
        sortedCache = (id, mirror.itemsVersion, sortOrder, sorted)
        return sorted
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
    /// 临时 tab(前往)不来自绑定列表,重建时原样保留在末位 —— 除非其路径已被「钉住」成正式
    /// 绑定(此时临时槽让位,选中将命中新绑定 id)。
    func rebuildMirrors(from bindings: [FolderBinding], selecting preferredID: FolderBinding.ID? = nil) {
        let desiredID = preferredID ?? currentMirror?.binding.id
        var rebuilt = bindings.map { DirectoryMirror(binding: $0, showHidden: showHidden) }
        // 去重比 rootURL(bookmark 解析结果)而非 binding.path:绑定目录被移动后持久化 path
        // 仍是旧值,按 path 比会同目录双 tab(Codex review)。
        if let temp = mirrors.first(where: \.isTemporary),
           !rebuilt.contains(where: {
               $0.rootURL.standardizedFileURL == temp.rootURL.standardizedFileURL
           }) {
            rebuilt.append(temp)
        }
        mirrors = rebuilt
        if let desiredID, let index = mirrors.firstIndex(where: { $0.binding.id == desiredID }) {
            currentTab = index
        } else {
            currentTab = min(currentTab, max(0, mirrors.count - 1))
        }
        subscribeToCurrent()
        // 不在此 arm:rebuild 可能发生在启动期,arm 会列目录触发 TCC,违反"权限按需触发、
        // 不启动弹"(spec §4.1.1)。arm 由调用方(面板可见时)或 selectTab/present 驱动。
    }

    // MARK: - 临时 tab(前往根外目录;单槽,不持久化)

    /// 当前的临时 mirror(至多一个)。
    var temporaryMirror: DirectoryMirror? { mirrors.first(where: \.isTemporary) }

    /// 打开/替换临时 tab 并切过去(用户显式动作,arm 可触发 TCC)。
    /// 单槽:再次前往根外路径即替换 —— 防 tab 泛滥,要常驻就「钉住」转正式绑定。
    func openTemporary(_ url: URL) {
        let binding = FolderBinding(path: url.path)   // 不入 BindingStore,不持久化
        let mirror = DirectoryMirror(binding: binding, showHidden: showHidden, isTemporary: true)
        if let index = mirrors.firstIndex(where: \.isTemporary) {
            mirrors[index] = mirror
            currentTab = index
        } else {
            mirrors.append(mirror)
            currentTab = mirrors.count - 1
        }
        clearSelection()
        subscribeToCurrent()
        armCurrent()
    }

    /// 关闭临时 tab(✕):回到最近一个正式 tab。
    func closeTemporary() {
        guard let index = mirrors.firstIndex(where: \.isTemporary) else { return }
        mirrors.remove(at: index)
        currentTab = min(currentTab, max(0, mirrors.count - 1))
        clearSelection()
        subscribeToCurrent()
        if !mirrors.isEmpty { armCurrent() }   // 关闭临时 tab 是用户动作,回落 tab 需要内容
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

    /// 清空选中(点空白 / 切 tab / 下钻)。同时结束就地重命名——这些路径都是"导航离开/取消选中",
    /// 重命名上下文已失效;否则键盘下钻(⌘↓/⌘↑)后 renamingItemID 残留会让 .renaming 抑制源泄漏,
    /// 面板永不自动收回(两模式等价:无论键盘还是鼠标导航都收口)。
    func clearSelection() {
        selectedIDs = []
        cursorID = nil
        anchorID = nil
        renamingItemID = nil
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
        } else if cursorID.map({ !ids.contains($0) }) ?? true {
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
