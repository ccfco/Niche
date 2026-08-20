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
    }

    struct Timing: Equatable {
        var hoverDelay: TimeInterval = 0.22
        var selectionDelay: TimeInterval = 0.18
        var selectionDuration: TimeInterval = 1.6
        var exitDelay: TimeInterval = 0.1
    }

    private struct Target: Equatable {
        let token: UUID
        let name: String
        let isTruncated: Bool
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

    func updateTarget(id: FileItem.ID, token: UUID, name: String, isTruncated: Bool) {
        let next = Target(token: token, name: name, isTruncated: isTruncated)
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
            selectionWork?.cancel()
            hoverWork = scheduler.schedule(after: timing.hoverDelay) { [weak self] in
                guard let self, self.hoveredID == id,
                      let current = self.targets[id], current.isTruncated else { return }
                self.hoverWork = nil
                self.presentation = Presentation(id: id, name: current.name, origin: .hover)
            }
        } else {
            guard hoveredID == id else { return }
            hoveredID = nil
            hoverWork?.cancel()
            hoverWork = nil
            guard presentation?.id == id, presentation?.origin == .hover else { return }
            scheduleHide(after: timing.exitDelay, matching: id)
        }
    }

    /// cursorID 同时覆盖鼠标单选、方向键和 type-ahead；延迟会合并连续方向键，只展示最终停稳项。
    func selectionChanged(to id: FileItem.ID?) {
        selectedID = id
        selectionWork?.cancel()
        selectionWork = nil
        hideWork?.cancel()
        hideWork = nil
        guard let id else {
            if presentation?.origin == .selection { presentation = nil }
            return
        }
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
            self.presentation = Presentation(id: id, name: current.name, origin: .selection)
            self.scheduleHide(after: self.timing.selectionDuration, matching: id)
        }
    }

    private func scheduleHide(after delay: TimeInterval, matching id: FileItem.ID) {
        hideWork?.cancel()
        hideWork = scheduler.schedule(after: delay) { [weak self] in
            guard let self, self.presentation?.id == id, self.hoveredID != id else { return }
            self.hideWork = nil
            self.presentation = nil
        }
    }
}

/// 两种文件名排版的截断合同。用与展示态相同的 AppKit 字体测量，不依赖字符串长度猜测。
enum FilenameTruncation {
    enum Layout {
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

/// 文件名单元只报告截断状态、hover 与锚点；浮层本体由 ContentPanelView 在面板根层统一绘制。
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
            .onHover { coordinator.hoverChanged(id: id, hovering: $0) }
            .onAppear { register() }
            .onChange(of: renderedWidth) { _, _ in register() }
            .onChange(of: name) { _, _ in register() }
            .onDisappear { coordinator.removeTarget(id: id, token: registrationToken) }
    }

    private func register() {
        coordinator.updateTarget(id: id, token: registrationToken, name: name, isTruncated: isTruncated)
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
                PositionedFullNameBubble(name: presentation.name, anchorRect: proxy[anchor],
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
                       margin: CGFloat, gap: CGFloat) -> CGPoint {
        let maxX = max(margin, container.width - margin - bubble.width)
        let x = min(max(anchor.midX - bubble.width / 2, margin), maxX)
        let below = anchor.maxY + gap
        let above = anchor.minY - gap - bubble.height
        let y: CGFloat
        if below + bubble.height <= container.height - margin {
            y = below
        } else if above >= margin {
            y = above
        } else {
            y = min(max(below, margin), max(margin, container.height - margin - bubble.height))
        }
        return CGPoint(x: x, y: y)
    }
}

private struct PositionedFullNameBubble: View {
    let name: String
    let anchorRect: CGRect
    let containerSize: CGSize
    let edge: EdgeMetrics
    @State private var bubbleSize: CGSize = .zero

    private var maxWidth: CGFloat {
        min(edge.base * 40, max(edge.base * 18, containerSize.width - edge.panelPadding * 2))
    }

    private var origin: CGPoint {
        FullNamePeekPlacement.origin(anchor: anchorRect, bubble: bubbleSize, container: containerSize,
                                     margin: edge.panelPadding, gap: edge.innerSpacing)
    }

    var body: some View {
        Text(name)
            .font(.system(size: 12))
            .multilineTextAlignment(.leading)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, edge.itemSpacing)
            .padding(.vertical, edge.innerSpacing * 1.5)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .glassEffect(.regular,
                         in: RoundedRectangle(cornerRadius: edge.controlCornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: edge.innerSpacing, y: edge.innerSpacing / 2)
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
