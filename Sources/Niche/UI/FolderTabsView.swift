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
    /// tab 右键:宿主构建带抑制的 NSMenu(移除此文件夹);nil 不弹。
    var onTabMenu: (_ id: FolderBinding.ID) -> NSMenu? = { _ in nil }
    /// 把临时 tab(前往)钉成正式绑定。
    var onPinTemporary: () -> Void = {}
    /// 拖动重排提交:from = 正式 tab 原索引,to = `Array.move(toOffset:)` 语义的落点偏移。
    var onMoveTab: (_ from: Int, _ to: Int) -> Void = { _, _ in }

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
        }
    }

    private func tab(index: Int, mirror: DirectoryMirror) -> some View {
        let id = mirror.binding.id
        let isCurrent = index == model.currentTab
        let title = mirror.binding.displayName
        let isDragging = draggingID == id
        // 与 +/视图切换/底栏统一玻璃语言:当前 tab 用 isActive 常驻高亮,去掉裸 accent 方块(#15)。
        // Button 仅作玻璃外壳;点选/拖动由 TabReorderView 接管(它消费左键,Button 的 action 不触发)。
        return Button {} label: {
            Text(title).lineLimit(1)
        }
        .buttonStyle(NicheFooterGlassButtonStyle(isActive: isCurrent, compact: true))
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
        .offset(x: reorderOffset(id: id))
        .zIndex(isDragging ? 1 : 0)
        // 无障碍:作为可切换标签项暴露,带当前选中态(Button 已是 .isButton,补 .isSelected)。
        .accessibilityLabel(title)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
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
            .accessibilityLabel("临时:\(mirror.binding.displayName)")
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
            Button(action: onPinTemporary) { Image(systemName: "pin") }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("钉住为常驻文件夹")
                .accessibilityLabel("钉住为常驻文件夹")
            Button { model.closeTemporary() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("关闭临时文件夹")
                .accessibilityLabel("关闭临时文件夹")
        }
    }

    private var addButton: some View {
        Button { onAddMenu(addAnchor.view) } label: {
            Image(systemName: "plus")
        }
        .buttonStyle(NicheFooterGlassButtonStyle(compact: true))   // 与视图切换/底栏同一玻璃语言
        .background(MenuAnchor(box: addAnchor))
        .help("添加文件夹或前往路径")
        .accessibilityLabel("添加文件夹或前往路径")
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
