import AppKit

/// 拖拽落点的操作语义(spec §4.5 拖拽红线 + 注②)。
///
/// 关键:`NSDraggingDestination` 只**协商**角标,真正搬文件要 Niche 自己执行(注②)。
/// 本类是纯决策:给定"是否同卷"与修饰键,算出 copy 还是 move,供 UI 显示角标 + 给
/// FileOperations 执行。把"卷比较"与"决策"拆开,决策部分可纯单测(跨卷文件难在 CI 造)。
enum DragOperation: Equatable {
    case copy
    case move
}

enum DragSemantics {
    /// 决策规则(与 Finder 一致):
    /// - ⌥(option)强制 copy,⌘(command)强制 move —— 修饰键优先级最高。
    /// - 无修饰:同卷 move、跨卷 copy。
    /// - `sameVolume == nil`(卷未知):保守按 copy(不静默移动用户文件,spec 红线)。
    ///
    /// ⌥ 与 ⌘ 同按时以 ⌥(copy)为准 —— option 的复制语义更安全(不动原件)。
    static func resolve(sameVolume: Bool?, modifiers: NSEvent.ModifierFlags) -> DragOperation {
        if modifiers.contains(.option) { return .copy }
        if modifiers.contains(.command) { return .move }
        guard let sameVolume else { return .copy }
        return sameVolume ? .move : .copy
    }

    /// 判定两个 URL 是否在同一卷上。任一无法取到卷标识时返回 nil(未知)。
    static func isSameVolume(_ lhs: URL, _ rhs: URL) -> Bool? {
        guard let l = volumeIdentifierObject(of: lhs),
              let r = volumeIdentifierObject(of: rhs)
        else { return nil }
        return l.isEqual(r)
    }

    /// `.volumeIdentifierKey` 返回的是不透明 token(NSCopying & NSObjectProtocol),
    /// 没有 `URLResourceValues` 的强类型访问器,要从 `allValues` 里取并用 `isEqual` 比较。
    private static func volumeIdentifierObject(of url: URL) -> NSObjectProtocol? {
        let values = try? url.resourceValues(forKeys: [.volumeIdentifierKey])
        return values?.allValues[.volumeIdentifierKey] as? NSObjectProtocol
    }
}
