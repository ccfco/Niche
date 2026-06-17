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
    /// 失焦提交(点面板内别处)。透传给 RenameTextField。
    var onRenameEndEditing: (String) -> Void = { _ in }
    /// Tab / ⇧Tab 提交并跳邻项(透传给 RenameTextField)。
    var onRenameTab: (String, Int) -> Void = { _, _ in }
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
    /// 待触发重命名代次:透传给 DragSourceView,面板收起后作废在途延迟重命名(防 .renaming 抑制泄漏)。
    var armToken: () -> Int = { 0 }

    @State private var thumbnail: NSImage?
    @State private var isHovered = false
    /// 文件名文字在本格坐标系内的 frame —— 慢速单击重命名只在命中此区域才触发(Finder:点图标
    /// 图片只选中,点文字才改名)。零值(未测量)= 不触发,安全默认。
    @State private var nameLabelRect: CGRect = .zero

    /// 本格私有坐标空间名:量 label frame 与 DragSourceView overlay 共用同一原点(格子左上)。
    private static let cellSpace = "fileCell"

    var body: some View {
        let cell = VStack(spacing: edge.innerSpacing) {
            artwork
                .frame(width: 48, height: 48)
                // id = 图标键(路径+标签+dataless) + mtime(图片缩略图随内容变):打标签不改 url/mtime,
                // 故必须含 tags 才会重取彩色图标;含 mtime 让图片内容更新也重取。
                // isCancelled 守:.task(id:) 切换会取消旧任务,但旧 QL 回调晚返回时 await 之后仍会执行,
                // 不守会用旧图标盖掉新态(异步缓存经典竞态)。
                .task(id: "\(ThumbnailCache.iconCacheKey(for: item, maxPixel: 96))|\(item.modificationDate.timeIntervalSince1970)") {
                    let img = await ThumbnailCache.shared.thumbnail(for: item, maxPixel: 96)
                    if !Task.isCancelled { thumbnail = img }
                }
            nameArea
                // 量文字标签 frame(本格坐标系)→ 慢速单击重命名命中判定。
                .background(GeometryReader { geo in
                    Color.clear.preference(key: NameRectKey.self,
                                           value: geo.frame(in: .named(Self.cellSpace)))
                })
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
        .onHover { hovering in isHovered = hovering }
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
                           isSoleSelection: isSoleSelection, onBeginRename: onBeginRename,
                           renameHitRect: { nameLabelRect }, armToken: armToken)
        } }
        .coordinateSpace(name: Self.cellSpace)
        .onPreferenceChange(NameRectKey.self) { nameLabelRect = $0 }

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

    /// 名称区:静态名(2 行中间截断,占位稳定)。重命名时静态名隐藏但保留占位,改名框走 overlay
    /// **不占位**浮在其上、向下溢出压住下方格子(由宿主网格抬该格 zIndex)→ 格子高度不变,不挤压
    /// 网格布局(Finder 图标视图重命名同款:框浮于上方,不顶开其它图标)。
    @ViewBuilder private var nameArea: some View {
        staticLabel
            .opacity(isRenaming ? 0 : 1)
            .overlay(alignment: .top) {
                if isRenaming {
                    // Finder 语义:聚焦即选中文件名主干,Enter 提交 / Esc 取消(见 RenameTextField)。
                    // multiline:多行换行,限高(~5 行)不无限撑;borderless 圆角框。
                    RenameTextField(initialName: item.name, onCommit: onRenameCommit,
                                    onCancel: onRenameCancel, onEndEditing: onRenameEndEditing,
                                    onTab: onRenameTab, multiline: true,
                                    cornerRadius: edge.itemCornerRadius)
                }
            }
    }

    /// 静态文件名:2 行中间截断(Finder 图标视图同款);全名靠系统 hover tooltip(.help)与进重命名
    /// 时的多行框查看——不在格子里自造展开浮层(那既不原生、又挤布局)。
    private var staticLabel: some View {
        Text(item.name)
            .font(.caption)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity)
            .help(item.name)
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

/// 文件名文字 frame(本格坐标系)—— 慢速单击重命名命中区。多 cell 各自独立,取最后(唯一)值。
private struct NameRectKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
