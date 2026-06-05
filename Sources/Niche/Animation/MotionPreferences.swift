import AppKit
import Combine

/// 无障碍偏好(spec §4.3:**非可选**的无障碍底线)。运行时监听
/// `accessibilityDisplayOptionsDidChangeNotification`,不能只启动读一次。
///
/// - Reduce Motion:展开/交错动画降级为淡入。
/// - Reduce Transparency / Increase Contrast:Liquid Glass 材质降级为不透明纯色 + 实色描边
///   (材质重度依赖模糊,关掉透明必须保证可读)。
@MainActor
final class MotionPreferences: ObservableObject {
    @Published private(set) var reduceMotion: Bool
    @Published private(set) var reduceTransparency: Bool
    @Published private(set) var increaseContrast: Bool

    /// 材质是否应降级为不透明(降低透明度或增强对比度任一开启)。
    var prefersOpaque: Bool { reduceTransparency || increaseContrast }

    private var observer: NSObjectProtocol?

    init() {
        let ws = NSWorkspace.shared
        reduceMotion = ws.accessibilityDisplayShouldReduceMotion
        reduceTransparency = ws.accessibilityDisplayShouldReduceTransparency
        increaseContrast = ws.accessibilityDisplayShouldIncreaseContrast

        observer = ws.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    private func refresh() {
        let ws = NSWorkspace.shared
        reduceMotion = ws.accessibilityDisplayShouldReduceMotion
        reduceTransparency = ws.accessibilityDisplayShouldReduceTransparency
        increaseContrast = ws.accessibilityDisplayShouldIncreaseContrast
    }
}
