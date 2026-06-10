import AppKit
import SwiftUI

/// 统一面板宿主:瞬态(hover 用完即走)与常驻(Pin)是**同一个** `NichePanel` 的两种行为,
/// 不是两套窗口、也不是两套代码 —— Pin 只翻 `WindowMode`(焦点/监听策略),**frame 一字节不动**。
///
/// 替代了旧的 NotchExpansion(DNK 黑底刘海板,吞玻璃)+ PinnedPanelController(另一个 titled 窗)。
///
/// - 尺寸:单一**标准尺寸**(宽恰容 5 列单元格,派生自网格;两模式共用,Pin 不改、不可 resize)。
/// - 瞬态:从刘海下方"长出来"(frame 动画)+ 鼠标离开"面板↔刘海"走廊即收。
/// - 常驻:就地变 floating、可激活、可拖动(detach);不长出、不改尺寸。
@MainActor
final class PanelController {
    private(set) var panel: NichePanel?
    private let model: PanelModel
    private let motion: MotionPreferences
    private let actions: PanelActions
    private let edge = EdgeMetrics.standard

    /// 瞬态下鼠标离开"面板↔刘海"走廊(宿主据此过 AutoHideCoordinator 抑制判定后收回)。
    var onMouseExitedTransient: (() -> Void)?

    private var mouseMonitors: [Any] = []
    /// 面板键盘权威:本地 keyDown monitor(先于响应链收到事件)。面板可见即装,收回即卸。
    /// 取代旧的 SwiftUI 面板级 `.onKeyPress` —— 后者在「父视图聚焦 vs Table 抢焦点」两态行为不一致
    /// (列表 ↑↓ 跳行 #1、空格被 Table 吞 #2/#22)。monitor 与 SwiftUI 焦点无关,行为确定。
    private var keyMonitor: Any?
    private var leaveWorkItem: DispatchWorkItem?
    /// 瞬态 keep-alive 区域基准(面板 frame ∪ 此矩形);防 hover-收-再 hover 闪烁。
    /// 贴刘海时=刘海矩形(连成走廊);脱离刘海(unpin)时=面板自身。
    private var anchorRect: CGRect = .zero
    /// 淡出竞态守卫:每次显示自增;hide 淡出回调若被新一次显示抢占(代次不符)则放弃 orderOut。
    private var showGeneration = 0
    private var isHiding = false
    /// 瞬态生长动画进行中:抑制 relayoutHeight,避免高度重算与展开动画相互覆盖(#14)。
    private var isPresenting = false
    /// 窗面玻璃:**不直接当 contentView**(那样会随窗口逐帧 resize → NSGlassEffectView 自带液态
    /// morph,呼出动画又慢又横扫)。改作 clipsToBounds 容器内的顶部锚定子视图,尺寸固定、只被裁切
    /// 露出 → 玻璃 bounds 全程不变,无 morph(见 ensurePanel / snapGlass / presentTransient)。
    private var glass: NSGlassEffectView?

    init(model: PanelModel, motion: MotionPreferences, actions: PanelActions) {
        self.model = model
        self.motion = motion
        self.actions = actions
    }

    /// 兜底:controller 释放时若 monitor 仍在,移除避免泄漏(直接访问存储属性 + nonisolated
    /// removeMonitor,不触碰 @MainActor 方法 —— 守 CLAUDE.md deinit 红线)。
    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var mode: WindowMode { panel?.mode ?? .transient }
    var isTransientShown: Bool { isVisible && mode == .transient }

    /// 固定列数:宽度 = 6 列单元格精确和(永不裁切半格,派生自 EdgeMetrics)。两模式共用、Pin 不改。
    private let columns = 6

    private var panelWidth: CGFloat {
        CGFloat(columns) * edge.cellWidth + CGFloat(columns - 1) * edge.itemSpacing + edge.panelPadding * 2
    }

