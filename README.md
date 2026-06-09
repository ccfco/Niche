<div align="center">

# Niche

**刘海原生的 macOS 文件快捷访问器**

*从屏幕的那个凹槽里，滑出你最常用的文件夹。用完即走。*

[![Platform](https://img.shields.io/badge/macOS-26+-black?logo=apple&logoColor=white)](#要求)
[![Arch](https://img.shields.io/badge/Apple_Silicon-arm64-0071e3)](#要求)
[![Swift](https://img.shields.io/badge/SwiftUI-Liquid_Glass-FA7343?logo=swift&logoColor=white)](#技术取舍)
[![License](https://img.shields.io/badge/License-MIT-22863a)](LICENSE)
[![Status](https://img.shields.io/badge/状态-开发中_·_MVP-yellow)](#项目状态)

</div>

---

Niche 从 MacBook 的刘海（无刘海则屏幕顶部）滑出一个悬浮窗，把你绑定的几个常用文件夹**镜像**出来——随手取用、拖拽、预览，鼠标一移开就收回。它长得就像系统自带的工具，因为它把每一件能交给系统的事都交给了系统。

> **Niche** /niːʃ/ — 与 *notch*（刘海）同源的意象：凹槽、专属凹空间。刘海本质就是屏幕顶部的一个 niche，而它装的，是你常用文件夹的专属小天地。

<!-- 演示 GIF 占位:录一段「刘海滑出 → 切 tab → Space 预览 → 拖出文件 → 移开即收」放这里最能打 -->

## 为什么是 Niche

刘海赛道（NotchNook / NotchDrop / BoringNotch …）清一色在做同一件事：**临时暂存 shelf + 媒体控制**。从各处拖文件进来暂放，再拖出去。

Niche 偏不做那个。它做的是另一件没人做的事——

| | 暂存盘（NotchNook 等） | **Niche** |
|---|---|---|
| 数据模型 | 把文件拷进来归我管的**快照** | 指向磁盘真实文件的**镜像入口** |
| 你看到的 | 你刚拖进去的那几个 | 文件夹此刻**磁盘上的真实状态**（FSEvents 实时同步） |
| 生命周期 | 自成一套，与原文件脱钩 | 文件被外部改 / 删 / 移，窗口立即跟着变 |
| 定位 | 中转站 | **常用文件夹的快速入口** |

一句话：**别人做"临时把东西放哪儿"，Niche 做"常用的东西在哪儿，一秒够到"。**

## 三条原则（贯穿每一个取舍）

1. **原生正确性 > 功能数量** — 「Finder 能做的，我们在自己范围内不阉割」。显示隐藏文件、完整文件操作语义都属于此：不是卖点，是底线。
2. **极简，守住主线** — 只做「文件夹镜像快速访问」一件事。暂存盘、媒体控制、付费堆料，一律不做。
3. **调用系统服务，不自研引擎** — 文件操作 / 预览 / 压缩 / 分享全部走系统框架（FileManager · NSWorkspace · Drag & Drop · QuickLook · NSSharingService）。不重新发明，只把系统能力包成顺手的入口。

## 功能

- **文件夹镜像** — 绑定多个真实文件夹，顶部 tab 切换；FSEvents 实时同步磁盘真实状态。
- **两种触发，刘海优先** — 刘海热区 hover（带防误触延迟）/ 拖着文件靠近时自动迎上 / 菜单栏图标 / 全局快捷键（默认 ⌥⌘Space）。多屏在鼠标活跃屏触发，无刘海回退屏幕顶部中央。
- **列表 / 图标双模式** — 列表用原生 `Table`（迷你访达），图标用网格 + 后台缩略图解码。两模式在选中、排序、右键、拖拽、键盘上**行为完全等价**。
- **全键盘导航** — ↑↓←→ 选择 · `Space` 预览（QuickLook，可翻页，再按 `Space` / `Esc` 收回）· `Return` 打开 · `⌘↓` 进子目录 · `⌘↑` 回上级 · `⌘A` 全选 · `⇧` 区间选。
- **完整文件操作（全走系统 API）** — 打开 / 用…打开 / 在 Finder 显示 / 重命名 / 复制移动 / 剪切粘贴 / 复制路径（⌥⌘C）/ 新建文件夹 / 压缩 / Finder 标签 / 分享 / 删除到废纸篓（可恢复，绝不真删）/ `⌘Z` 撤销。
- **Finder 语义拖拽** — 拖入按 Finder 规则（同卷移动、跨卷复制，⌥强制复制、⌘强制移动），实时 copy/move 角标 + 同名冲突提示；拖出用真实 file URL。
- **窗口状态机** — `Pin` 在瞬态面板 ↔ 常驻 always-on-top 浮窗之间切换，可拖离刘海，记忆尺寸与位置。面板高度随内容自适应。
- **iCloud 占位文件** — dataless 文件不主动下载，预览 / 打开时按需下载并显进度；状态走 NSMetadataQuery，不靠 FSEvents 误判。
- **无障碍降级** — 尊重「减弱动态效果」（降为淡入）与「降低透明度 / 增强对比度」（材质降级为不透明纯色 + 实色描边）。

## 技术取舍

- **SwiftUI 为主 + AppKit 桥接** — 触发动画引 [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit)；QuickLook / 自拼右键 NSMenu / 拖拽 / 键盘权威这些 SwiftUI 力有不逮处下沉到 AppKit。
- **menu bar accessory**（`LSUIElement`），不进 Dock。
- **不沙盒** — 换取显示隐藏文件 + 任意路径访问；受保护目录（Desktop / Documents / Downloads / iCloud）走 TCC 授权，**权限按需触发**，绝不在启动时主动弹窗。
- **不用 security-scoped bookmark** — 那是沙盒专属机制；不沙盒、有完整磁盘访问，无需它。
- **只发 Apple Silicon / arm64**，GitHub Release 自分发，不上 Mac App Store。

## 构建

```sh
# 需要 Xcode 26+ 与 XcodeGen(brew install xcodegen)
xcodegen generate
xcodebuild -scheme Niche -destination 'platform=macOS,arch=arm64' build

# 运行单测
xcodebuild -scheme Niche -destination 'platform=macOS,arch=arm64' test
```

`Niche.xcodeproj` 由 `project.yml` 经 XcodeGen 生成，**不进版本库**；改工程配置 / 加依赖改 `project.yml`，新增或删源文件后重跑 `xcodegen generate`。

## 要求

- macOS 26+（Liquid Glass）
- Apple Silicon（arm64）
- 不沙盒，GitHub Release 自分发（非 Mac App Store）

## 项目状态

**开发中（MVP / P0 核心闭环）** — 设计先行、定稿后再动手，核心交互正在打磨，暂未发布 Release。欢迎读代码、提 issue、讨论设计。

## 许可

[MIT](LICENSE) · © 2026 Niche contributors

<div align="center"><sub>用完即走，像系统自带的一样。</sub></div>
