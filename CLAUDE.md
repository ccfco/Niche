# Niche

刘海原生的 macOS 文件快捷访问器。从 MacBook 刘海(无刘海回退屏幕顶部)滑出悬浮窗,镜像常用文件夹,随手取用 / 拖拽 / 预览,用完即走。开源 · SwiftUI · 不沙盒自分发。

设计文档:`docs/superpowers/specs/2026-06-05-niche-design.md`(权威设计稿)。实现计划:`docs/superpowers/plans/2026-06-05-niche-implementation.md`。

## 构建(读代码得不到)

- 工程由 `project.yml` 经 **XcodeGen 生成**,`Niche.xcodeproj` 不进 git。改配置/加依赖改 `project.yml`,改完先 `xcodegen generate` 再 `xcodebuild`。新增/删源文件后必须重跑 `xcodegen generate`(按目录 glob)。
- 命令:`xcodegen generate && xcodebuild -scheme Niche -destination 'platform=macOS,arch=arm64' build`(测试同 `test`)。
- **Swift 语言模式 5.0 + `SWIFT_STRICT_CONCURRENCY=minimal`**(降低大型 AppKit 从 0 构建期并发噪音);`@MainActor` 仍按需显式标注。`deinit` 是 nonisolated,**不能调 `@MainActor` 方法**(observer 清理放 `close()` 等显式路径,不放 deinit)。
- 命名避坑:自定义类型勿与系统同名 —— `Edge`(撞 SwiftUI)、`SortOrder`(撞 Foundation)已分别命名 `EdgeMetrics`/`FileSortOrder`。
- **改完代码主动装机并打开**:构建通过后直接跑 `./scripts/auto-install.sh`——源码比已装 app 新就 Release 构建、`killall` 旧实例、装进 `/Applications`、**自动 `open` 到前台**(源码无变化则只 `open` 已装版本)。用户要的是"改完啥都不点、最新版已经开着",**已明确授权 Niche 这样自动启动**(global「不擅自启动 GUI」红线对本项目 deploy 这一动作放行,仅限 Niche)。不擅自建 Stop hook——用户要 hook 会自己说 / 用 `/hooks`。

## Obsidian 知识库

`[project:: niche]`

- **文档根目录**:`Projects/personal/niche/`
- **方案**:`方案/`
- **架构图**:`架构图/`
- **踩坑**:`踩坑/`

## 架构方向

- **SwiftUI 为主**;MVP 数据量小,配置/设置用纯 Swift(UserDefaults / 轻量本地存储),暂不引 Rust。
- **触发动画自研 PanelController**(DynamicNotchKit 已弃用,170a1cd:黑底吞玻璃 + 两套窗口系统);依赖政策不变:Niche **不继承** Clipin 的"零 SPM 依赖"红线,需要时可引库。
- **menu bar accessory**(`LSUIElement=true`),不进 Dock;**AppKit 启动,无 SwiftUI App scene**:设置窗口自管(Settings scene 在 accessory app 无公开 API 可编程打开,`showSettingsWindow:` 在 macOS 14+ 被封禁);主菜单由 AppDelegate 显式重建,**Edit 菜单不能删**——重命名输入框的 ⌘C/V/X/A 靠它路由,删了静默失效。
- **只发 Apple Silicon / arm64**(沿用 Clipin)。

## 关键决策(读代码得不到、违反会出问题的不变量)

### 定位
- **只做「文件夹镜像快速访问」一件事,禁止做成暂存盘**(从各处拖文件进来暂放的 B 模型)——那是 NotchNook/Yoink 赛道,会模糊定位。
- **原生正确性 > 功能数量**:Finder 能做的(显示隐藏文件、完整文件操作语义)在自己范围内不阉割——是底线不是卖点。
- **心智模型 = 书签栏 + 地址栏**:tab 是书签(稳定、用户钦定,肌肉记忆是核心资产),「前往」是地址栏(长尾出口),钉住是升级通道;添加动作主入口在面板现场(「+」菜单),设置页是管理界面。禁止引入会漂移 tab 稳定性的浏览态(如 MRU 自动 tab、记住上次浏览位置当首页)。**但 tab 内「下钻深度」可 per-binding 持久化恢复**(书签身份/绑定根不变,只复刻浏览深度强化肌肉记忆;禁的是 tab *指向* 漂移成别处,而非深度)——持久化走旁路 UserDefaults(`niche.lastPath.<id>`),**不入 BindingStore**:后者是 `@Published`,NicheController 订阅其变更会触发 `rebuildMirrors` 重建全部 mirror(丢状态 + 重 arm 可能弹 TCC),下钻高频必须挂不广播的旁路存储。

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

