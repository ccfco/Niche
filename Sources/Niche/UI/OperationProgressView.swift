import SwiftUI

/// 底栏上方的文件操作进度行:复制/移动/压缩进行中显示,完成后自动消失。
/// 单项操作显示 spinner(无法给出字节级比例),多项显示「已完成/总数」+ 可取消。
struct OperationProgressView: View {
    let progress: FileOperationProgress
    let edge: EdgeMetrics
    var onCancel: () -> Void = {}

    var body: some View {
        HStack(spacing: edge.itemSpacing) {
            // 状态区合并成一个读屏元素;取消按钮必须留在外面,否则会被合并进状态、无法单独操作。
            HStack(spacing: edge.itemSpacing) {
                if progress.isIndeterminate {
                    ProgressView().controlSize(.small)
                } else {
                    ProgressView(value: progress.fraction)
                        .controlSize(.small)
                        .frame(width: edge.base * 10)   // ~80pt,不挤占右侧留白
                }
                Text(progress.kind.title)
                Text(verbatim: "\(progress.completed)/\(progress.total)")
                    .monospacedDigit()
                if let name = progress.currentName, !progress.isIndeterminate {
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(progress.kind.title))
            .accessibilityValue(Text(verbatim: "\(progress.completed)/\(progress.total)"))
            Spacer(minLength: 0)
            Button(String(localized: "取消"), action: onCancel)
                .buttonStyle(NicheFooterGlassButtonStyle(compact: true))
                .controlSize(.small)
        }
        .font(.caption)
        .padding(.horizontal, edge.itemSpacing)
        .padding(.vertical, edge.innerSpacing)
    }
}