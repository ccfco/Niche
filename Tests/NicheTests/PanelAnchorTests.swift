import XCTest
import CoreGraphics
@testable import Niche

final class PanelAnchorTests: XCTestCase {
    // 模拟 1920×1080 外接屏,菜单栏 24、Dock 70(可视区 y ∈ [70, 1056])。
    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let visible = CGRect(x: 0, y: 70, width: 1920, height: 986)
    private let size = CGSize(width: 600, height: 400)

    func testTopAnchorMatchesLegacyStandardFrame() {
        let notch = CGRect(x: 860, y: 1043, width: 200, height: 37)
        let target = PanelAnchor.top(notch).targetFrame(panelSize: size, visible: visible)
        XCTAssertEqual(target.midX, notch.midX, accuracy: 0.001)
        XCTAssertEqual(target.maxY, notch.minY, accuracy: 0.001)   // 顶边贴刘海底
    }

    func testCornerTargetsFlushWithVisibleCorners() {
        let rect = CGRect.zero
        let br = PanelAnchor.corner(.bottomRight, rect).targetFrame(panelSize: size, visible: visible)
        XCTAssertEqual(br.maxX, visible.maxX, accuracy: 0.001)
        XCTAssertEqual(br.minY, visible.minY, accuracy: 0.001)     // 贴可视区,自动避开 Dock
        let tl = PanelAnchor.corner(.topLeft, rect).targetFrame(panelSize: size, visible: visible)
        XCTAssertEqual(tl.minX, visible.minX, accuracy: 0.001)
        XCTAssertEqual(tl.maxY, visible.maxY, accuracy: 0.001)
    }

    func testSideTargetFollowsMouseAndClamps() {
        // 左边缘,鼠标居中:面板贴左、垂直居中于鼠标。
        let mid = PanelAnchor.side(.left, mouse: CGPoint(x: 0, y: 500))
            .targetFrame(panelSize: size, visible: visible)
        XCTAssertEqual(mid.minX, visible.minX, accuracy: 0.001)
        XCTAssertEqual(mid.midY, 500, accuracy: 0.001)
        // 下边缘,鼠标贴屏幕最右:面板夹回可视区内不越界。
        let clamped = PanelAnchor.side(.bottom, mouse: CGPoint(x: 1919, y: 0))
            .targetFrame(panelSize: size, visible: visible)
        XCTAssertEqual(clamped.maxX, visible.maxX, accuracy: 0.001)
        XCTAssertEqual(clamped.minY, visible.minY, accuracy: 0.001)
    }

    func testCollapsedFrameHugsAnchorSide() {
        let target = CGRect(x: 100, y: 70, width: 600, height: 400)
        let bottom = PanelAnchor.side(.bottom, mouse: .zero).collapsedFrame(target: target)
        XCTAssertEqual(bottom.minY, target.minY, accuracy: 0.001)
        XCTAssertEqual(bottom.width, target.width, accuracy: 0.001)
        XCTAssertLessThan(bottom.height, 10)
        let right = PanelAnchor.side(.right, mouse: .zero).collapsedFrame(target: target)
        XCTAssertEqual(right.maxX, target.maxX, accuracy: 0.001)
        XCTAssertLessThan(right.width, 10)
    }

