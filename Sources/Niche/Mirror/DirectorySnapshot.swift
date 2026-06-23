import Foundation

/// 某目录某一时刻的内容快照。
///
/// FSEvents 不是逐文件强一致流(会 coalesce / drop,见 spec §4.1.1),所以镜像同步**靠快照
/// 比对而非增量信任**:每次拿到事件就重新列目录得到新 `DirectorySnapshot`,与旧快照 diff,
/// UI 按 diff 增量更新。
struct DirectorySnapshot: Equatable {
    /// key = 文件 URL(标准化),value = 该项。
    let items: [URL: FileItem]

    init(items: [FileItem]) {
        self.items = Dictionary(items.map { ($0.url.standardizedFileURL, $0) }) { first, _ in first }
    }

    var fileItems: [FileItem] { Array(items.values) }

    /// 列目录得到快照。`showHidden=false` 时跳过隐藏项(spec §4.4 隐藏文件开关)。
    /// 列目录本身就是一次访问 —— 受保护目录会触发 TCC(由调用方绑定用户动作,见 §4.1.1)。
    ///
    /// **软链目录**:`contentsOfDirectory(at:)`(URL 版)按 isDirectoryKey 预判,指向目录的软链
    /// 被当非目录直接拒(报 NSCocoaError 256,**非权限错**;`atPath:` 版才跟随)。故 directory 经由
    /// 软链时,用解析后的真实目录列举,再把子项 URL **重建回 directory(软链路径)体系** —— 保持
    /// 下钻/面包屑坐标一致(containsUnresolved 不越界),真实属性由 FileItem.load 跟随中段软链读取。
    /// 普通目录解析后与 directory 相等,沿用原 URL(保留 contentsOfDirectory 的属性预取)。
    static func capture(directory: URL, showHidden: Bool) throws -> DirectorySnapshot {
        let options: FileManager.DirectoryEnumerationOptions =
            showHidden ? [] : [.skipsHiddenFiles]
        let listDir = directory.resolvingSymlinksInPath()
        let urls = try FileManager.default.contentsOfDirectory(
            at: listDir,
            includingPropertiesForKeys: Array(FileItem.resourceKeys),
            options: options
        )
        let needsRebase = listDir != directory
        let items = urls.map { child -> FileItem in
            FileItem.load(url: needsRebase ? directory.appendingPathComponent(child.lastPathComponent) : child)
        }
        return DirectorySnapshot(items: items)
    }
}

/// 两快照之间的差异。重命名表现为 removed(旧名)+ added(新名);内容/属性变化为 changed。
struct SnapshotDiff: Equatable {
    var added: [FileItem]
    var removed: [FileItem]
    var changed: [FileItem]

    var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }

    static func between(old: DirectorySnapshot, new: DirectorySnapshot) -> SnapshotDiff {
        var added: [FileItem] = []
        var changed: [FileItem] = []
        var removed: [FileItem] = []

        for (url, newItem) in new.items {
            if let oldItem = old.items[url] {
                // 大小/修改时间/dataless/标签任一变化即视为 changed。
                if oldItem != newItem { changed.append(newItem) }
            } else {
                added.append(newItem)
            }
        }
        for (url, oldItem) in old.items where new.items[url] == nil {
            removed.append(oldItem)
        }
        return SnapshotDiff(added: added, removed: removed, changed: changed)
    }
}
