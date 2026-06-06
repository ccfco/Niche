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
    private let motion: MotionPreferences
    private let actions: PanelActions
    private var notch: DynamicNotch<AnyView, EmptyView, EmptyView>?
    private(set) var isExpanded = false

    init(model: PanelModel, motion: MotionPreferences, actions: PanelActions) {
        self.model = model
        self.motion = motion
        self.actions = actions
    }

    /// 底层 NSPanel(DNK 暴露 windowController 供改底层窗口);用于挂失焦监听与几何读取。
    var panel: NSPanel? { notch?.windowController?.window as? NSPanel }

    private func makeNotchIfNeeded() -> DynamicNotch<AnyView, EmptyView, EmptyView> {
        if let notch { return notch }
        let model = self.model
        let motion = self.motion
        let actions = self.actions
        // hoverBehavior=.keepVisible:鼠标在面板上时不自动收(收回交给 AutoHideCoordinator)。
        let created = DynamicNotch<AnyView, EmptyView, EmptyView>(
            hoverBehavior: .keepVisible,
            style: .notch(topCornerRadius: 12, bottomCornerRadius: 20)
        ) {
            AnyView(ContentPanelView(model: model, motion: motion, actions: actions))
        }
        notch = created
        return created
    }

    /// 展开瞬态面板。
    /// - Parameter draggingFile: 由拖拽接管路径触发(用户手上拎着文件靠近刘海)。
    ///   此时换更利落的展开曲线(见 `openingAnimation` 注释),让落点尽快稳定。
    func expand(on screen: NSScreen, draggingFile: Bool) async {
        let notch = makeNotchIfNeeded()
        notch.transitionConfiguration = transitionConfiguration(draggingFile: draggingFile)
        await notch.expand(on: screen)
        isExpanded = true
    }

    func hide() async {
        guard let notch else { return }
        await notch.hide()
        isExpanded = false
    }

    /// 派生展开/收回动画(spec §4.3)。
    /// - Reduce Motion:去掉一切 spring 过冲,降级为纯 easeOut 淡入/淡出(非可选)。
    /// - 拖拽接管:默认 `.bouncy` 的回弹会让落点框漂移,换 `.snappy` 利落到位。
    /// - 普通呼出:`openingAnimation = nil` → 回落到 DNK 默认 `.bouncy`,保留"长出来"手感。
    private func transitionConfiguration(draggingFile: Bool) -> DynamicNotchTransitionConfiguration {
        if motion.reduceMotion {
            return .init(openingAnimation: .easeOut(duration: 0.2),
                         closingAnimation: .easeOut(duration: 0.18))
        }
        return .init(openingAnimation: draggingFile ? .snappy(duration: 0.25) : nil)
    }
}
