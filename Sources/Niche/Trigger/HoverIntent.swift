import Foundation

/// hover 意图判定(spec §4.2:空手 hover 带 intent 延迟防误触;§4.3:停留够久才真正展开)。
///
/// 鼠标进入热区不立即展开,先起一个延迟计时;期间离开则取消。延迟到点才回调展开。
/// 时钟可注入,便于单测(不依赖真实 RunLoop)。
@MainActor
final class HoverIntent {
    /// 抽象的延迟调度器,便于测试替身。
    protocol Scheduler {
        /// 在 `delay` 后执行 `action`,返回一个可取消的 token。
        func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> Cancelable
    }
    protocol Cancelable {
        func cancel()
    }

    /// 意图延迟,可在运行期由设置调整(只影响下一次 enter,正在跑的计时不重排)。
    var delay: TimeInterval
    private let scheduler: Scheduler
    private var pending: Cancelable?
    /// 展开回调。
    var onConfirmed: (() -> Void)?

    init(delay: TimeInterval = 0.18, scheduler: Scheduler = DispatchScheduler()) {
        self.delay = delay
        self.scheduler = scheduler
    }

    /// 鼠标进入热区:起意图计时(已在计时则忽略重复进入)。
    func enter() {
        guard pending == nil else { return }
        pending = scheduler.schedule(after: delay) { [weak self] in
            self?.pending = nil
            self?.onConfirmed?()
        }
    }

    /// 鼠标离开热区:取消尚未到点的意图。
    func exit() {
        pending?.cancel()
        pending = nil
    }

    var isPending: Bool { pending != nil }
}

/// 基于 GCD 的默认调度器(主队列)。非 actor 隔离:仅把 action 投递到主队列执行。
final class DispatchScheduler: HoverIntent.Scheduler {
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> HoverIntent.Cancelable {
        let work = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return Token(work: work)
    }
    private final class Token: HoverIntent.Cancelable {
        let work: DispatchWorkItem
        init(work: DispatchWorkItem) { self.work = work }
        func cancel() { work.cancel() }
    }
}
