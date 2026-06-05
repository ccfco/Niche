import Foundation

/// 网格键盘导航的选择模型(spec §4.7:↑↓ 选择、⌘↓ 进子目录、⌘↑ 回上级)。
///
/// 纯逻辑:给定条目总数、列数与当前选中下标,算出方向键移动后的新下标。边界 clamp,
/// 空集合不崩。子目录进入/返回是数据源动作(不在此),这里只管同层网格的焦点移动。
struct GridSelection: Equatable {
    /// 当前选中下标;nil = 无选中。
    var index: Int?

    enum Direction {
        case up, down, left, right
        case first, last
    }

    /// 在 `count` 个条目、`columns` 列的网格里移动选择。返回移动后的新选择(self 不可变副本)。
    func moved(_ direction: Direction, columns: Int, count: Int) -> GridSelection {
        guard count > 0 else { return GridSelection(index: nil) }
        let cols = max(1, columns)

        // 无选中时:任意方向键先落到首项(右/下)或末项(左/上)。
        guard let current = index else {
            switch direction {
            case .up, .left, .last: return GridSelection(index: count - 1)
            case .down, .right, .first: return GridSelection(index: 0)
            }
        }

        let clamped = min(max(current, 0), count - 1)
        let next: Int
        switch direction {
        case .left:  next = max(0, clamped - 1)
        case .right: next = min(count - 1, clamped + 1)
        case .up:    next = clamped - cols >= 0 ? clamped - cols : clamped
        case .down:  next = clamped + cols <= count - 1 ? clamped + cols : clamped
        case .first: next = 0
        case .last:  next = count - 1
        }
        return GridSelection(index: next)
    }
}
