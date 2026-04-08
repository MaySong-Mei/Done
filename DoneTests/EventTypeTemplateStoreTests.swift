import SwiftUI
import XCTest
@testable import Done

final class EventTypeTemplateStoreTests: XCTestCase {
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "EventTypeTemplateStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDown() {
        if let defaultsSuiteName, let defaults {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }
        defaults = nil
        defaultsSuiteName = nil
        super.tearDown()
    }

    func testColorHexRoundTripPreservesAlpha() {
        let hex = ColorHex.fromColor(Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 0.5))

        XCTAssertEqual(hex, "#FF000080")
        XCTAssertEqual(ColorHex.fromColor(ColorHex.toColor(hex)), "#FF000080")
    }

    func testStorePersistsTransparentTemplateColor() {
        let templates = [EventTypeTemplate(title: "Focus", colorHex: "#3366CC80")]
        let data = try! JSONEncoder().encode(templates)
        defaults.set(data, forKey: EventTypeTemplateStore.storageKey)

        XCTAssertEqual(
            ColorHex.fromColor(EventTypeTemplateStore.color(for: "Focus", defaults: defaults)),
            "#3366CC80"
        )
    }

    func testEffortOpacityDisabledReturnsFullOpacity() {
        // When the setting is OFF, all events render fully opaque
        // regardless of colorDepth.
        let unlogged = Event(title: "Study Session", type: "Study")
        XCTAssertEqual(
            unlogged.colorOpacityMultiplier(effortOpacityEnabled: false),
            1.0,
            accuracy: 0.0001
        )

        let logged = Event(
            title: "Study Session",
            type: "Study",
            colorDepth: Event.colorDepth(forEffort: 1)
        )
        XCTAssertEqual(
            logged.colorOpacityMultiplier(effortOpacityEnabled: false),
            1.0,
            accuracy: 0.0001
        )
    }

    func testEffortOpacityEnabledUnloggedDefaultsToMedium() {
        // When the setting is ON (default), an event WITHOUT an effort log
        // should render at medium opacity (≈ 0.7), not 1.0.
        let unlogged = Event(title: "Study Session", type: "Study")
        XCTAssertEqual(
            unlogged.colorOpacityMultiplier(effortOpacityEnabled: true),
            0.7,
            accuracy: 0.0001
        )
    }

    func testEffortOpacityEnabledHighEffortMoreOpaqueThanLow() {
        let lowEffort = Event(
            title: "Easy Task",
            type: "Study",
            colorDepth: Event.colorDepth(forEffort: 1)
        )
        let highEffort = Event(
            title: "Hard Task",
            type: "Study",
            colorDepth: Event.colorDepth(forEffort: 5)
        )
        let lowOpacity = lowEffort.colorOpacityMultiplier(effortOpacityEnabled: true)
        let highOpacity = highEffort.colorOpacityMultiplier(effortOpacityEnabled: true)
        XCTAssertLessThan(lowOpacity, highOpacity)
    }

    func testEffortOpacityEnabledLogged5IsFullyOpaque() {
        let event = Event(
            title: "Max Effort",
            type: "Study",
            colorDepth: Event.colorDepth(forEffort: 5)
        )
        XCTAssertEqual(
            event.colorOpacityMultiplier(effortOpacityEnabled: true),
            1.0,
            accuracy: 0.0001
        )
    }

    func testEffortOpacityEnabledLogged1IsBelowDefault() {
        // Effort 1 should be MORE transparent than the default (no-log)
        // medium opacity, so the visual hierarchy is:
        //     low effort < unlogged < high effort
        let unlogged = Event(title: "Unlogged", type: "Study")
        let lowEffort = Event(
            title: "Low Effort",
            type: "Study",
            colorDepth: Event.colorDepth(forEffort: 1)
        )
        XCTAssertLessThan(
            lowEffort.colorOpacityMultiplier(effortOpacityEnabled: true),
            unlogged.colorOpacityMultiplier(effortOpacityEnabled: true)
        )
    }

    func testEffortMappingProducesStableColorDepthAndOpacity() {
        XCTAssertEqual(Event.colorDepth(forEffort: nil), 0, accuracy: 0.0001)
        XCTAssertEqual(Event.colorDepth(forEffort: 1), 0.2, accuracy: 0.0001)
        XCTAssertEqual(Event.colorDepth(forEffort: 4), 0.8, accuracy: 0.0001)

        let event = Event(
            title: "Deep Work",
            type: "Study",
            colorDepth: Event.colorDepth(forEffort: 4)
        )
        XCTAssertEqual(
            event.colorOpacityMultiplier(effortOpacityEnabled: true),
            0.88,
            accuracy: 0.0001
        )
    }

}