    /// 高度按条目数 + 视图模式自适应:有几行就多高(消灭空白),超出上限滚动。
    /// 列表行矮(~26)、行数=条目数;图标行高(~98)、行数=ceil(条目/列)。chrome 含 tab/工具栏/分隔(列表多表头)。
    /// 下钻后多一行面包屑(#7 加的路径栏),计入 chrome 否则内容被挤压(#14)。
    private func panelHeight(itemCount: Int) -> CGFloat {
        let count = max(itemCount, 1)
        let breadcrumb: CGFloat = (model.currentMirror?.canGoUp == true) ? 34 : 0
        if model.viewMode == .list {
            let rowHeight: CGFloat = 26
            let chrome: CGFloat = 112        // tab + 表头 + 底栏 + 分隔 + padding
            let rows = max(4, min(12, count))
            return (chrome + breadcrumb + CGFloat(rows) * rowHeight).rounded()
        } else {
            let rowHeight: CGFloat = 98
            let chrome: CGFloat = 96
            let rows = max(2, min(5, Int(ceil(Double(count) / Double(columns)))))
            return (chrome + breadcrumb + CGFloat(rows) * rowHeight).rounded()
        }
    }

    /// 内容/视图模式/下钻态变化后重算高度并动画到新高度(#14)。顶边固定(从刘海向下生长;
    /// pinned 保持顶左固定,避免和用户拖动后的位置冲突 —— 只改高度不改顶点)。高度无变化即跳过。
    func relayoutHeight() {
        guard let panel, panel.isVisible, !isHiding, !isPresenting else { return }
        // 用未排序 items.count(高度只关心条目数,与顺序无关)——避免每次 relayout 触发 sortedItems
        // 全量排序(objectWillChange 高频,选中移动也触发,排序代价不该白花,Codex review)。
        let count = model.currentMirror?.items.count ?? 0
        let newHeight = panelHeight(itemCount: count)
        let frame = panel.frame
        guard abs(frame.height - newHeight) > 1 else { return }
        let top = frame.maxY   // 顶边不动
        var originY = top - newHeight
        // 屏幕底部夹取:pinned 拖到屏幕下方后向下生长可能越界,保证不低于可视区下沿(Codex review)。
        if let screenMinY = panel.screen?.visibleFrame.minY, originY < screenMinY {
            originY = screenMinY
        }
        let newFrame = NSRect(x: frame.origin.x, y: originY, width: frame.width,
                              height: top - originY)
        snapGlass(toContentHeight: newFrame.height)   // 同 present:玻璃先到新高度,窗口裁切露出(无 morph)
        if motion.reduceMotion {
            panel.setFrame(newFrame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(newFrame, display: true)
            }
        }
    }

    // MARK: - 显示 / 收起

