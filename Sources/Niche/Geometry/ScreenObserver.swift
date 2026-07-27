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
    /// 找屏谓词与 HotZoneController 共用同一个(四边含 max 边):触发侧解析热区的屏和呈现侧
    /// 定锚点的屏必须是同一套判定,否则鼠标贴边(坐标恰在 frame 的 max 边)时两侧可能各选一块屏,
    /// 面板从错误的屏长出(NSMouseInRect 排除 x=maxX/y=minY,贴右/贴底会踩)。
    var activeScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first {
            HotZoneController.screenContainsMouse(frame: $0.frame, mouse: mouse)
        } ?? NSScreen.main
    }

    /// 解析某屏的刘海/回退几何。widthScale 见 NotchGeometry.resolve。
    func resolution(for screen: NSScreen, widthScale: CGFloat = 1.0) -> NotchGeometry.Resolution {
        NotchGeometry.resolve(
            screenFrame: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width,
            auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width,
            menubarHeight: screen.frame.maxY - screen.visibleFrame.maxY,
            widthScale: widthScale
        )
    }
}
