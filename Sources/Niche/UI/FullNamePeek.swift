import AppKit
import SwiftUI

/// 被截断文件名的“速览”状态机。只管意图与生命周期，不持有 View：列表和图标视图
/// 共用同一套 hover / 选中语义，面板根层只渲染一个浮层。
@MainActor
final class FullNamePeekCoordinator: ObservableObject {
    enum Origin: Equatable { case hover, selection }

    struct Presentation: Equatable {
        let id: FileItem.ID
        let name: String
        let origin: Origin
        let layout: FilenameTruncation.Layout
    }

    struct Timing: Equatable {
        var hoverDelay: TimeInterval = 0.4
        var selectionDelay: TimeInterval = 0.15
        var exitDelay: TimeInterval = 0.1
    }

    private struct Target: Equatable {
        let token: UUID
        let name: String
        let isTruncated: Bool
        let layout: FilenameTruncation.Layout
    }

    @Published private(set) var presentation: Presentation?

    private let timing: Timing
    private let scheduler: HoverIntent.Scheduler
    private var targets: [FileItem.ID: Target] = [:]
    private var hoveredID: FileItem.ID?
    private var selectedID: FileItem.ID?
    private var hoverWork: HoverIntent.Cancelable?
    private var selectionWork: HoverIntent.Cancelable?
    private var hideWork: HoverIntent.Cancelable?

    init(timing: Timing = Timing(), scheduler: HoverIntent.Scheduler = DispatchScheduler()) {
        self.timing = timing
        self.scheduler = scheduler
    }

    func updateTarget(id: FileItem.ID, token: UUID, name: String, isTruncated: Bool,
                      layout: FilenameTruncation.Layout) {
        let next = Target(token: token, name: name, isTruncated: isTruncated, layout: layout)
        guard targets[id] != next else { return }
        targets[id] = next
        if !isTruncated, presentation?.id == id {
            presentation = nil
        } else if isTruncated, selectedID == id, presentation == nil {
            scheduleSelection(for: id)
        }
    }

    /// LazyVGrid / Table 会回收离屏条目。token 防止旧 View 的 disappear 把同 id 的新 View 注册删掉。
    func removeTarget(id: FileItem.ID, token: UUID) {
        guard targets[id]?.token == token else { return }
        targets[id] = nil
        if hoveredID == id { hoveredID = nil; hoverWork?.cancel(); hoverWork = nil }
        if presentation?.id == id { presentation = nil }
    }

    func hoverChanged(id: FileItem.ID, hovering: Bool) {
        if hovering {
            guard let target = targets[id], target.isTruncated else { return }
            hoveredID = id
            hoverWork?.cancel()
            hideWork?.cancel()
            hoverWork = scheduler.schedule(after: timing.hoverDelay) { [weak self] in
                guard let self, self.hoveredID == id,
                      let current = self.targets[id], current.isTruncated else { return }
                self.hoverWork = nil
                self.presentation = Presentation(id: id, name: current.name, origin: .hover,
                                                 layout: current.layout)
            }
        } else {
            guard hoveredID == id else { return }
            hoveredID = nil
            hoverWork?.cancel()
            hoverWork = nil
            guard presentation?.id == id, presentation?.origin == .hover else { return }
            scheduleHoverExit(after: timing.exitDelay, matching: id)
        }
    }

    /// cursorID 同时覆盖鼠标单选、方向键和 type-ahead；延迟会合并连续方向键，只展示最终停稳项。
    func selectionChanged(to id: FileItem.ID?) {
        selectedID = id
        selectionWork?.cancel()
        selectionWork = nil
        hideWork?.cancel()
        hideWork = nil
        if presentation?.origin == .selection, presentation?.id != id {
            presentation = nil
        }
        guard let id else {
            return
        }
        // 鼠标正在临时查看另一项时不抢回浮层；移出后恢复新选中的光标项。
        if presentation?.origin == .hover || hoveredID != nil { return }
        scheduleSelection(for: id)
    }

