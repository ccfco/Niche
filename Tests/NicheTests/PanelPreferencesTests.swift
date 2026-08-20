import XCTest
@testable import Niche

@MainActor
final class PanelPreferencesTests: XCTestCase {
    private let keys = [
        "niche.panelWidth",
        "niche.panelHeight",
        "niche.filenameLineLimit",
        "niche.autoHideDelay",
        "niche.iconSize",
        "niche.showItemInfo",
        "niche.showHidden",
        "niche.viewMode",
    ]
    private var original: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        for key in keys {
            if let value = defaults.object(forKey: key) { original[key] = value }
            defaults.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        for key in keys {
            if let value = original[key] { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        original.removeAll()
        super.tearDown()
    }

    func testDefaultsPreserveCurrentPanelGeometry() {
        let model = PanelModel()

        XCTAssertEqual(model.preferredPanelWidth, PanelModel.defaultPanelWidth, accuracy: 0.001)
        XCTAssertEqual(model.preferredPanelHeight, PanelModel.defaultPanelHeight, accuracy: 0.001)
        XCTAssertEqual(model.filenameLineLimit, 3)
        XCTAssertEqual(model.autoHideDelay, 0.35, accuracy: 0.001)
        XCTAssertEqual(model.iconSize, 52, accuracy: 0.001)
        XCTAssertTrue(model.showItemInfo)
        XCTAssertFalse(model.showHidden)
        XCTAssertEqual(model.viewMode, .icon)
    }

    func testExistingPanelPreferencesSurviveModelRecreationAndNewDefaults() {
        let model = PanelModel()
        model.preferredPanelWidth = 843
        model.preferredPanelHeight = 537
        model.filenameLineLimit = 1
        model.autoHideDelay = 0.8
        model.iconSize = 96
        model.showItemInfo = false
        model.showHidden = true
        model.viewMode = .list
        model.persistPanelSize()
        model.persistIconSize()

        let restored = PanelModel()
        XCTAssertEqual(restored.preferredPanelWidth, 843, accuracy: 0.001)
        XCTAssertEqual(restored.preferredPanelHeight, 537, accuracy: 0.001)
        XCTAssertEqual(restored.filenameLineLimit, 1)
        XCTAssertEqual(restored.autoHideDelay, 0.8, accuracy: 0.001)
        XCTAssertEqual(restored.iconSize, 96, accuracy: 0.001)
        XCTAssertFalse(restored.showItemInfo)
        XCTAssertTrue(restored.showHidden)
        XCTAssertEqual(restored.viewMode, .list)
    }

    func testRestorePanelDefaultsWritesAllManagedPreferences() {
        let model = PanelModel()
        model.preferredPanelWidth = 1000
        model.preferredPanelHeight = 700
        model.filenameLineLimit = 1
        model.autoHideDelay = 0.8
        model.iconSize = 96
        model.showItemInfo = false
        model.showHidden = true
        model.viewMode = .list

        model.restorePanelDefaults()

        XCTAssertEqual(model.preferredPanelWidth, PanelModel.defaultPanelWidth, accuracy: 0.001)
        XCTAssertEqual(model.preferredPanelHeight, PanelModel.defaultPanelHeight, accuracy: 0.001)
        XCTAssertEqual(model.filenameLineLimit, 3)
        XCTAssertEqual(model.autoHideDelay, 0.35, accuracy: 0.001)
        XCTAssertEqual(model.iconSize, 52, accuracy: 0.001)
        XCTAssertTrue(model.showItemInfo)
        XCTAssertFalse(model.showHidden)
        XCTAssertEqual(model.viewMode, .icon)
    }

    func testUnknownAutoHideDelayNormalizesToNearestVisibleOption() {
        UserDefaults.standard.set(0.72, forKey: "niche.autoHideDelay")

        XCTAssertEqual(PanelModel().autoHideDelay, 0.8, accuracy: 0.001)
    }

    func testSpokenSliderValueDoesNotMutateControlValue() {
        let slider = FinalizingNSSlider(value: 0.28, minValue: 0, maxValue: 1,
                                        target: nil, action: nil)
        slider.presentedAccessibilityValue = "0.30 秒"

        XCTAssertEqual(slider.doubleValue, 0.28, accuracy: 0.000_1)
        XCTAssertEqual(slider.accessibilityValue() as? String, "0.30 秒")
        XCTAssertEqual(slider.doubleValue, 0.28, accuracy: 0.000_1)
    }
}
