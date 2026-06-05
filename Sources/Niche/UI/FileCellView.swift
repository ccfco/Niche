import SwiftUI

/// 网格单元:图标/缩略图 + 文件名。M1 用系统图标(`NSWorkspace.icon`);M2 接入
/// ThumbnailCache 后台 ImageIO 解码(spec §4.4:禁止 row 渲染路径同步解码)。
struct FileCellView: View {
    let item: FileItem
    let isSelected: Bool
    let edge: EdgeMetrics

    var body: some View {
        VStack(spacing: edge.innerSpacing) {
            icon
                .frame(width: 48, height: 48)
            Text(item.name)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(edge.innerSpacing)
        .background(
            RoundedRectangle(cornerRadius: edge.itemCornerRadius, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
        )
        .overlay(alignment: .topTrailing) {
            if item.isDataless {
                // iCloud 占位:云图标,不触发下载(spec §4.1.2)。
                Image(systemName: "icloud.and.arrow.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(2)
            }
        }
        .contentShape(Rectangle())
    }

    private var icon: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}