    /// 重命名、拖拽、菜单、Quick Look、导航和面板收起都通过此入口彻底收口。
    func dismiss() {
        hoverWork?.cancel(); hoverWork = nil
        selectionWork?.cancel(); selectionWork = nil
        hideWork?.cancel(); hideWork = nil
        hoveredID = nil
        selectedID = nil
        presentation = nil
    }

    private func scheduleSelection(for id: FileItem.ID) {
        guard let target = targets[id], target.isTruncated else { return }
        selectionWork?.cancel()
        selectionWork = scheduler.schedule(after: timing.selectionDelay) { [weak self] in
            guard let self, self.selectedID == id,
                  let current = self.targets[id], current.isTruncated else { return }
            self.selectionWork = nil
            self.presentation = Presentation(id: id, name: current.name, origin: .selection,
                                             layout: current.layout)
        }
    }

    private func scheduleHoverExit(after delay: TimeInterval, matching id: FileItem.ID) {
        hideWork?.cancel()
        hideWork = scheduler.schedule(after: delay) { [weak self] in
            guard let self, self.presentation?.id == id, self.hoveredID != id else { return }
            self.hideWork = nil
            self.presentation = nil
            guard let selectedID = self.selectedID else { return }
            self.scheduleSelection(for: selectedID)
        }
    }
}

/// 两种文件名排版的截断合同。用与展示态相同的 AppKit 字体测量，不依赖字符串长度猜测。
enum FilenameTruncation {
    enum Layout: Equatable {
        case list
        case grid

        fileprivate var font: NSFont {
            switch self {
            case .list: return .systemFont(ofSize: NSFont.systemFontSize)
            case .grid: return .systemFont(ofSize: 12)
            }
        }
    }

    static func isTruncated(_ name: String, width: CGFloat, layout: Layout) -> Bool {
        guard width > 1, !name.isEmpty else { return false }
        let attributes: [NSAttributedString.Key: Any] = [.font: layout.font]
        switch layout {
        case .list:
            let natural = ceil((name as NSString).size(withAttributes: attributes).width)
            return natural > floor(width) + 1
        case .grid:
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byCharWrapping
            let rect = (name as NSString).boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: layout.font, .paragraphStyle: paragraph]
            )
            return ceil(rect.height) > ceil(layout.font.boundingRectForFont.height * 2) + 1
        }
    }
}

/// 文件名只报告截断状态与原位锚点；整个文件单元的 hover 由调用方上报，避免要求用户精准指向文字。
struct FullNamePeekTarget<Label: View>: View {
    @ObservedObject var coordinator: FullNamePeekCoordinator
    let id: FileItem.ID
    let name: String
    let layout: FilenameTruncation.Layout
    @ViewBuilder let label: () -> Label

    @State private var renderedWidth: CGFloat = 0
    @State private var registrationToken = UUID()

    private var isTruncated: Bool {
        FilenameTruncation.isTruncated(name, width: renderedWidth, layout: layout)
    }

    var body: some View {
        label()
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { renderedWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, width in renderedWidth = width }
                }
            }
            .anchorPreference(key: FullNameAnchorPreferenceKey.self, value: .bounds) { [id: $0] }
            // 展开态替代原截断文本，不同时显示两份名称；布局占位仍保留，网格不会跳动。
            .opacity(coordinator.presentation?.id == id ? 0 : 1)
            .onAppear { register() }
            .onChange(of: renderedWidth) { _, _ in register() }
            .onChange(of: name) { _, _ in register() }
            .onDisappear { coordinator.removeTarget(id: id, token: registrationToken) }
    }

    private func register() {
        coordinator.updateTarget(id: id, token: registrationToken, name: name,
                                 isTruncated: isTruncated, layout: layout)
    }
}

