import SwiftUI
import AppKit

/// 顶部文件夹 tab 切换(spec §4.1:绑定多个真实文件夹,顶部 tab 切换;多文件夹是核心体验)。
/// tab = 书签(CLAUDE.md:稳定、用户钦定),支持**按住拖动重排**(实时让位,Safari 标签手感);
/// 重排走 `onMoveTab` → 宿主 `BindingStore.move`(已持久化)。临时「前往」tab 与「+」不参与重排。
///
/// 左键(点选 + 拖动重排)由 `TabReorderView` 这个 AppKit 视图接管 —— 必须认领并消费
/// `mouseDown`,否则左键拖 tab 会被窗口当成"拖背景移窗口"(pinned 下 `isMovableByWindowBackground`)。
/// 这是 SwiftUI `DragGesture` 解决不了的:左键事件穿透到 NSHostingView,窗口在 SwiftUI 手势之前
/// 就发起了移动。沿用 `DragSourceView` 同款"认领左键"模式根治。hover/右键 hitTest 返回 nil 透传。
struct FolderTabsView: View {
    @ObservedObject var model: PanelModel
    let edge: EdgeMetrics
    /// 「+」:弹添加菜单(选择文件夹 / 前往路径,由宿主以 NSMenu+抑制呈现,锚定按钮)。
    var onAddMenu: (_ anchor: NSView?) -> Void = { _ in }
    /// tab 右键:宿主构建带抑制的 NSMenu(复制路径 / 在 Finder 中显示 / 显示简介 / 重命名标签 / 移除);nil 不弹。
    var onTabMenu: (_ id: FolderBinding.ID) -> NSMenu? = { _ in nil }
    /// tab 标签就地改名提交(改 displayName);空名视为取消。
    var onRenameTabCommit: (_ id: FolderBinding.ID, _ newName: String) -> Void = { _, _ in }
    /// 某文件夹的引用菜单(复制路径 / 在 Finder 中显示 / 显示简介)。临时 tab 用它 —— 它不是
    /// 持久书签,只配文件夹引用操作(无重命名标签/移除,关闭走内联 ✕);与面包屑段同源。
    var onPathSegmentMenu: (_ url: URL) -> NSMenu? = { _ in nil }
    /// 把临时 tab(前往)钉成正式绑定。
    var onPinTemporary: () -> Void = {}
    /// 拖动重排提交:from = 正式 tab 原索引,to = `Array.move(toOffset:)` 语义的落点偏移。
    var onMoveTab: (_ from: Int, _ to: Int) -> Void = { _, _ in }
    /// 拖文件夹进 tab 栏 → 固定为常驻绑定(内容区子文件夹 / 外部 Finder 同走此路;非文件夹拒绝)。
    /// index = 插入光标落点(正式 tab 序);nil = 几何未就绪,宿主末尾追加兜底。
    var onDropFolders: (_ urls: [URL], _ index: Int?) -> Void = { _, _ in }

    /// 「+」菜单锚点(弹在按钮下方,toolbar 菜单惯例)。
    private let addAnchor = MenuAnchorBox()

    // MARK: 拖动重排状态
    /// 正被拖动的正式 tab;nil = 无拖动。
    @State private var draggingID: FolderBinding.ID?
    /// 拖动横向位移(跟手,不进动画事务)。
    @State private var dragOffset: CGFloat = 0
    /// 当前越界落点(正式 tab 序中的目标 index;进动画事务 → 邻居平滑让位)。
    @State private var dragTarget: Int?
    /// 各正式 tab 的静息 frame(bar 坐标系);`.offset` 不改它,故拖动中稳定。
    @State private var tabFrames: [FolderBinding.ID: CGRect] = [:]
    /// 外部拖文件夹悬停 tab 栏:落点 index(正式 tab 序,0...count);nil = 无拖入 → 此 index 及其后的
    /// 正式 tab 整体右让一个空槽示意将插入到此(见 dropShift),像内部排序一样"挤出位置"。
    @State private var dropInsertIndex: Int?
    /// 拖入是否进行中的引用型闸:drop/exit 即置 false。SwiftUI 在 drop 后偶发再补 dropUpdated 会重新
    /// 点亮空槽(竞态),闸关后一律忽略 —— 引用类型保证 delegate 闭包读到的是实时值(@State 值快照赢不了 race)。
    @State private var dropGate = DropGate()

    private let coordSpace = "nicheTabBar"
    private let reorderAnim = Animation.spring(response: 0.28, dampingFraction: 0.82)