    func testCorridorFillsGapBetweenPanelAndPhysicalEdge() {
        // 下边缘触发,面板贴可视区下沿(Dock 上方):走廊须从物理屏底一直铺到面板底。
        let target = CGRect(x: 100, y: 70, width: 600, height: 400)
        let corridor = PanelAnchor.side(.bottom, mouse: .zero)
            .corridorRect(target: target, screenFrame: screen)
        XCTAssertEqual(corridor.minY, screen.minY, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(corridor.maxY, target.minY - 0.001)
    }

    // MARK: - 触发去重判据(修「跨屏呼出被吞、面板滞留旧屏」)

    /// 同屏同热区重复触发(锚点值相等)→ 是重复,present 吞掉(hover 进面板再回刘海的历史行为)。
    func testSameTopAnchorIsDuplicateTrigger() {
        let notch = CGRect(x: 860, y: 1043, width: 200, height: 37)
        XCTAssertTrue(PanelAnchor.isSameTriggerTarget(.top(notch), .top(notch)))
    }

    /// 跨屏触发(热区 rect 不同)→ 不是重复,必须重新 present 把面板挪到新屏。
    func testCrossScreenTopAnchorIsNotDuplicate() {
        let screenB = CGRect(x: 2500, y: 1408, width: 260, height: 32)
        XCTAssertFalse(PanelAnchor.isSameTriggerTarget(
            .top(CGRect(x: 860, y: 1043, width: 200, height: 37)), .top(screenB)
        ))
    }

    /// 换触发区(顶部 → 热角)→ 不是重复。
    func testDifferentAnchorKindIsNotDuplicate() {
        XCTAssertFalse(PanelAnchor.isSameTriggerTarget(
            .top(.zero), .corner(.topLeft, CGRect(x: 0, y: 1060, width: 20, height: 20))
        ))
    }

    /// 边缘锚点忽略鼠标位置:同一条边即同锚点(鼠标微移不该被判异锚点、反复重放动画)。
    func testSameSideIgnoresMousePosition() {
        XCTAssertTrue(PanelAnchor.isSameTriggerTarget(
            .side(.left, mouse: CGPoint(x: 2, y: 300)), .side(.left, mouse: CGPoint(x: 1, y: 700))
        ))
        XCTAssertFalse(PanelAnchor.isSameTriggerTarget(
            .side(.left, mouse: CGPoint(x: 2, y: 300)), .side(.right, mouse: CGPoint(x: 1918, y: 300))
        ))
    }

    /// 无刘海屏调热区宽度(widthScale)只改 rect 的 x/width,面板落位(midX/minY)不变:
    /// 仍算同锚点,不该重放动画 + 重新 armCurrent(Codex review Low #4)。
    func testTopAnchorIgnoresWidthChangeWithSamePlacement() {
        XCTAssertTrue(PanelAnchor.isSameTriggerTarget(
            .top(CGRect(x: 800, y: 1043, width: 320, height: 37)),
            .top(CGRect(x: 640, y: 1043, width: 640, height: 37))   // 同 midX=960、同 minY
        ))
    }

    // MARK: - shouldSwallowTrigger(去重终判:锚点 + 屏幕身份)

    private let screenA = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let screenB = CGRect(x: 1920, y: 0, width: 2560, height: 1440)

    /// 异屏同侧不吞:.side 携带值区分不了屏,必须靠屏 frame 比对(Codex review High #1)。
    func testCrossScreenSameSideIsNotSwallowed() {
        XCTAssertFalse(PanelAnchor.shouldSwallowTrigger(
            current: (.side(.left, mouse: CGPoint(x: 2, y: 300)), screenA),
            target: .side(.left, mouse: CGPoint(x: 1922, y: 500)), targetScreenFrame: screenB
        ))
    }

    /// 同屏同锚点吞(hover 进面板再回刘海的历史幂等行为)。
    func testSameScreenSameAnchorIsSwallowed() {
        let notch = CGRect(x: 860, y: 1043, width: 200, height: 37)
        XCTAssertTrue(PanelAnchor.shouldSwallowTrigger(
            current: (.top(notch), screenA), target: .top(notch), targetScreenFrame: screenA
        ))
    }

    /// 无已展开瞬态(含收回动画中,current = nil)不吞:收回中重触发 = 把面板叫回来。
    func testNoActiveTransientIsNotSwallowed() {
        XCTAssertFalse(PanelAnchor.shouldSwallowTrigger(
            current: nil, target: .top(.zero), targetScreenFrame: screenA
        ))
    }

    /// 脱锚浮面板(unpin 回瞬态,anchor = nil)吞:热区触发不把浮着的面板拽回锚点。
    func testDetachedTransientSwallowsTrigger() {
        XCTAssertTrue(PanelAnchor.shouldSwallowTrigger(
            current: (nil, screenA), target: .top(.zero), targetScreenFrame: screenA
        ))
    }

    func testGrowsUpwardOnlyForBottomAnchors() {
        XCTAssertTrue(PanelAnchor.side(.bottom, mouse: .zero).growsUpward)
        XCTAssertTrue(PanelAnchor.corner(.bottomLeft, .zero).growsUpward)
        XCTAssertFalse(PanelAnchor.top(.zero).growsUpward)
        XCTAssertFalse(PanelAnchor.side(.left, mouse: .zero).growsUpward)
        XCTAssertFalse(PanelAnchor.corner(.topRight, .zero).growsUpward)
    }
}
