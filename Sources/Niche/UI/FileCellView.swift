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
    /// dataless 按需下载中:显 spinner 替代 iCloud 角标(#13)。
    var isDownloading: Bool = false
    /// 拖入悬停目标(目录格子,Finder 语义"会落进这个文件夹"):高亮环 + 底色。
    var isDropTarget: Bool = false
    let edge: EdgeMetrics
    var onRenameCommit: (String) -> Void = { _ in }
    var onRenameCancel: () -> Void = {}
    var makeContextMenu: (NSView) -> NSMenu? = { _ in nil }
    /// 单击选中(带修饰键:⌘ 离散 / ⇧ 区间 / 普通单选)。
    var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
    /// 双击激活(打开文件 / 进文件夹);VoiceOver 默认激活复用此回调。
    var onActivate: () -> Void = {}
    /// 拖出起止(接面板 auto-hide .draggingOut 抑制)。
    var onDragBegin: () -> Void = {}
    var onDragEnd: () -> Void = {}
    /// 拖出携带的 URL 集合(多选:拖已选中项 → 整组)。空回退本项。
    var dragURLs: () -> [URL] = { [] }
    /// 本项当前是否为唯一选中项(慢速单击重命名前置条件)。
    var isSoleSelection: () -> Bool = { false }
    /// 慢速单击触发就地重命名。
    var onBeginRename: () -> Void = {}
    /// 键盘光标项:无 hover 时也展开长名浮层,纯键盘浏览也能读全名。
    var isCurrent: Bool = false
    /// hover 变化上报宿主网格:让 hover 的格子 zIndex 抬高,长名浮层向下溢出不被相邻格遮住。
    var onHoverChange: (Bool) -> Void = { _ in }

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
        // 拖入悬停环(Finder 拖到文件夹上的高亮框同义):画在底色之上、角标/捕获层之下。
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: edge.itemCornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        // hover 高亮:鼠标移入给一层比选中态更淡的底,提示可点(选中态优先)。
        .onHover { hovering in
            isHovered = hovering
            onHoverChange(hovering)
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .overlay(alignment: .topTrailing) {
            if isDownloading {
                ProgressView().controlSize(.small).padding(edge.badgeInset)
            } else if item.isDataless {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.caption2).foregroundStyle(.secondary).padding(edge.badgeInset)
            }
        }
        .overlay(RightClickCatcher(makeMenu: makeContextMenu))   // 右键:自拼 NSMenu(hitTest 只认右键)
        .contentShape(Rectangle())
        // 左键(选中/双击)+ 拖出统一交给 AppKit DragSourceView:SwiftUI .onDrag 拿不到
        // NSDraggingSession 起止回调,无法抑制 auto-hide / 实现拖出即走。重命名态不拦截(让 TextField 可编辑)。
        .overlay { if !isRenaming {
            DragSourceView(url: item.url, onClick: onClick, onActivate: onActivate,
                           onDragBegin: onDragBegin, onDragEnd: onDragEnd, dragURLs: dragURLs,
                           isSoleSelection: isSoleSelection, onBeginRename: onBeginRename)
        } }

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

    /// 单元底色:拖入悬停(落点提示)> 选中(强调色)> hover(淡灰提示)> 无。强度收口到 GlassTokens(#16)。
    private var cellFill: Color {
        if isDropTarget { return Color.accentColor.opacity(GlassTokens.selectionFill) }
        if isSelected { return Color.accentColor.opacity(GlassTokens.selectionFill) }
        if isHovered { return Color.primary.opacity(GlassTokens.hoverFill) }
        return Color.clear
    }

    @ViewBuilder private var label: some View {
        if isRenaming {
            // Finder 语义:聚焦即选中文件名主干(不含扩展名),Enter 提交 / Esc 取消(见 RenameTextField)。
            RenameTextField(initialName: item.name, onCommit: onRenameCommit, onCancel: onRenameCancel)
                .frame(maxWidth: .infinity)
        } else {
            // 长名:静止两行中间截断(Finder 图标视图同款);hover/光标项浮起展开全显(见 FileNameLabel)。
            // .help 兜底全名 tooltip,与列表模式(#17)统一 —— 触控板/无 hover 路径也能读全名。
            FileNameLabel(name: item.name, expanded: isHovered || isCurrent, edge: edge)
                .help(item.name)
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

/// 图标模式文件名标签:静止两行中间截断(占位高度稳定,网格对齐不抖);hover 或光标项时
/// 浮起展开为完整多行 + 玻璃底(Finder 图标视图同款长名呈现 —— 原生正确性 > 功能数量)。
///
/// **只在真被截断时浮起**:隐藏的不限行副本测完整高度,大于受限两行态才 `isTruncated`,短名
/// 不套多余玻璃底。浮层走 `overlay` 不占位(不撑高格子,网格不错位);向下溢出由宿主网格的
/// zIndex 抬高压住相邻格(见 FileGridView)。玻璃材质/圆角复用既有体系,不引新魔法数(chrome 纪律)。
private struct FileNameLabel: View {
    let name: String
    let expanded: Bool
    let edge: EdgeMetrics
    @State private var isTruncated = false
    @State private var clipHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    var body: some View {
        baseText
            .lineLimit(2)
            .truncationMode(.middle)
            // 截断检测只在浮起态(hover/光标)挂载 —— 非展开 cell 零额外测量开销(Codex review)。
            .background { if expanded { truncationMeasurement } }
            .overlay(alignment: .top) {
                if expanded && isTruncated { expandedOverlay }
            }
            .animation(.easeOut(duration: 0.12), value: expanded)
    }

    private var baseText: some View {
        Text(name)
            .font(.caption)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    /// 展开浮层:不限行完整名 + 厚玻璃底(盖住下方格子保证可读),圆角同格子。
    private var expandedOverlay: some View {
        Text(name)
            .font(.caption)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, edge.innerSpacing)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: edge.itemCornerRadius, style: .continuous)
                    .fill(.thickMaterial)
            )
    }

    /// 截断测量层(隐藏,只在展开态挂载):同宽渲染「受限两行」与「不限行完整」两份,
    /// 高度差即被截断。preference 回调也收在此 —— 非展开 cell 不挂载、不刷新。
    private var truncationMeasurement: some View {
        ZStack {
            baseText
                .lineLimit(2)
                .background(GeometryReader { clip in
                    Color.clear.preference(key: ClipNameHeightKey.self, value: clip.size.height)
                })
            baseText
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { full in
                    Color.clear.preference(key: FullNameHeightKey.self, value: full.size.height)
                })
        }
        .hidden()
        .onPreferenceChange(ClipNameHeightKey.self) { clipHeight = $0; recomputeTruncation() }
        .onPreferenceChange(FullNameHeightKey.self) { fullHeight = $0; recomputeTruncation() }
    }

    private func recomputeTruncation() {
        let truncated = fullHeight > clipHeight + 1
        if truncated != isTruncated { isTruncated = truncated }
    }
}

/// 受限两行态高度(截断判定基准)。
private struct ClipNameHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 不限行完整高度(> 受限态即被截断)。
private struct FullNameHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
