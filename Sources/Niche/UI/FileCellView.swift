import SwiftUI

/// 网格单元:图标/缩略图 + 文件名。M1 用系统图标(`NSWorkspace.icon`);M2 接入
/// ThumbnailCache 后台 ImageIO 解码(spec §4.4:禁止 row 渲染路径同步解码)。
struct FileCellView: View {
    let item: FileItem
    let isSelected: Bool
    let edge: EdgeMetrics

    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: edge.innerSpacing) {
            artwork
                .frame(width: 48, height: 48)
                .task(id: item.id) {
                    // 后台 ImageIO 解码(非 row 同步路径);dataless/非图片返回 nil → 用系统图标。
                    thumbnail = await ThumbnailCache.shared.thumbnail(for: item, maxPixel: 96)
                }
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

    @ViewBuilder private var artwork: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: edge.innerSpacing, style: .continuous))
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }
}
