import SwiftUI
import AppKit

/// 右键/次级点击捕获 overlay:SwiftUI 的 contextMenu 不暴露 open/close 回调,且 spec 要求
/// 用自拼 NSMenu。这里用透明 NSView 的 `menu(for:)` 钩子 —— AppKit 对右键与 control-左键统一
/// 调用它返回菜单并自动弹出(菜单 delegate 驱动 §4.6 抑制隐藏)。
/// hitTest 用 NSApp.currentEvent 只认领右键/control-左键,其余透传给下层 SwiftUI(左键选择/拖拽)。
struct RightClickCatcher: NSViewRepresentable {
    /// (anchorView) → 返回为该条目构建好的菜单(nil 则不弹)。
    let makeMenu: (NSView) -> NSMenu?

    func makeNSView(context: Context) -> RightClickNSView {
        let view = RightClickNSView()
        view.makeMenu = makeMenu
        return view
    }

    func updateNSView(_ nsView: RightClickNSView, context: Context) {
        nsView.makeMenu = makeMenu
    }
}

final class RightClickNSView: NSView {
    var makeMenu: ((NSView) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        makeMenu?(self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            return super.hitTest(point)
        case .leftMouseDown where event.modifierFlags.contains(.control):
            return super.hitTest(point)
        default:
            return nil   // 左键事件透传给下层 SwiftUI(选择/双击/拖出)
        }
    }
}
