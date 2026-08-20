import XCTest
@testable import Niche

@MainActor
final class FullNamePeekTests: XCTestCase {
    final class ManualScheduler: HoverIntent.Scheduler {
        final class Token: HoverIntent.Cancelable {
            var cancelled = false
            func cancel() { cancelled = true }
        }

        private var pending: [(token: Token, action: () -> Void)] = []

        func schedule(after delay: TimeInterval,
                      _ action: @escaping () -> Void) -> HoverIntent.Cancelable {
            let token = Token()
            pending.append((token, action))
            return token
        }

        func fireNext() {
            while !pending.isEmpty {
                let next = pending.removeFirst()
                if !next.token.cancelled { next.action(); return }
            }
        }

        func fireAll() {
            while !pending.isEmpty { fireNext() }
        }
    }

    private let longID = URL(fileURLWithPath: "/tmp/a-very-long-file-name.txt")
    private let otherID = URL(fileURLWithPath: "/tmp/another-long-file-name.txt")

    func testHoverOnlyPresentsRegisteredTruncatedName() {
        let scheduler = ManualScheduler()
        let peek = FullNamePeekCoordinator(scheduler: scheduler)
        let token = UUID()
        peek.updateTarget(id: longID, token: token, name: "完整文件名.txt", isTruncated: true)

        peek.hoverChanged(id: longID, hovering: true)
        XCTAssertNil(peek.presentation)
        scheduler.fireNext()

        XCTAssertEqual(peek.presentation?.id, longID)
        XCTAssertEqual(peek.presentation?.origin, .hover)
    }

    func testUntruncatedNameNeverPresents() {
        let scheduler = ManualScheduler()
        let peek = FullNamePeekCoordinator(scheduler: scheduler)
        peek.updateTarget(id: longID, token: UUID(), name: "短名", isTruncated: false)

        peek.hoverChanged(id: longID, hovering: true)
        peek.selectionChanged(to: longID)
        scheduler.fireAll()

        XCTAssertNil(peek.presentation)
    }

    func testRapidSelectionOnlyPresentsFinalSettledItem() {
        let scheduler = ManualScheduler()
        let peek = FullNamePeekCoordinator(scheduler: scheduler)
        peek.updateTarget(id: longID, token: UUID(), name: "第一个很长的文件名", isTruncated: true)
        peek.updateTarget(id: otherID, token: UUID(), name: "最终停稳的很长文件名", isTruncated: true)

        peek.selectionChanged(to: longID)
        peek.selectionChanged(to: otherID)
        scheduler.fireNext()

        XCTAssertEqual(peek.presentation?.id, otherID)
        XCTAssertEqual(peek.presentation?.origin, .selection)
    }

    func testDismissCancelsPendingPresentation() {
        let scheduler = ManualScheduler()
        let peek = FullNamePeekCoordinator(scheduler: scheduler)
        peek.updateTarget(id: longID, token: UUID(), name: "完整文件名", isTruncated: true)
        peek.hoverChanged(id: longID, hovering: true)

        peek.dismiss()
        scheduler.fireAll()

        XCTAssertNil(peek.presentation)
    }

    func testDismissClearsSelectionIntentAcrossTargetReregistration() {
        let scheduler = ManualScheduler()
        let peek = FullNamePeekCoordinator(scheduler: scheduler)
        peek.updateTarget(id: longID, token: UUID(), name: "完整文件名", isTruncated: true)
        peek.selectionChanged(to: longID)
        peek.dismiss()

        peek.updateTarget(id: longID, token: UUID(), name: "完整文件名", isTruncated: true)
        scheduler.fireAll()

        XCTAssertNil(peek.presentation)
    }

    func testTruncationUsesRenderedWidthInsteadOfCharacterCount() {
        XCTAssertFalse(FilenameTruncation.isTruncated("短名", width: 120, layout: .list))
        XCTAssertTrue(FilenameTruncation.isTruncated(String(repeating: "W", count: 30),
                                                      width: 60, layout: .list))
        XCTAssertFalse(FilenameTruncation.isTruncated("两行以内", width: 120, layout: .grid))
        XCTAssertTrue(FilenameTruncation.isTruncated(String(repeating: "很长的文件名", count: 12),
                                                     width: 70, layout: .grid))
    }

    func testPlacementStaysInsidePanelAndFlipsAboveNearBottom() {
        let container = CGSize(width: 400, height: 260)
        let bubble = CGSize(width: 220, height: 70)
        let anchor = CGRect(x: 340, y: 220, width: 40, height: 20)
        let origin = FullNamePeekPlacement.origin(anchor: anchor, bubble: bubble,
                                                  container: container, margin: 12, gap: 4)

        XCTAssertGreaterThanOrEqual(origin.x, 12)
        XCTAssertLessThanOrEqual(origin.x + bubble.width, container.width - 12)
        XCTAssertLessThan(origin.y, anchor.minY)
        XCTAssertGreaterThanOrEqual(origin.y, 12)
    }
}
