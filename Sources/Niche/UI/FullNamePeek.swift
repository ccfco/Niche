import AppKit
import SwiftUI

/// 两种文件名排版的截断合同。使用与真实展示态相同的 AppKit 字体测量，不按字符数猜测。
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

/// Finder 式完整名称帮助：默认只画两行/一行名称；仅当真实渲染宽度发生截断时，
/// 把系统 Help Tag 挂在**文字本身**。出现延迟、材质、边缘翻转和退出生命周期交给 macOS，
/// 不再维护会与选择、Quick Look、重命名争抢状态的自定义面板根层浮层。
struct TruncatedFilenameHelp<Label: View>: View {
    let name: String
    let layout: FilenameTruncation.Layout
    @ViewBuilder let label: () -> Label

    @State private var renderedWidth: CGFloat = 0

    private var isTruncated: Bool {
        FilenameTruncation.isTruncated(name, width: renderedWidth, layout: layout)
    }

    var body: some View {
        helpWhenNeeded
    }

    @ViewBuilder private var helpWhenNeeded: some View {
        if isTruncated {
            measuredLabel.help(name)
        } else {
            measuredLabel
        }
    }

    private var measuredLabel: some View {
        label()
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { renderedWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, width in renderedWidth = width }
                }
            }
    }
}