### 本地化(String Catalog,中文=源语言)
- **`Localizable.xcstrings` 中文作为 key 本身**(`project.yml` `developmentLanguage: zh-Hans`),English 是附加译文;日志(`Log.*`)/注释/commit message 不本地化。
- **一律显式 `String(localized:)`,不依赖字面量隐式转 `LocalizedStringKey`**——除非目标参数类型就是 `LocalizedStringKey`(如 `Text("...")`/`Toggle("...")`/`TableColumn("...")` 等标准 SwiftUI API 的字面量参数),这类literal保留原样。三元表达式只要有一支是非字面量 `String`,两支的类型会被统一推成 `String`,连字面量那支也会跟着失去隐式查表资格,必须两支都显式包。
- **`TagPalette.standard` 的 `name` 字段不本地化**:它既是右键菜单展示文本,也是 `ContextMenuBuilder.toggleTag` 写入 `com.apple.metadata:_kMDItemUserTags` 的字面量标签名,翻译成英文会让本 App 写入的标签名与访达标准中文标签名不一致、标签互认失效——这是功能标识符,不是纯展示字符串。
- **插值字符串会生成占位符 key**(`String(localized: "跳转到 \(name)")` → key `"跳转到 %@"`,`Int` 插值是 `%lld`),手写 `.xcstrings` 条目时占位符要按参数真实类型对应,不能全按 `%@` 处理。

### Onboarding(首次使用引导)
- **`OnboardingState.hasSeen` 走旁路 `UserDefaults`,不进 `BindingStore`**(同下钻深度持久化的理由:不需要 `@Published` 广播触发 `rebuildMirrors`)。
- **`OnboardingWindowController` 建窗禁止用 `contentRect: .zero`**:`NSHostingView` 不会把 0×0 窗口自动撑到 SwiftUI 内容的实际尺寸,窗口会以 0×0 呈现(视觉上等同没弹出),必须在设好 `contentView` 后显式 `window.setContentSize(host.fittingSize)`。此类问题编译与 XCTest 都测不出,只能真机装跑验证。
- **`SettingsWindowController` 的分区选中态(`selection`)归窗口控制器持有,不是 `SettingsView` 的 `@State`**:窗口只建一次、View 实例不会因外部再调用而重建,`@State` 初值只在首次生效——`show(section:)` 要在窗口已存在后跳转指定分区,必须把状态提到跨 `show()` 调用存活的控制器层,`SettingsView` 改收 `@Binding`。

### 自动更新(Sparkle，双层架构同 Clipin)
- **检测与安装必须分两层**：`UpdateChecker`（轮询 `appcast.xml`）只做检测、驱动菜单栏小红点 + 设置页；Sparkle 只做下载/EdDSA 验签/替换/重启。`AppDelegate.setupSparkle()` 把「触发安装」闭包注入 `UpdateChecker.installHandler`，并置 Sparkle `automaticallyChecksForUpdates=false`，禁止两层都去轮询。
- **`UpdateChecker` 检测源必须是 `appcast.xml`（`raw.githubusercontent.com`），禁止改回 `api.github.com`**：后者未认证限额 60 次/小时且按 IP 算，共享出口 IP 极易被其它流量打满，一旦打满检测层（含菜单栏红点、设置页、Sparkle 安装入口）全部瘫痪——实测踩过。appcast.xml 是静态 CDN 资源不受此限，且和 Sparkle 装的是同一份数据，不会有双源不一致。解析用 `AppcastParser`（`XMLParser` 委托，不开 `shouldProcessNamespaces`）：`didEndElement` 必须清空 `currentElement`，否则标签间的换行缩进会被 `foundCharacters` 当作仍在当前标签内、误追加进版本号（实测踩过：`"0.1.3\n            "`)。
- **发版必须走 `scripts/release.sh`，且 appcast 必须在 release 资产上传并验证可下载后才 push**：先 push appcast 会让已装客户端拿到指向不存在下载 URL 的 appcast（永久 404）。脚本顺序固定：前置检查(工作树干净)→版本号写回并单独 commit→构建→ad-hoc 签名→generate_appcast EdDSA 签名→tag→push 代码→建 release 传 zip→`gh api` 查资产 state/size 就绪(非 curl HEAD)→curl 兜底验证可达→最后才 push appcast。
- **Sparkle EdDSA 私钥与 Clipin 复用同一对（本机 Keychain）、公钥在 Info.plist `SUPublicEDKey`**：禁止 `generate_keys` 重新生成——换私钥会让所有已装客户端验签失败、更新链彻底断。签名弹的是本机 Keychain 密码（点「始终允许」免重复弹），终端用户验签只用公钥、永不需要密码。

## 设计原则(同 Clipin)

- **简单·复用优先**:不过度工程化;能用系统能力 / 成熟库就不自造,自研必须说明为什么现成方案不适合。
- **找根因·不打补丁·不兜底**:不写 fallback / default / catch-all 静默消化异常,让问题正面暴露。
- **方案先行**:功能 / bug 修复前先在对话里把方案(涉及哪些文件、改什么、为什么)定清楚,确认后再实现。
- **Git**:原子提交,前缀 `feat:`/`fix:`/`docs:`/`refactor:`,提交信息全部用中文,三段式(根因背景 / 踩坑记录 / 改动范围),禁止 force push。

## 文档约定

- CLAUDE.md 只收「读代码得不到、违反会出问题」的不变量,每条尽量一行讲清"必须怎样 + 为什么";像素级 / 实现级 WHY 进代码注释,调试复盘进 commit message。
- 写入门禁:① 读代码能发现的不写;② 违反不会出问题的不写;③ 单条尽量一行、含"必须/不能/禁止"。
- 超 ~250 行做一次回收:合并碎片、把已腐烂的像素条目下沉代码注释。