    /// 呼出瞬态:从刘海/回退区下方"长出来"(nonactivating 取键焦点做导航但不抢前台)+ 起鼠标离开监听。
    func presentTransient(below resolution: NotchGeometry.Resolution, itemCount: Int) {
        let panel = ensurePanel()
        showGeneration += 1
        isHiding = false
        startKeyMonitor()
        panel.mode = .transient
        let target = standardFrame(below: resolution, itemCount: itemCount)
        anchorRect = resolution.rect
        // 起始:刘海宽的小条,顶边贴刘海底 → 向下+两侧长到标准尺寸。
        let start = NSRect(x: target.midX - resolution.rect.width / 2,
                           y: target.maxY - 6, width: resolution.rect.width, height: 6)
        panel.setFrame(start, display: false)
        snapGlass(toContentHeight: target.height)   // 玻璃先到目标尺寸,窗口长大只是裁切露出(无 morph)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        let dur = motion.reduceMotion ? 0.16 : 0.3
        isPresenting = true   // 生长动画期间抑制 relayout,避免与展开动画打架(#14)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = dur
            ctx.timingFunction = CAMediaTimingFunction(name: motion.reduceMotion ? .easeOut : .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            self?.isPresenting = false
        })
        startMouseLeaveMonitor()
    }

    /// 复现常驻(全局快捷键再次呼出已 pin 的窗):就地 orderFront + 激活,不长出、不改尺寸/位置。
    func revealPinned() {
        let panel = ensurePanel()
        showGeneration += 1
        isHiding = false
        startKeyMonitor()
        panel.mode = .pinned
        // 离屏自救:拖到外接屏后拔屏,frame 可能整窗落在所有屏可视区外 ——"显示了"但看不见,
        // 且 pin 态不动 frame,用户无任何路径把它拽回来。回拉到鼠标所在屏(无则主屏)中央。
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            if let vf = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: vf.midX - panel.frame.width / 2,
                                             y: vf.midY - panel.frame.height / 2))
            }
        }
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 收起:瞬态**几何收回刘海**(与 present 长出对称)+ 淡出;常驻(脱离刘海)仅淡出。
    /// 收回时**不动玻璃**——玻璃仍是满尺寸顶部锚定,窗口缩成刘海小条只是容器从底部裁掉玻璃、向刘海口
    /// 收拢,玻璃 bounds 全程不变 → 同 present 零 morph(复用同一根治思路)。
    func hide() {
        stopMouseLeaveMonitor()
        stopKeyMonitor()
        guard let panel, panel.isVisible, !isHiding else { return }
        isHiding = true
        let gen = showGeneration
        let dur = motion.reduceMotion ? 0.12 : 0.18
        // 瞬态:收回目标 = 刘海宽小条,顶边贴当前顶(present start 的镜像);常驻不收(已脱离刘海,
        // 飞回刘海口反而突兀)。anchorRect 在贴刘海时=刘海矩形,故宽/中心取自它。
        let collapse: NSRect? = panel.mode == .transient
            ? NSRect(x: anchorRect.midX - anchorRect.width / 2,
                     y: panel.frame.maxY - 6, width: anchorRect.width, height: 6)
            : nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = dur
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)   // 加速收进刘海
            if let collapse { panel.animator().setFrame(collapse, display: true) }
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, gen == self.showGeneration else { return }   // 被新一次显示抢占 → 不收
            panel.orderOut(nil)
            panel.alphaValue = 1                                         // 复位;下次 present 会重设 frame/glass
            self.isHiding = false
        })
    }

    // MARK: - 就地 Pin / Unpin(只翻行为,绝不改 frame)

    /// Pin:停鼠标离开监听、变 .pinned(floating + 可激活 + 可拖动)、激活取键焦点。
    /// Unpin:变回 .transient、keep-alive 区改为面板自身、恢复鼠标离开监听。**两条路径都不动 frame**。
    func setPinned(_ pinned: Bool) {
        guard let panel else { return }
        panel.mode = pinned ? .pinned : .transient
        if pinned {
            stopMouseLeaveMonitor()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            anchorRect = panel.frame   // 脱离刘海:走廊塌缩为面板自身,离开面板即收
            startMouseLeaveMonitor()
        }
    }

    // MARK: - 几何 / 窗口

    /// 标准 frame:刘海/回退区正下方居中,顶边贴刘海底(向下展开)。高度按条目数自适应。
    private func standardFrame(below resolution: NotchGeometry.Resolution, itemCount: Int) -> NSRect {
        let anchor = resolution.rect
        let w = panelWidth
        let h = panelHeight(itemCount: itemCount)
        return NSRect(x: anchor.midX - w / 2,
                      y: anchor.minY - h,   // anchor.minY = 刘海底 = 面板顶
                      width: w, height: h)
    }

    /// 窗口 setFrame 动画**之前**调:把玻璃快照到目标内容尺寸、顶部居中锚定,并关隐式动画
    /// (CATransaction)避免玻璃自己 morph。此后放大窗口 frame,容器裁切露出玻璃;autoresize 只改
    /// 玻璃**位置**不改 bounds → 全程零 morph(根治呼出"慢 + 从右往左")。height = 目标内容高度。
    private func snapGlass(toContentHeight height: CGFloat) {
        guard let glass, let container = panel?.contentView else { return }
        let w = panelWidth
        let cb = container.bounds
        // 相对当前容器:顶边对齐(y = 容器高 - 玻璃高)、水平居中。autoresize 随后维持此锚定。
        let frame = NSRect(x: (cb.width - w) / 2, y: cb.height - height, width: w, height: height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glass.frame = frame
        CATransaction.commit()
    }

    private func ensurePanel() -> NichePanel {
        if let panel { return panel }
        // .titled(而非 borderless)是 Clipin 干净边缘的前提:borderless 窗本身是直角矩形,
        // 玻璃在内圆到 24,四角"圆角外、窗框内"的小三角会露系统阴影 = 尖角灰线。.titled 窗有
        // 系统 frame view,可被 KVC cornerRadius 圆角,与玻璃严丝合缝 → 无三角、无灰线。
        let p = NichePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight(itemCount: 12)),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],   // 自适应高度:不带 .resizable
            backing: .buffered, defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.title = ""
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { p.standardWindowButton($0)?.isHidden = true }
        p.minSize = NSSize(width: 1, height: 1)   // 允许"从刘海长出"动画起始的窄条

        // 窗面 = macOS 26 原生整窗 Liquid Glass(NSGlassEffectView,Spotlight/访达同款)。
        // 干净圆角裁切 + 锐利系统阴影 —— 根治旧 NSVisualEffectView + masksToBounds 的"边缘发糊发灰"。
        //
        // **不把玻璃直接当 contentView**:呼出是逐帧 setFrame 把窗口从刘海小条放大到整窗,玻璃若随窗口
        // resize 会触发自带液态 morph(慢 + 高光横扫,盖掉"居中向下生长")。改为:容器(透明 + clipsToBounds)
        // 作 contentView 随窗口廉价裁切;玻璃作子视图,固定宽高、顶部居中锚定(flexibleBottom/Left/Right
        // margin),动画前由 snapGlass 快照到目标尺寸 → 窗口长大时玻璃只被"露出",bounds 全程不变,无 morph。
        let glass = NSGlassEffectView()
        glass.cornerRadius = edge.panelCornerRadius   // 外壳同心圆基准(= 底栏按钮 16 + gap 8)
        glass.autoresizingMask = [.minYMargin, .minXMargin, .maxXMargin]   // 顶部居中锚定,宽高固定
        let host = NicheGlassHostingView(rootView: ContentPanelView(model: model, motion: motion, actions: actions))
        glass.contentView = host

        let container = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight(itemCount: 12)))
        container.wantsLayer = true
        container.layer?.masksToBounds = true   // 裁掉露出范围外的玻璃(生长动画的"开口"由此实现)
        glass.frame = container.bounds          // 初始铺满(稳态);呼出/relayout 前 snapGlass 会改写
        container.addSubview(glass)
        p.contentView = container
        self.glass = glass
        // .titled 窗始终有系统 frame:用 cornerRadius KVC 把 frame 圆角对齐 shell 24,否则四角
        // 露 frame 发丝弧/尖角灰线(Clipin 同款,private _cornerRadius,不手动 masksToBounds)。
        p.setValue(edge.panelCornerRadius, forKey: "cornerRadius")
        p.invalidateShadow()
        p.mode = .transient
        panel = p
        return p
    }

    // MARK: - 瞬态鼠标离开监听

    private func startMouseLeaveMonitor() {
        stopMouseLeaveMonitor()
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.evaluateLeave()
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.evaluateLeave()
            return event
        }
        mouseMonitors = [global, local].compactMap { $0 }
    }

    private func stopMouseLeaveMonitor() {
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseMonitors.removeAll()
        leaveWorkItem?.cancel()
        leaveWorkItem = nil
    }

    // MARK: - 键盘权威(本地 keyDown monitor)

    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handlePanelKey(event)
        }
    }

    private func stopKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }

    /// 列表方向键:Table 已是第一响应者 → 放行给原生 NSTableView(原生 ∓1 + 自动滚动 + 回写
    /// 选中 binding);否则(@FocusState 未生效:首现/QL 返回/pin 切换)兜底走 model.move(cols=1)
    /// 并吃掉事件 —— 消除「按键无响应」死区(Codex review:列表方向键不应依赖焦点成功)。
    private func listArrow(_ direction: GridSelection.Direction, extend: Bool, _ event: NSEvent) -> NSEvent? {
        if panel?.firstResponder is NSTableView { return event }   // 原生 Table:含 ⇧+方向键区间
        model.moveCursor(direction, extend: extend)
        return nil
    }

    /// 返回 nil 吃掉事件,返回 event 放行给响应链(交原生控件,如 Table 原生方向键导航)。
    private func handlePanelKey(_ event: NSEvent) -> NSEvent? {
        // Quick Look 活跃:键盘单一权威接管预览态。必须在 isKeyWindow 守卫之前 —— QL becomeKey 后
        // 本面板 resignKey,守卫会提前 return;且 accessory app + 自定义层级下 QL 自带 space-to-close
        // 不稳。空格/Esc → 关预览(原生 toggle,Esc 不再误关整个面板);方向键 → 移光标(经选中同步
        // 让 QL 跟随);其余键透传给 QL/响应链。本地 monitor 是 app 级,QL 为 key 时仍先于其拿到事件。
        if actions.isQuickLookActive() {
            // 方向键移光标后**同步**推 QL(onQuickLookSyncCursor):QL 是 key window 时,依赖
            // `.receive(on: RunLoop.main)` 的异步跟随会滞后到下次按键 → 预览落后一格(再按一次才切)。
            switch event.keyCode {
            case 49, 53: actions.onQuickLookClose(); return nil   // Space / Esc
            case 126: model.moveCursor(.up, extend: false); actions.onQuickLookSyncCursor(); return nil
            case 125: model.moveCursor(.down, extend: false); actions.onQuickLookSyncCursor(); return nil
            case 123: model.moveCursor(.left, extend: false); actions.onQuickLookSyncCursor(); return nil
            case 124: model.moveCursor(.right, extend: false); actions.onQuickLookSyncCursor(); return nil
            default: return event
            }
        }
        guard let panel, panel.isVisible, panel.isKeyWindow else { return event }
        // 重命名进行中:字段编辑器(NSText)是第一响应者 → 放行所有键给输入框(含空格/方向键/Esc)。
        // Esc 由 RenameTextField 的 cancelOperation 吃掉,不冒泡到这里关面板(#20)。
        if panel.firstResponder is NSText { return event }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)
        let isList = model.viewMode == .list

        switch event.keyCode {
        case 126: // ↑
            if cmd { model.currentMirror?.goUp(); model.clearSelection(); return nil }
            if isList { return listArrow(.up, extend: shift, event) }
            model.moveCursor(.up, extend: shift); return nil
        case 125: // ↓
            if cmd {
                // Finder 语义:⌘↓ = 打开所选(目录下钻,文件交系统打开)。此前只对目录生效,
                // 文件按了没反应 —— 与 Finder 不一致的无声死区。
                if let item = model.cursorItem {
                    if item.isDirectory { model.currentMirror?.enter(item.url); model.clearSelection() }
                    else { actions.onOpen(item) }
                }
                return nil
            }
            if isList { return listArrow(.down, extend: shift, event) }
            model.moveCursor(.down, extend: shift); return nil
        case 123: // ←
            if isList { return event }   // 列表无横向语义,交 Table(默认无操作)
            model.moveCursor(.left, extend: shift); return nil
        case 124: // →
            if isList { return event }
            model.moveCursor(.right, extend: shift); return nil
        case 49: // 空格 → Quick Look(从光标项起,可在全部条目间翻页)
            if let idx = model.cursorIndex {
                actions.onQuickLook(model.sortedItems.map(\.url), idx)
            }
            return nil
        case 36, 76: // Return / Enter → 打开 / 下钻;⇧Return → 就地重命名
            // Return=打开是 spec §4.7 的有意取舍(非 Finder 的 Return=重命名),但重命名必须留
            // 键盘路径(否则只剩右键菜单一条路,Finder 用户两头落空)。⇧Return:离 Finder 习惯
            // 最近的空位(重命名态本身的 Return/Esc 由字段编辑器在 monitor 之前接管,不冲突)。
            if let item = model.cursorItem {
                if shift {
                    model.selectSingle(item.id)
                    model.beginRename(item.url)
                } else if item.isDirectory {
                    model.currentMirror?.enter(item.url); model.clearSelection()
                } else {
                    actions.onOpen(item)
                }
            }
            return nil
        case 53: // Esc → 收回(未 pin)/ 隐藏常驻
            actions.onClose(); return nil
        case 51, 117: // Delete / Forward Delete
            if cmd { actions.onTrash(model.selectionURLs); return nil }
            return event
        default:
            break
        }

        // ⌘ 字母快捷键(spec §4.5/§4.7)。
        if cmd, let ch = event.charactersIgnoringModifiers?.lowercased() {
            // ⌘1…9 切 tab(访达/浏览器惯例):多文件夹是核心体验,切 tab 不能只有鼠标一条路。
            if let n = Int(ch), (1...9).contains(n) {
                model.selectTab(n - 1)   // 越界由 selectTab 守卫,no-op
                return nil
            }
            switch ch {
            case "a": model.selectAll(); return nil
            case "c" where option: actions.onCopyPath(model.selectionURLs); return nil
            case "c": actions.onCopy(model.selectionURLs); return nil
            case "x": actions.onCut(model.selectionURLs); return nil
            case "v": actions.onPaste(); return nil
            case "z": actions.onUndo(); return nil
            case "w": actions.onClose(); return nil
            case ",": actions.onOpenSettings(); return nil
            default: break
            }
        }
        return event
    }

    /// 抑制源(QL/菜单/重命名/拖拽)解除后由 AutoHideCoordinator 调:重新评估鼠标当前位置,
    /// 而非盲目兑现抑制期间记下的 pendingHide —— 鼠标已回走廊内就不收(关 QL 不连带收面板)。
    func reevaluateAutoHide() { evaluateLeave() }

    /// 鼠标在"面板 ∪ anchorRect"走廊内 → 取消待收;离开 → 起 0.35s 延时收回(被抑制由宿主拦)。
    private func evaluateLeave() {
        guard let panel, panel.mode == .transient, panel.isVisible else { return }
        let region = panel.frame.union(anchorRect).insetBy(dx: -8, dy: -8)
        if region.contains(NSEvent.mouseLocation) {
            leaveWorkItem?.cancel()
            leaveWorkItem = nil
        } else if leaveWorkItem == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.leaveWorkItem = nil
                self?.onMouseExitedTransient?()
            }
            leaveWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }
}

