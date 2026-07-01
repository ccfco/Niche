import XCTest
@testable import Niche

@MainActor
final class OnboardingStateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "niche.onboarding.hasSeen")
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
        let prefs = TriggerPreferences()
        prefs.hotZoneEnabled = true
        XCTAssertTrue(prefs.onboardingTriggerDescription.contains("刘海")
            || prefs.onboardingTriggerDescription.contains("顶部"))

        prefs.hotZoneEnabled = false
        XCTAssertTrue(prefs.onboardingTriggerDescription.contains("快捷键"))
    }
}
