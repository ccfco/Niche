# Niche

> 刘海原生的 macOS 文件快捷访问器

Niche 从 MacBook 刘海(无刘海则屏幕顶部)滑出一个悬浮窗,把你常用的几个文件夹「镜像」出来——随手取用、拖拽、预览,用完即走,像系统自带的一样。

## 为什么是 Niche

- **真·原生** — macOS 26 Liquid Glass 质感,长得就像系统自带工具。
- **极简** — 只做「常用文件夹快速访问」一件事,不堆功能。
- **不阉割** — 显示隐藏文件、完整文件操作(与 Finder 行为一致),该有的基础能力都在。
- **刘海原生** — 从刘海滑出,带苹果味的展开动画;无刘海自动回退屏幕顶部。
- **开源 · 隐私** — 本地优先,不沙盒自分发,代码开放。

## 功能

- **文件夹镜像** — 绑定多个真实文件夹,顶部 tab 切换;FSEvents 实时同步磁盘真实状态。
- **触发** — 刘海热区 hover(带防误触延迟)/ 拖着文件靠近自动迎上 / 菜单栏图标 / 全局快捷键(默认 ⌥⌘Space)。
- **浏览** — 网格 + 后台缩略图解码;名称/日期/大小/类型排序;隐藏文件开关;Quick Look(Space)。
- **键盘导航** — ↑↓←→ 选择 / Space 预览 / Return 打开 / ⌘↓ 进子目录 / ⌘↑ 回上级。
- **文件操作** — 打开 / 在 Finder 显示 / 重命名 / 复制移动 / 剪切粘贴(⌘X/C/V)/ 复制路径(⌥⌘C)/ 新建文件夹 / 压缩 / Finder 标签 / 分享 / 删除到废纸篓;⌘Z 撤销。全部走系统 API。
- **拖拽** — 拖入按 Finder 语义(同卷移动 / 跨卷复制,⌥强制复制、⌘强制移动)、同名冲突提示;拖出用真实 file URL。
- **窗口** — Pin 切换瞬态面板 ↔ 常驻 always-on-top 浮窗,可拖离刘海(detach),记忆尺寸与位置。
- **iCloud** — 占位(dataless)文件不主动下载,预览时按需下载;状态走 NSMetadataQuery。
- **无障碍** — 尊重「减弱动态效果」(降级淡入)与「降低透明度 / 增强对比度」(材质降级为不透明纯色 + 实色描边)。

## 设计文档

完整设计稿:[`docs/superpowers/specs/2026-06-05-niche-design.md`](docs/superpowers/specs/2026-06-05-niche-design.md)(在 Obsidian 知识库)。

## 构建

```sh
# 需要 Xcode 26+ 与 XcodeGen(brew install xcodegen)
xcodegen generate
xcodebuild -scheme Niche -destination 'platform=macOS,arch=arm64' build
# 运行单测
xcodebuild -scheme Niche -destination 'platform=macOS,arch=arm64' test
```

`Niche.xcodeproj` 由 `project.yml` 经 XcodeGen 生成,不进版本库;改工程配置改 `project.yml`。

## 要求

- macOS 26+
- Apple Silicon(arm64)
- 不沙盒,GitHub Release 自分发(非 Mac App Store)

## 许可

[MIT](LICENSE)