/// 受 WindowMode 状态机驱动的 NSPanel:styleMask(.nonactivatingPanel)、层级、可拖动随模式变化。
/// 瞬态与常驻共用此**一个**窗口(见 PanelController)。
final class NichePanel: NSPanel {
    var mode: WindowMode = .transient {
        didSet { applyMode() }
    }

    override var canBecomeKey: Bool { mode.canBecomeKey }
    override var canBecomeMain: Bool { mode.canBecomeMain }

    private func applyMode() {
        // styleMask 恒定带 .nonactivatingPanel(init 设),不随 mode 切 —— 避免反复改 styleMask
        // 抖掉 firstResponder/键盘焦点。两模式都靠 canBecomeKey=true 成 key 收键盘;常驻另调
        // NSApp.activate 激活 app。nonactivating 只挡 main(附件 app 不需要 main),不挡 key。
        level = mode.level
        collectionBehavior = mode.collectionBehavior
        isMovableByWindowBackground = (mode == .pinned)   // 常驻:拖背景移动(detach);瞬态:不可拖
        hidesOnDeactivate = false   // 隐藏策略统一交给 AutoHideCoordinator,不靠系统 deactivate
    }
}

/// NSGlassEffectView 内的 SwiftUI 宿主:窗面玻璃/圆角/裁切/阴影全交给 AppKit(NSGlassEffectView +
/// 窗口),内容层只需归零 safe area、清空图层、**不 mask** —— 在内容层再画边/裁切会和玻璃叠出
/// 发丝线(借鉴 Clipin ClipinPanelHostingView)。无 borderless 标题栏,故 safe area 本就该为 0。
final class NicheGlassHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
        layer?.borderColor = nil
        layer?.masksToBounds = false
    }
}
