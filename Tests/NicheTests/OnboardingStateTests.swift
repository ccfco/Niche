import XCTest
@testable import Niche

@MainActor
final class OnboardingStateTests: XCTestCase {
    private var originalHasSeen: Any?

    override func setUp() {
        super.setUp()
        // 宿主测试与生产 app 共用 com.ccfco.Niche 的 UserDefaults.standard。测试 false/true 合同前
        // 必须快照,tearDown 原样恢复;否则每次全量测试都会把老用户重置成首次使用、部署后重新弹引导。
        originalHasSeen = UserDefaults.standard.object(forKey: "niche.onboarding.hasSeen")
        UserDefaults.standard.removeObject(forKey: "niche.onboarding.hasSeen")
    }

    override func tearDown() {
        if let originalHasSeen {
            UserDefaults.standard.set(originalHasSeen, forKey: "niche.onboarding.hasSeen")
        } else {
            UserDefaults.standard.removeObject(forKey: "niche.onboarding.hasSeen")
        }
        super.tearDown()
    }

    func testDefaultsToFalse() {
        XCTAssertFalse(OnboardingState.hasSeen)
    }

    func testSettingPersists() {
        OnboardingState.hasSeen = true
        XCTAssertTrue(OnboardingState.hasSeen)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "niche.onboarding.hasSeen"))
    }

    func testTriggerDescriptionReflectsHotZoneEnabled() {
        // 单元测试寄宿在真实 Niche.app 进程里跑,TriggerPreferences 的 didSet 会写入
        // UserDefaults.standard —— 这就是真机上 com.ccfco.Niche 的那份真实偏好设置,不是隔离的
        // 测试沙盒。之前这里改完 hotZoneEnabled 不复原,导致每次跑测试都会把用户机器上的热区
        // 开关真的改成关闭(实测踩过:每次 build+test 后部署,热区必然是关的)。快照 + defer 复原,
        // 不能让测试留下可观测的副作用。
        let original = UserDefaults.standard.object(forKey: "niche.hotZoneEnabled") as? Bool
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: "niche.hotZoneEnabled")
            } else {
                UserDefaults.standard.removeObject(forKey: "niche.hotZoneEnabled")
            }
        }

        let prefs = TriggerPreferences()
        prefs.hotZoneEnabled = true
        XCTAssertTrue(prefs.onboardingTriggerDescription.contains("刘海")
            || prefs.onboardingTriggerDescription.contains("顶部"))

        prefs.hotZoneEnabled = false
        XCTAssertTrue(prefs.onboardingTriggerDescription.contains("快捷键"))
    }

    func testHoverDelayDefaultsToPointThreeAndPreservesSavedChoice() {
        let original = UserDefaults.standard.object(forKey: "niche.hoverDelay")
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: "niche.hoverDelay")
            } else {
                UserDefaults.standard.removeObject(forKey: "niche.hoverDelay")
            }
        }

        UserDefaults.standard.removeObject(forKey: "niche.hoverDelay")
        XCTAssertEqual(TriggerPreferences().hoverDelay, 0.3, accuracy: 0.001)

        UserDefaults.standard.set(0.18, forKey: "niche.hoverDelay")
        XCTAssertEqual(TriggerPreferences().hoverDelay, 0.18, accuracy: 0.001)
    }

    func testHoverDelayLogScaleRoundTripsAndCoversFiveSeconds() {
        for delay in [0.1, 0.18, 0.3, 1, 2, 5] {
            let position = TriggerPreferences.sliderPosition(for: delay)
            XCTAssertGreaterThanOrEqual(position, 0)
            XCTAssertLessThanOrEqual(position, 1)
            XCTAssertEqual(TriggerPreferences.hoverDelay(forSliderPosition: position), delay,
                           accuracy: 0.000_1)
        }
        XCTAssertEqual(TriggerPreferences.hoverDelay(forSliderPosition: -1), 0.1, accuracy: 0.000_1)
        XCTAssertEqual(TriggerPreferences.hoverDelay(forSliderPosition: 2), 5, accuracy: 0.000_1)
    }

    func testFallbackTopZoneCanBeDisabledWithoutDisablingRealNotch() {
        let originalHotZone = UserDefaults.standard.object(forKey: "niche.hotZoneEnabled")
        let originalFallback = UserDefaults.standard.object(forKey: "niche.fallbackHotZoneEnabled")
        defer {
            restore(originalHotZone, key: "niche.hotZoneEnabled")
            restore(originalFallback, key: "niche.fallbackHotZoneEnabled")
        }

        let prefs = TriggerPreferences()
        prefs.hotZoneEnabled = true
        prefs.fallbackHotZoneEnabled = false
        XCTAssertTrue(prefs.enablesPrimaryZone(hasNotch: true))
        XCTAssertFalse(prefs.enablesPrimaryZone(hasNotch: false))

        prefs.hotZoneEnabled = false
        XCTAssertFalse(prefs.enablesPrimaryZone(hasNotch: true))
    }

    func testFallbackWidthScaleClampsLegacyOutOfRangeValues() {
        let original = UserDefaults.standard.object(forKey: "niche.hotZoneWidthScale")
        defer { restore(original, key: "niche.hotZoneWidthScale") }

        UserDefaults.standard.set(9, forKey: "niche.hotZoneWidthScale")
        XCTAssertEqual(TriggerPreferences().hotZoneWidthScale, 2, accuracy: 0.001)

        UserDefaults.standard.set(0.1, forKey: "niche.hotZoneWidthScale")
        XCTAssertEqual(TriggerPreferences().hotZoneWidthScale, 0.6, accuracy: 0.001)
    }

    private func restore(_ value: Any?, key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
}