    /// 正式 tab(非临时)的 id 顺序 —— 与 `BindingStore.bindings` 索引对齐(临时 tab 追加在后)。
    private var normalOrder: [FolderBinding.ID] {
        model.mirrors.filter { !$0.isTemporary }.map(\.binding.id)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: edge.innerSpacing) {
                ForEach(Array(model.mirrors.enumerated()), id: \.element.binding.id) { index, mirror in
                    if mirror.isTemporary {
                        temporaryTab(index: index, mirror: mirror)
                    } else {
                        tab(index: index, mirror: mirror)
                    }
                }
                addButton
            }
            .padding(.horizontal, edge.panelPadding)
            .padding(.vertical, edge.innerSpacing)
            .coordinateSpace(name: coordSpace)
            .onPreferenceChange(TabFramePreference.self) { tabFrames = $0 }
            // 拖文件夹进 tab 栏 → 定位固定为常驻绑定。只接文件夹(非文件夹 forbidden);落点 index 处
            // 及其后的 tab 整体让位腾出空槽示意插入(见 dropShift);宿主去重 + 按 index 插入。
            .onDrop(of: [.fileURL], delegate: FolderTabDropDelegate(
                onDropFolders: onDropFolders,
                insertionIndex: { point in computeInsertIndex(at: point) },
                setActive: { active in
                    dropGate.active = active
                    if !active { withAnimation(reorderAnim) { dropInsertIndex = nil } }
                },
                updateIndex: { point in
                    guard dropGate.active else { return }   // 闸关(drop 后的残余 dropUpdated)一律忽略
                    let idx = computeInsertIndex(at: point)
                    if idx != dropInsertIndex { withAnimation(reorderAnim) { dropInsertIndex = idx } }
                }
            ))
        }
    }

    private func tab(index: Int, mirror: DirectoryMirror) -> some View {
        let id = mirror.binding.id
        // 就地改名标签:渲染编辑框取代玻璃 tab(无 TabReorderView 接管,左键落进字段;
        // firstResponder is NSText 时面板键盘 monitor 整体放行,不吞输入)。
        if model.renamingTabID == id {
            return AnyView(renameTabField(id: id, initial: mirror.binding.displayName))
        }
        let isCurrent = index == model.currentTab
        let title = mirror.binding.displayName
        let isDragging = draggingID == id
        // 与 +/视图切换/底栏统一玻璃语言:当前 tab 用 isActive 常驻高亮,去掉裸 accent 方块(#15)。
        // Button 仅作玻璃外壳;点选/拖动由 TabReorderView 接管(它消费左键,Button 的 action 不触发)。
        return AnyView(Button {} label: {
            Text(title).lineLimit(1)
        }
        .buttonStyle(NicheFooterGlassButtonStyle(isActive: isCurrent, compact: true))
        // hover 即见完整磁盘路径(站在根目录看不到层级时的零空间兜底)。
        .help(mirror.binding.path)
        // 静息 frame 上报(bar 坐标系);`.offset` 不影响它,拖动中保持稳定。
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: TabFramePreference.self,
                                       value: [id: geo.frame(in: .named(coordSpace))])
            }
        )
        // 左键接管:单击切换 / 拖动重排;消费 mouseDown → 拖 tab 不触发窗口拖动。
        .overlay(
            TabReorderView(
                onSelect: { model.selectTab(index) },
                onDragChanged: { dx in
                    if draggingID == nil { draggingID = id }
                    dragOffset = dx
                    let t = computeTarget()
                    if t != dragTarget { withAnimation(reorderAnim) { dragTarget = t } }
                },
                onDragEnded: { commitReorder() }
            )
        )
        // 右键菜单走 RightClickCatcher+NSMenu(抑制驱动),不用 .contextMenu —— 那接不上
        // AutoHideCoordinator,菜单开着鼠标移出走廊面板会被收走(与文件右键同一根因)。
        .overlay(RightClickCatcher { _ in onTabMenu(id) })
        // 抬起跟手 + 让位:offset/scale 放在 overlay 之外,使接管层与可见 tab 一起移动。
        .scaleEffect(isDragging ? 1.04 : 1)
        .shadow(color: .black.opacity(isDragging ? 0.18 : 0), radius: isDragging ? 6 : 0, y: isDragging ? 2 : 0)
        .offset(x: reorderOffset(id: id) + dropShift(id: id))
        .zIndex(isDragging ? 1 : 0)
        // 无障碍:作为可切换标签项暴露,带当前选中态(Button 已是 .isButton,补 .isSelected)。
        .accessibilityLabel(title)
        .accessibilityAddTraits(isCurrent ? .isSelected : []))
    }

    /// tab 标签就地改名框(复用 RenameTextField:Enter 提交 / Esc 取消 / 失焦提交,Finder 语义)。
    /// 提交与失焦都经 `renamingTabID == id` 守卫,避免 teardown 二次提交(对齐文件改名)。
    private func renameTabField(id: FolderBinding.ID, initial: String) -> some View {
        RenameTextField(
            initialName: initial,
            onCommit: { name in
                onRenameTabCommit(id, name)
                model.endRenameTab()
            },
            onCancel: { if model.renamingTabID == id { model.endRenameTab() } },
            onEndEditing: { name in
                guard model.renamingTabID == id else { return }
                onRenameTabCommit(id, name)
                model.endRenameTab()
            },
            // tab 改的是书签别名(非文件名),无扩展名概念 → 全选,否则 `v2.0` 这类含点别名误选前缀。
            selectsStem: false
        )
        // minWidth..maxWidth 而非定宽:短名给足 120 编辑空间,长别名按内容撑开;封顶 280 防病态长名把
        // 单行框撑过视口 —— tab 栏是横向 ScrollView 不跟随 NSTextField 光标,无封顶则光标会滚出可视区。
        .frame(minWidth: 120, maxWidth: 280)
        .padding(.vertical, 1)
    }

    // MARK: 拖动重排几何

    /// 拖动中某正式 tab 的横向偏移:被拖的跟手,落点路径上的邻居整体让位一个"拖动宽度"。
    private func reorderOffset(id: FolderBinding.ID) -> CGFloat {
        guard let draggingID else { return 0 }
        if id == draggingID { return dragOffset }
        guard let from = normalOrder.firstIndex(of: draggingID),
              let target = dragTarget,
              let dragged = tabFrames[draggingID],
              let index = normalOrder.firstIndex(of: id) else { return 0 }
        let shift = dragged.width + edge.innerSpacing
        if from < target, index > from, index <= target { return -shift }   // 向右拖:中间项左移补位
        if from > target, index >= target, index < from { return shift }    // 向左拖:中间项右移让位
        return 0
    }

    /// 当前拖动落点(正式 tab 序的目标 index):被拖 tab 中心越过相邻 tab 中心即进退一档。
    private func computeTarget() -> Int? {
        guard let draggingID,
              let from = normalOrder.firstIndex(of: draggingID),
              let restMid = tabFrames[draggingID]?.midX else { return nil }
        let center = restMid + dragOffset
        let order = normalOrder
        var target = from
        while target < order.count - 1, let next = tabFrames[order[target + 1]]?.midX, center > next { target += 1 }
        while target > 0, let prev = tabFrames[order[target - 1]]?.midX, center < prev { target -= 1 }
        return target
    }

    private func commitReorder() {
        let from = draggingID.flatMap { normalOrder.firstIndex(of: $0) }
        let target = dragTarget
        withAnimation(reorderAnim) {
            draggingID = nil
            dragOffset = 0
            dragTarget = nil
        }
        if let from, let target, target != from {
            // Array.move(toOffset:) 语义:向右落点需 +1(删除原项前的插入位)。
            onMoveTab(from, target > from ? target + 1 : target)
        }
    }

    // MARK: 拖文件夹定位插入几何

    /// 鼠标 x 落点 → 正式 tab 序的插入 index(0...count):光标左边有几个 tab 中点即第几位。
    /// frames 未就绪 → 返回 count(末尾),宿主据 nil/越界兜底。坐标系与 DropInfo.location 同 coordSpace。
    private func computeInsertIndex(at point: CGPoint) -> Int? {
        let order = normalOrder
        guard !order.isEmpty else { return 0 }
        let mids = order.compactMap { tabFrames[$0]?.midX }
        guard mids.count == order.count else { return order.count }
        return mids.filter { $0 < point.x }.count
    }

    /// 空槽宽度:腾出"一个 tab"的位置示意(平均 tab 宽 + 间距,够明显又不突兀)。frames 未就绪给兜底。
    private var dropSlotWidth: CGFloat {
        let widths = normalOrder.compactMap { tabFrames[$0]?.width }
        guard !widths.isEmpty else { return 64 }
        return widths.reduce(0, +) / CGFloat(widths.count) + edge.innerSpacing
    }

    /// 拖文件夹悬停时,落点 index 及其后的正式 tab 整体右让一个空槽宽 —— 像内部排序一样"挤出位置",
    /// 直接展示将插入到此(比插入线更自然)。无拖入(dropInsertIndex == nil)时为 0。
    private func dropShift(id: FolderBinding.ID) -> CGFloat {
        guard let insert = dropInsertIndex,
              let idx = normalOrder.firstIndex(of: id) else { return 0 }
        return idx >= insert ? dropSlotWidth : 0
    }

    /// 拖入期间「+」始终右让一个空槽宽:无论中间还是末尾插入,落点之后的正式 tab(含最后一个)
    /// 都右移了一个空槽,「+」须同步右让,否则尾部 tab 会戳进「+」重叠(`.offset` 不改布局占位)。
    private var addButtonDropShift: CGFloat {
        dropInsertIndex != nil ? dropSlotWidth : 0
    }

    /// 临时 tab(前往根外目录):前往图标点出身份,内联 📌 钉住(转正式绑定)与 ✕ 关闭。
    /// 不用 .contextMenu 挂动作:SwiftUI 菜单不接 AutoHideCoordinator 抑制,菜单开着面板
    /// 可能被收走(文件右键走 RightClickCatcher+NSMenu 正是为此)。
    private func temporaryTab(index: Int, mirror: DirectoryMirror) -> some View {
        let isCurrent = index == model.currentTab
        return HStack(spacing: 2) {
            Button { model.selectTab(index) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right").font(.caption2)
                    Text(mirror.binding.displayName).lineLimit(1)
                }
            }
            .buttonStyle(NicheFooterGlassButtonStyle(isActive: isCurrent, compact: true))
            .help(mirror.binding.path)
            // 右键:文件夹引用操作(临时 tab 非书签,只配引用项;同面包屑段)。
            .overlay(RightClickCatcher { _ in onPathSegmentMenu(mirror.rootURL) })
            .accessibilityLabel(String(localized: "临时:\(mirror.binding.displayName)"))
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
            Button(action: onPinTemporary) { Image(systemName: "pin") }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(String(localized: "钉住为常驻文件夹"))
                .accessibilityLabel(String(localized: "钉住为常驻文件夹"))
            Button { model.closeTemporary() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(String(localized: "关闭临时文件夹"))
                .accessibilityLabel(String(localized: "关闭临时文件夹"))
        }
    }

    private var addButton: some View {
        Button { onAddMenu(addAnchor.view) } label: {
            Image(systemName: "plus")
        }
        .buttonStyle(NicheFooterGlassButtonStyle(compact: true))   // 与视图切换/底栏同一玻璃语言
        .background(MenuAnchor(box: addAnchor))
        .offset(x: addButtonDropShift)   // 末尾插入时右让,空槽落在最后一个 tab 之后
        .help(String(localized: "添加文件夹或前往路径"))
        .accessibilityLabel(String(localized: "添加文件夹或前往路径"))
    }
}

