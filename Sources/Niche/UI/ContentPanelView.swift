import SwiftUI

/// 面板内容根视图:顶部 tab(M2)+ 网格 + 底栏。M1 只接单文件夹网格与底栏 Pin 按钮,
/// 验证窗口模型;多 tab、排序菜单、隐藏开关在 M2 接入。
struct ContentPanelView: View {
    @ObservedObject var model: PanelModel
    private let edge = EdgeMetrics.standard

    /// 由宿主注入的动作(打开/Pin 切换),解耦 UI 与 AppKit 控制器。
    var onOpen: (FileItem) -> Void = { _ in }
    var onTogglePin: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            FileGridView(model: model, edge: edge, onOpen: onOpen)
            Divider()
            BottomBarView(model: model, edge: edge, onTogglePin: onTogglePin)
        }
        .frame(minWidth: 360, minHeight: 240)
    }
}
