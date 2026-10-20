import Foundation
import Testing
@testable import Niche

/// TriggerPreferences 从 Combine 迁到 Observation 后,宿主靠显式 onChange 应用偏好;
/// 滑杆的连续值仍只在编辑结束时落盘(didSet 只回调、不写盘)。
@MainActor
@Suite("TriggerPreferences 变更回调")
struct TriggerPreferencesObservationTests {
    @Test("偏好变化立即回调,离散项立即持久化")
    func changesNotifyAndPersist() throws {
        let suite = "niche.tests.triggerprefs.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = TriggerPreferences(defaults: defaults)
        var changes = 0
        prefs.onChange = { changes += 1 }

        prefs.hotZoneEnabled = false
        prefs.hoverDelay = 0.5
        prefs.hotZoneWidthScale = 1.4
        prefs.fallbackHotZoneEnabled = false
        prefs.enabledHotCorners = [.topLeft]
        prefs.enabledSides = [.left]
        let customHotkey = HotkeyPreference(keyCode: 0, carbonModifiers: 0, display: "⌃A")
        prefs.hotkey = customHotkey
        #expect(changes == 7)

        // 连续值只在滑杆松手时落盘。
        prefs.persistHoverDelay()
        prefs.persistHotZoneWidthScale()

        let reloaded = TriggerPreferences(defaults: defaults)
        #expect(reloaded.hotZoneEnabled == false)
        #expect(reloaded.hoverDelay == 0.5)
        #expect(reloaded.hotZoneWidthScale == 1.4)
        #expect(reloaded.fallbackHotZoneEnabled == false)
        #expect(reloaded.enabledHotCorners == [.topLeft])
        #expect(reloaded.enabledSides == [.left])
        #expect(reloaded.hotkey == customHotkey)
    }
}