/// 收集各正式 tab 在 bar 坐标系的静息 frame,供拖动重排计算越界落点与让位量。
private struct TabFramePreference: PreferenceKey {
    static let defaultValue: [FolderBinding.ID: CGRect] = [:]
    static func reduce(value: inout [FolderBinding.ID: CGRect], nextValue: () -> [FolderBinding.ID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// tab 左键接管(沿用 DragSourceView 模式):认领并消费左键 `mouseDown`,使拖 tab 不被窗口当作
/// "拖背景移窗口"(根治与窗口拖动打架)。单击 → onSelect;横向拖过阈值 → onDragChanged(位移)/
/// onDragEnded。hover / 右键 / control-左键 hitTest 返回 nil 透传(玻璃高亮、右键菜单不受影响)。
struct TabReorderView: NSViewRepresentable {
    var onSelect: () -> Void = {}
    var onDragChanged: (_ translationX: CGFloat) -> Void = { _ in }
    var onDragEnded: () -> Void = {}

    func makeNSView(context: Context) -> TabReorderNSView {
        let v = TabReorderNSView()
        v.configure(onSelect: onSelect, onDragChanged: onDragChanged, onDragEnded: onDragEnded)
        return v
    }

    func updateNSView(_ nsView: TabReorderNSView, context: Context) {
        nsView.configure(onSelect: onSelect, onDragChanged: onDragChanged, onDragEnded: onDragEnded)
    }
}

final class TabReorderNSView: NSView {
    private var onSelect: () -> Void = {}
    private var onDragChanged: (CGFloat) -> Void = { _ in }
    private var onDragEnded: () -> Void = {}
    private var startX: CGFloat?
    private var dragging = false
    private let threshold: CGFloat = 6   // 区分点击与拖动(横向位移阈值,pt)

    func configure(onSelect: @escaping () -> Void, onDragChanged: @escaping (CGFloat) -> Void,
                   onDragEnded: @escaping () -> Void) {
        self.onSelect = onSelect
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
    }

    /// 双保险:即便 mouseDown 已消费,显式声明本视图区域不充当窗口拖动把手。
    override var mouseDownCanMoveWindow: Bool { false }

    /// 只认领左键;右键 / control-左键 / hover 返回 nil 透传给下层(RightClickCatcher / SwiftUI 玻璃高亮)。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            if event.modifierFlags.contains(.control) { return nil }   // control-左键当右键
            return super.hitTest(point)
        default:
            return nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        startX = event.locationInWindow.x
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startX else { return }
        let dx = event.locationInWindow.x - startX
        if !dragging, abs(dx) <= threshold { return }   // 阈值内仍当点击
        dragging = true
        onDragChanged(dx)
    }

    override func mouseUp(with event: NSEvent) {
        defer { startX = nil }
        if dragging { onDragEnded() } else { onSelect() }
        dragging = false
    }
}

/// tab 栏外来拖入:只接文件夹 → 固定为常驻绑定(添加书签语义,`.copy` 角标);非文件夹 `.forbidden`
/// (守 CLAUDE.md「不做暂存盘」定位 —— tab 是书签不是落盘区)。
/// 关键:文件夹判定与 URL 收集都走「`.drag` 剪贴板 + FileManager 命中真实文件系统」——
/// - 不用 `resourceValues(.isDirectoryKey)`:跨进程(Finder)拖入取不到 → 误判非文件夹 → 无让位。
/// - 不用 `loadObject(ofClass: URL.self)`:对文件夹拖入回 path 为空的 URL → 固定成空白「未命名」。
///   剪贴板里是 Finder / 内部拖拽源写入的真实 URL,path 完整、同步可读(无需异步 loadObject)。
/// 去重已绑定路径交宿主(NicheController.dropFolders)。
struct FolderTabDropDelegate: DropDelegate {
    let onDropFolders: ([URL], Int?) -> Void
    /// 鼠标落点 → 正式 tab 序的插入 index(由 View 提供,捕获当前 tabFrames)。
    var insertionIndex: (CGPoint) -> Int? = { _ in nil }
    /// 拖入进/出闸:true=进入(开始接受落点更新),false=移出/落地(收空槽 + 关闸)。
    var setActive: (Bool) -> Void = { _ in }
    /// 落点更新(含文件夹时跟随鼠标刷新空槽位置;闸关时 View 侧忽略,根治 drop 后残余更新点亮空槽)。
    var updateIndex: (CGPoint) -> Void = { _ in }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) { setActive(true) }
    func dropExited(info: DropInfo) { setActive(false) }

    /// 含文件夹 → copy(添加书签)+ 空槽跟随落点;否则 forbidden(不做暂存盘)+ 关闸收槽。
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let hasFolder = !folderURLs().isEmpty
        if hasFolder { updateIndex(info.location) } else { setActive(false) }
        return DropProposal(operation: hasFolder ? .copy : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        let index = insertionIndex(info.location)
        setActive(false)               // 先关闸:drop 后残余 dropUpdated 不再点亮空槽(根治空白卡住)
        let urls = folderURLs()
        guard !urls.isEmpty else { return false }
        onDropFolders(urls, index)
        return true
    }

    /// 从拖拽专用剪贴板**同步**取真实 file URL,过滤为「存在的目录」(同步可读,无需异步 loadObject)。
    private func folderURLs() -> [URL] {
        let pb = NSPasteboard(name: .drag)
        let urls = pb.readObjects(forClasses: [NSURL.self],
                                  options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
    }
}

/// 拖入进行中的引用型闸(见 FolderTabsView.dropGate)。引用类型保证 delegate 闭包读到实时值,
/// drop 后残余 dropUpdated 的竞态从构造上消除(值类型 @State 快照赢不了这场 race)。
final class DropGate {
    var active = false
}
