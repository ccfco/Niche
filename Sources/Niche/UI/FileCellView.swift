import SwiftUI
import UniformTypeIdentifiers

/// 网格单元:缩略图/系统图标 + 文件名(或就地重命名输入框)。
/// - 缩略图:后台 ImageIO 解码(非 row 同步路径,spec §4.4);dataless/非图片退系统图标。
/// - 拖出:`.draggable` 用**真实 file URL**(spec §4.5:不用 NSFilePromiseProvider)。
/// - 右键:overlay RightClickCatcher 弹自拼 NSMenu。
/// - 就地重命名:isRenaming 时显示 TextField。
struct FileCellView: View {
    let item: FileItem
    let isSelected: Bool
    let isRenaming: Bool
    let edge: EdgeMetrics
    var onRenameCommit: (String) -> Void = { _ in }
    var onRenameCancel: () -> Void = {}
    var makeContextMenu: (NSView) -> NSMenu? = { _ in nil }
    /// VoiceOver 默认激活(打开文件 / 进文件夹);与双击同义。
    var onActivate: () -> Void = {}

    @State private var thumbnail: NSImage?
    @State private var isHovered = false

    var body: some View {
        let cell = VStack(spacing: edge.innerSpacing) {
            artwork
                .frame(width: 48, height: 48)
                .task(id: item.id) {
                    thumbnail = await ThumbnailCache.shared.thumbnail(for: item, maxPixel: 96)
                }
            label
        }
        .padding(edge.innerSpacing)
        .background(
            RoundedRectangle(cornerRadius: edge.itemCornerRadius, style: .continuous)
                .fill(cellFill)
        )
        // hover 高亮:鼠标移入给一层比选中态更淡的底,提示可点(选中态优先)。
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .overlay(alignment: .topTrailing) {
            if item.isDataless {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.caption2).foregroundStyle(.secondary).padding(2)
            }
        }
        .overlay(RightClickCatcher(makeMenu: makeContextMenu))   // 右键:自拼 NSMenu
        .contentShape(Rectangle())
        // 拖出:真实 file URL(系统据此判同卷移动/跨卷复制)。
        .onDrag { NSItemProvider(object: item.url as NSURL) }

        // 无障碍:展示态把整格聚合为单一元素(VoiceOver 读"文件名,文件夹/文件,已选中");
        // 重命名态保留 children 可达,否则输入框对 VoiceOver 不可编辑。
        if isRenaming {
            cell
        } else {
            cell
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.name)
                .accessibilityValue(accessibilityValue)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                // onTapGesture 不会自动成为无障碍 action,显式补默认激活(打开/下钻)。
                .accessibilityAction { onActivate() }
        }
    }

    /// VoiceOver 读出的状态值:类型 +(iCloud 未下载时)占位提示。
    private var accessibilityValue: String {
        var parts = [item.isDirectory ? "文件夹" : "文件"]
        if item.isDataless { parts.append("未下载") }
        return parts.joined(separator: ",")
    }

    /// 单元底色:选中(强调色)> hover(淡灰提示)> 无。
    private var cellFill: Color {
        if isSelected { return Color.accentColor.opacity(0.25) }
        if isHovered { return Color.primary.opacity(0.08) }
        return Color.clear
    }

    @ViewBuilder private var label: some View {
        if isRenaming {
            // Finder 语义:聚焦即选中文件名主干(不含扩展名),Enter 提交 / Esc 取消(见 RenameTextField)。
            RenameTextField(initialName: item.name, onCommit: onRenameCommit, onCancel: onRenameCancel)
                .frame(maxWidth: .infinity)
        } else {
            Text(item.name)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
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
