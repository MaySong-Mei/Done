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

    func testCalendarLayoutEventColorKeepsBaseOpacityWhenNoEffortDepth() {
        let event = Event(title: "Study Session", type: "Study")

        XCTAssertEqual(ColorHex.fromColor(CalendarLayout.eventColor(for: event)), "#34C759")
    }

    func testCalendarLayoutEventColorAppliesEffortDrivenOpacity() {
        let event = Event(
            title: "Study Session",
            type: "Study",
            colorDepth: Event.colorDepth(forEffort: 1)
        )

        XCTAssertEqual(ColorHex.fromColor(CalendarLayout.eventColor(for: event)), "#34C75985")
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
        XCTAssertEqual(event.colorOpacityMultiplier, 0.88, accuracy: 0.0001)
    }

}
