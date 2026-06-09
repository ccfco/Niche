# Niche

刘海原生的 macOS 文件快捷访问器。从 MacBook 刘海(无刘海回退屏幕顶部)滑出悬浮窗,镜像常用文件夹,随手取用 / 拖拽 / 预览,用完即走。开源 · SwiftUI · 不沙盒自分发。

设计文档:`docs/superpowers/specs/2026-06-05-niche-design.md`(权威设计稿)。实现计划:`docs/superpowers/plans/2026-06-05-niche-implementation.md`。

## 构建(读代码得不到)

- 工程由 `project.yml` 经 **XcodeGen 生成**,`Niche.xcodeproj` 不进 git。改配置/加依赖改 `project.yml`,改完先 `xcodegen generate` 再 `xcodebuild`。新增/删源文件后必须重跑 `xcodegen generate`(按目录 glob)。
- 命令:`xcodegen generate && xcodebuild -scheme Niche -destination 'platform=macOS,arch=arm64' build`(测试同 `test`)。
- **Swift 语言模式 5.0 + `SWIFT_STRICT_CONCURRENCY=minimal`**(降低大型 AppKit 从 0 构建期并发噪音);`@MainActor` 仍按需显式标注。`deinit` 是 nonisolated,**不能调 `@MainActor` 方法**(observer 清理放 `close()` 等显式路径,不放 deinit)。
- 命名避坑:自定义类型勿与系统同名 —— `Edge`(撞 SwiftUI)、`SortOrder`(撞 Foundation)已分别命名 `EdgeMetrics`/`FileSortOrder`。

## Obsidian 知识库

`[project:: niche]`

- **文档根目录**:`Projects/personal/niche/`
- **方案**:`方案/`
- **架构图**:`架构图/`
- **踩坑**:`踩坑/`

## 架构方向

- **SwiftUI 为主**;MVP 数据量小,配置/设置用纯 Swift(UserDefaults / 轻量本地存储),暂不引 Rust。
- **触发动画引 DynamicNotchKit**(开源 SwiftUI 库)——Niche **不继承** Clipin 的"零 SPM 依赖"红线。
- **menu bar accessory**(`LSUIElement=true`),不进 Dock。
- **只发 Apple Silicon / arm64**(沿用 Clipin)。

## 关键决策(读代码得不到、违反会出问题的不变量)

### 定位
- **只做「文件夹镜像快速访问」一件事,禁止做成暂存盘**(从各处拖文件进来暂放的 B 模型)——那是 NotchNook/Yoink 赛道,会模糊定位。
- **原生正确性 > 功能数量**:Finder 能做的(显示隐藏文件、完整文件操作语义)在自己范围内不阉割——是底线不是卖点。

### 文件操作
- **文件操作全部走系统 API**(FileManager/NSWorkspace/Drag&Drop/QuickLook/NSSharingService),禁止自研文件引擎。
- **删除必须走废纸篓**(NSWorkspace.recycle / FileManager.trashItem)可恢复,禁止真删用户文件。
- **拖拽必须按 Finder 语义**:同卷移动/跨卷复制,⌥强制复制、⌘强制移动,光标显示角标;写操作前校验目标可写。
- **拖出用真实 file URL,不用 NSFilePromiseProvider**(promise 是给"拖出时才生成内容"的场景)。
- **右键菜单用 NSMenu 自拼**覆盖常用项(每项调系统 API);Finder 右键菜单本体与 Get Info 是系统硬边界搬不过来,不做。

### 权限与沙盒
- **不沙盒**(换取隐藏文件 + 任意路径访问),GitHub Release 自分发,不上 MAS。
- **不沙盒 → 不用 security-scoped bookmark**(那是沙盒专属机制);持久化用普通 bookmark/存路径。
- **访问受保护目录**(Desktop/Documents/Downloads/iCloud)走 TCC 授权,**权限必须按需触发**(访问失败时),禁止启动时主动弹——沿用 Clipin。
- **arm(列目录=触发 TCC)只在用户动作路径**:`DirectoryMirror.arm()` 不能在启动/后台/`rebuildMirrors` 里调(那会启动期弹权限)。`rebuildMirrors` 重建后由 `NicheController` **仅在面板可见时**重新 arm 当前 mirror;否则等 `present()`/`selectTab()` 用户动作触发。

### 窗口与触发
- **触发位置**:刘海优先 → 顶/左/右/菜单栏可选 → 全局快捷键兜底;**多屏在鼠标活跃屏触发,无刘海回退顶部中央**。
- **Pin 是两种窗口模式的切换**(瞬态 NSPanel ↔ 常驻可拖动 always-on-top 浮窗),**必须从一开始做成可切换状态机**,不能先写死 launcher 再改。
- **面板键盘走 `PanelController` 的 AppKit 本地 `keyDown` monitor 单一权威**,禁止在 SwiftUI 视图加 `.onKeyPress`/`.focusable`(随焦点漂移失效,与 monitor 抢键)。重命名态(`firstResponder is NSText`)**必须整体放行**给字段编辑器,否则 monitor 会吞掉输入框的 Esc/空格/方向键(Esc 关面板而非取消重命名);列表方向键交原生 `NSTableView`,但 `listArrow` 须兜底 `model.moveCursor`(@FocusState 首现/QL 返回时未生效)。**Quick Look 活跃时空格/Esc 关预览、方向键移光标也由此 monitor 接管**(在 `isKeyWindow` 守卫之前判 `isQuickLookActive`):accessory app + 自定义层级下 QLPreviewPanel 自带 space-to-close 不稳,别依赖它;否则空格不能 toggle 关、Esc 误关整个面板。

### Chrome / UI
- **间距/圆角由单一旋钮派生**,禁止组件硬编码 padding/cornerRadius;**禁卡片套卡片**,底栏各按钮自承材质——沿用 Clipin chrome 纪律,达成 Liquid Glass 原生质感。
- **缩略图禁止在 row 渲染路径同步解码**,必须后台 ImageIO 解码 + 缓存上限。
- **列表(原生 `Table`)与图标(`LazyVGrid`)两模式行为必须等价**:选中(`Set<id>`+光标+锚点单一真相)/ 排序(`FileSortOrder` 单一真相,表头与底栏菜单共写)/ 右键(同款 `RightClickCatcher`→`ContextMenuBuilder`)/ 拖入拖出 / 键盘——给一模式加能力时另一模式同步,缺一即违反「原生正确性 > 功能数量」。

## 设计原则(同 Clipin)

- **简单·复用优先**:不过度工程化;能用系统能力 / 成熟库就不自造,自研必须说明为什么现成方案不适合。
- **找根因·不打补丁·不兜底**:不写 fallback / default / catch-all 静默消化异常,让问题正面暴露。
- **方案先行**:功能 / bug 修复前先在对话里把方案(涉及哪些文件、改什么、为什么)定清楚,确认后再实现。
- **Git**:原子提交,前缀 `feat:`/`fix:`/`docs:`/`refactor:`,提交信息全部用中文,三段式(根因背景 / 踩坑记录 / 改动范围),禁止 force push。

## 文档约定

- CLAUDE.md 只收「读代码得不到、违反会出问题」的不变量,每条尽量一行讲清"必须怎样 + 为什么";像素级 / 实现级 WHY 进代码注释,调试复盘进 commit message。
- 写入门禁:① 读代码能发现的不写;② 违反不会出问题的不写;③ 单条尽量一行、含"必须/不能/禁止"。
- 超 ~250 行做一次回收:合并碎片、把已腐烂的像素条目下沉代码注释。
