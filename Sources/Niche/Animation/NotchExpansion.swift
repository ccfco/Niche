import AppKit
import SwiftUI
import DynamicNotchKit

/// 瞬态呈现(spec §4.3:从刘海"长出来"的展开动画)。
///
/// 用 DynamicNotchKit 承载瞬态面板,快速达成"初始宽=刘海宽,向下+两侧 morph 到全宽、
/// 圆角连续与刘海黑融为一体"的苹果味动画(spec §7 依赖策略 + §8 风险#1:先引库验证)。
/// Pin 后切到 PinnedPanelController 自有浮窗;DNK 只管瞬态。
@MainActor
final class NotchExpansion {
    private let model: PanelModel
    private let onOpen: (FileItem) -> Void
    private let onTogglePin: () -> Void
    private var notch: DynamicNotch<AnyView, EmptyView, EmptyView>?
    private(set) var isExpanded = false

    init(model: PanelModel,
         onOpen: @escaping (FileItem) -> Void,
         onTogglePin: @escaping () -> Void) {
        self.model = model
        self.onOpen = onOpen
        self.onTogglePin = onTogglePin
    }

    /// 底层 NSPanel(DNK 暴露 windowController 供改底层窗口);用于挂失焦监听与几何读取。
    var panel: NSPanel? { notch?.windowController?.window as? NSPanel }

    private func makeNotchIfNeeded() -> DynamicNotch<AnyView, EmptyView, EmptyView> {
        if let notch { return notch }
        let model = self.model
        let onOpen = self.onOpen
        let onTogglePin = self.onTogglePin
        // hoverBehavior=.keepVisible:鼠标在面板上时不自动收(收回交给 AutoHideCoordinator)。
        let created = DynamicNotch<AnyView, EmptyView, EmptyView>(
            hoverBehavior: .keepVisible,
            style: .notch(topCornerRadius: 12, bottomCornerRadius: 20)
        ) {
            AnyView(
                ContentPanelView(model: model, onOpen: onOpen, onTogglePin: onTogglePin)
            )
        }
        notch = created
        return created
    }

    func expand(on screen: NSScreen) async {
        let notch = makeNotchIfNeeded()
        await notch.expand(on: screen)
        isExpanded = true
    }

    func hide() async {
        guard let notch else { return }
        await notch.hide()
        isExpanded = false
    }
}