struct FullNameAnchorPreferenceKey: PreferenceKey {
    static let defaultValue: [FileItem.ID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [FileItem.ID: Anchor<CGRect>],
                       nextValue: () -> [FileItem.ID: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}

/// 面板内的单一速览浮层。不是 popover/辅助窗口，因此不会抢 key、触发 auto-hide 或跨 Space 漂移。
struct FullNamePeekOverlay: View {
    @ObservedObject var coordinator: FullNamePeekCoordinator
    @ObservedObject var motion: MotionPreferences
    let anchors: [FileItem.ID: Anchor<CGRect>]
    let edge: EdgeMetrics

    var body: some View {
        GeometryReader { proxy in
            if let presentation = coordinator.presentation,
               let anchor = anchors[presentation.id] {
                PositionedFullNameBubble(presentation: presentation, anchorRect: proxy[anchor],
                                         containerSize: proxy.size, edge: edge)
                    .id(presentation.id)
                    .transition(motion.reduceMotion
                                ? .opacity
                                : .opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.easeOut(duration: motion.reduceMotion ? 0.1 : 0.15),
                   value: coordinator.presentation)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct FullNamePeekPlacement {
    static func origin(anchor: CGRect, bubble: CGSize, container: CGSize,
                       margin: CGFloat, layout: FilenameTruncation.Layout) -> CGPoint {
        let maxX = max(margin, container.width - margin - bubble.width)
        let preferredX = layout == .grid ? anchor.midX - bubble.width / 2 : anchor.minX - margin / 2
        let x = min(max(preferredX, margin), maxX)
        // 覆盖原文件名而非另起一条提示：图标模式顶边对齐，列表模式垂直居中。
        let preferredY = layout == .grid ? anchor.minY - margin / 2 : anchor.midY - bubble.height / 2
        let maxY = max(margin, container.height - margin - bubble.height)
        let y = min(max(preferredY, margin), maxY)
        return CGPoint(x: x, y: y)
    }
}

private struct PositionedFullNameBubble: View {
    let presentation: FullNamePeekCoordinator.Presentation
    let anchorRect: CGRect
    let containerSize: CGSize
    let edge: EdgeMetrics
    @State private var bubbleSize: CGSize = .zero

    private var bubbleWidth: CGFloat {
        let font = presentation.layout.font
        let natural = ceil((presentation.name as NSString).size(withAttributes: [.font: font]).width)
        let available = containerSize.width - edge.panelPadding * 2
        switch presentation.layout {
        case .grid:
            // 图标模式守住当前列的归属感：宽度只比标准格略宽，长名称向下换行，禁止再横跨数列。
            let minimum = edge.cellWidth + edge.itemSpacing * 2
            let cap = min(edge.cellWidth + edge.sectionSpacing * 2, available)
            return min(max(anchorRect.width + edge.itemSpacing * 2, minimum), cap)
        case .list:
            // 列表行天然横向阅读，按内容增长更易扫读，但仍限制在紧凑的面板内浮层宽度。
            let cap = min(edge.base * 32.5, available)
            return min(natural + edge.itemSpacing * 2, cap)
        }
    }

    private var origin: CGPoint {
        FullNamePeekPlacement.origin(anchor: anchorRect, bubble: bubbleSize, container: containerSize,
                                     margin: edge.panelPadding, layout: presentation.layout)
    }

    var body: some View {
        Text(presentation.name)
            .font(.system(size: 12))
            .multilineTextAlignment(presentation.layout == .grid ? .center : .leading)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, edge.itemSpacing)
            .padding(.vertical, edge.innerSpacing)
            .frame(width: bubbleWidth,
                   alignment: presentation.layout == .grid ? .center : .leading)
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: edge.itemCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: edge.itemCornerRadius, style: .continuous)
                    .strokeBorder(presentation.origin == .selection
                                  ? Color.accentColor.opacity(0.28)
                                  : Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.08), radius: edge.innerSpacing, y: edge.innerSpacing / 2)
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { bubbleSize = geometry.size }
                        .onChange(of: geometry.size) { _, size in bubbleSize = size }
                }
            }
            .opacity(bubbleSize == .zero ? 0 : 1)
            .position(x: origin.x + bubbleSize.width / 2,
                      y: origin.y + bubbleSize.height / 2)
    }
}
