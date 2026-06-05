import XCTest
@testable import Niche

@MainActor
final class HoverIntentTests: XCTestCase {
    /// 手动触发的测试调度器:记录待执行 action,由测试显式 fire。
    final class ManualScheduler: HoverIntent.Scheduler {
        final class Token: HoverIntent.Cancelable {
            var cancelled = false
            func cancel() { cancelled = true }
        }
        private(set) var pending: (token: Token, action: () -> Void)?
        func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> HoverIntent.Cancelable {
            let token = Token()
            pending = (token, action)
            return token
        }
        /// 模拟延迟到点:执行未取消的 action。
        func fire() {
            guard let p = pending, !p.token.cancelled else { return }
            p.action()
        }
    }

    func testStayingLongEnoughConfirmsOnce() {
        let scheduler = ManualScheduler()
        let intent = HoverIntent(delay: 0.2, scheduler: scheduler)
        var confirmCount = 0
        intent.onConfirmed = { confirmCount += 1 }

        intent.enter()
        XCTAssertTrue(intent.isPending)
        scheduler.fire()
        XCTAssertEqual(confirmCount, 1)
        XCTAssertFalse(intent.isPending)
    }

    func testLeavingBeforeDelayCancels() {
        let scheduler = ManualScheduler()
        let intent = HoverIntent(delay: 0.2, scheduler: scheduler)
        var confirmCount = 0
        intent.onConfirmed = { confirmCount += 1 }

        intent.enter()
        intent.exit()
        scheduler.fire()   // token 已取消,不应触发
        XCTAssertEqual(confirmCount, 0)
        XCTAssertFalse(intent.isPending)
    }

    func testRepeatedEnterDoesNotStackTimers() {
        let scheduler = ManualScheduler()
        let intent = HoverIntent(delay: 0.2, scheduler: scheduler)
        intent.enter()
        intent.enter()   // 已 pending,忽略
        XCTAssertTrue(intent.isPending)
    }
}
