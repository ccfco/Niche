import AppKit
import Combine

/// 活跃屏判定 + 刘海几何解析 + 屏幕参数变化监听(spec §4.2:多屏在鼠标活跃屏触发)。
@MainActor
final class ScreenObserver: ObservableObject {
    /// 屏幕配置变化(分辨率/接拔显示器/菜单栏隐藏)时自增,供呼出前重新解析几何。
    @Published private(set) var generation = 0

    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.generation += 1 }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// 鼠标当前所在屏(spec §4.2:在鼠标活跃屏触发);回退主屏。
    var activeScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// 解析某屏的刘海/回退几何。
    func resolution(for screen: NSScreen) -> NotchGeometry.Resolution {
        NotchGeometry.resolve(
            screenFrame: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width,
            auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width,
            menubarHeight: screen.frame.maxY - screen.visibleFrame.maxY
        )
    }
}
