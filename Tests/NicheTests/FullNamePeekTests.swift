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
        peek.updateTarget(id: longID, token: token, name: "完整文件名.txt",
                          isTruncated: true, layout: .grid)

        peek.hoverChanged(id: longID, hovering: true)
        XCTAssertNil(peek.presentation)
        scheduler.fireNext()

        XCTAssertEqual(peek.presentation?.id, longID)
        XCTAssertEqual(peek.presentation?.origin, .hover)
    }

    func testUntruncatedNameNeverPresents() {
        let scheduler = ManualScheduler()
        let peek = FullNamePeekCoordinator(scheduler: scheduler)
        peek.updateTarget(id: longID, token: UUID(), name: "短名",
                          isTruncated: false, layout: .grid)

        peek.hoverChanged(id: longID, hovering: true)
        peek.selectionChanged(to: longID)
        scheduler.fireAll()

        XCTAssertNil(peek.presentation)
    }

    func testRapidSelectionOnlyPresentsFinalSettledItem() {
        let scheduler = ManualScheduler()
        let peek = FullNamePeekCoordinator(scheduler: scheduler)
        peek.updateTarget(id: longID, token: UUID(), name: "第一个很长的文件名",
                          isTruncated: true, layout: .grid)
        peek.updateTarget(id: otherID, token: UUID(), name: "最终停稳的很长文件名",
                          isTruncated: true, layout: .grid)

        peek.selectionChanged(to: longID)
        peek.selectionChanged(to: otherID)
        scheduler.fireNext()

        XCTAssertEqual(peek.presentation?.id, otherID)
        XCTAssertEqual(peek.presentation?.origin, .selection)

        // 选中代表明确关注，完整名称保持到选择或其他交互发生，不再定时消失。
        scheduler.fireAll()
        XCTAssertEqual(peek.presentation?.id, otherID)
    }

    func testChangingSelectionClearsPreviousPersistentNameImmediately() {
        let scheduler = ManualScheduler()
        let peek = FullNamePeekCoordinator(scheduler: scheduler)
        peek.updateTarget(id: longID, token: UUID(), name: "第一个很长的文件名",
                          isTruncated: true, layout: .grid)
        peek.updateTarget(id: otherID, token: UUID(), name: "另一个很长的文件名",
                          isTruncated: true, layout: .grid)
        peek.selectionChanged(to: longID)
        scheduler.fireNext()

        peek.selectionChanged(to: otherID)

        XCTAssertNil(peek.presentation)
    }

    func testDismissCancelsPendingPresentation() {
        let scheduler = ManualScheduler()
        let peek = FullNamePeekCoordinator(scheduler: scheduler)
        peek.updateTarget(id: longID, token: UUID(), name: "完整文件名",
                          isTruncated: true, layout: .grid)
        peek.hoverChanged(id: longID, hovering: true)

        peek.dismiss()
        scheduler.fireAll()

        XCTAssertNil(peek.presentation)
    }

    func testDismissClearsSelectionIntentAcrossTargetReregistration() {
        let scheduler = ManualScheduler()
        let peek = FullNamePeekCoordinator(scheduler: scheduler)
        peek.updateTarget(id: longID, token: UUID(), name: "完整文件名",
                          isTruncated: true, layout: .grid)
        peek.selectionChanged(to: longID)
        peek.dismiss()

        peek.updateTarget(id: longID, token: UUID(), name: "完整文件名",
                          isTruncated: true, layout: .grid)
        scheduler.fireAll()

        XCTAssertNil(peek.presentation)
    }

    func testSelectionIntentWaitsForTargetRegistrationAfterViewSwitch() {
        let scheduler = ManualScheduler()
        let peek = FullNamePeekCoordinator(scheduler: scheduler)
        peek.selectionChanged(to: longID)

        peek.updateTarget(id: longID, token: UUID(), name: "新视图里的完整文件名",
                          isTruncated: true, layout: .list)
        scheduler.fireAll()

        XCTAssertEqual(peek.presentation?.id, longID)
        XCTAssertEqual(peek.presentation?.layout, .list)
    }

    func testTruncationUsesRenderedWidthInsteadOfCharacterCount() {
        XCTAssertFalse(FilenameTruncation.isTruncated("短名", width: 120, layout: .list))
        XCTAssertTrue(FilenameTruncation.isTruncated(String(repeating: "W", count: 30),
                                                      width: 60, layout: .list))
        XCTAssertFalse(FilenameTruncation.isTruncated("两行以内", width: 120, layout: .grid))
        XCTAssertTrue(FilenameTruncation.isTruncated(String(repeating: "很长的文件名", count: 12),
                                                     width: 70, layout: .grid))
    }

    func testHoverTemporarilyOverridesAndThenRestoresSelection() {
        let scheduler = ManualScheduler()
        let peek = FullNamePeekCoordinator(scheduler: scheduler)
        peek.updateTarget(id: longID, token: UUID(), name: "已选中的完整文件名",
                          isTruncated: true, layout: .grid)
        peek.updateTarget(id: otherID, token: UUID(), name: "鼠标停留的完整文件名",
                          isTruncated: true, layout: .grid)
        peek.selectionChanged(to: longID)
        scheduler.fireNext()

        peek.hoverChanged(id: otherID, hovering: true)
        scheduler.fireNext()
        XCTAssertEqual(peek.presentation?.id, otherID)
        XCTAssertEqual(peek.presentation?.origin, .hover)

        peek.hoverChanged(id: otherID, hovering: false)
        scheduler.fireNext()
        scheduler.fireNext()
        XCTAssertEqual(peek.presentation?.id, longID)
        XCTAssertEqual(peek.presentation?.origin, .selection)
    }

    func testPlacementOverlaysNameAndStaysInsidePanel() {
        let container = CGSize(width: 400, height: 260)
        let expandedSize = CGSize(width: 220, height: 70)
        let anchor = CGRect(x: 340, y: 220, width: 40, height: 20)
        let origin = FullNamePeekPlacement.origin(anchor: anchor, expandedSize: expandedSize,
                                                  container: container, margin: 12, layout: .grid)

        XCTAssertGreaterThanOrEqual(origin.x, 12)
        XCTAssertLessThanOrEqual(origin.x + expandedSize.width, container.width - 12)
        XCTAssertGreaterThanOrEqual(origin.y, 12)
        XCTAssertLessThanOrEqual(origin.y + expandedSize.height, container.height - 12)
    }

    func testGridPlacementExpandsUpwardAndKeepsMetadataBelowClear() {
        let container = CGSize(width: 400, height: 260)
        let expandedSize = CGSize(width: 120, height: 56)
        let anchor = CGRect(x: 140, y: 150, width: 100, height: 32)
        let origin = FullNamePeekPlacement.origin(anchor: anchor, expandedSize: expandedSize,
                                                  container: container, margin: 12, layout: .grid)

        XCTAssertEqual(origin.y + expandedSize.height, anchor.maxY, accuracy: 0.001)
    }
}
