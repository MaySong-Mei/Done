import XCTest
import SwiftUI
@testable import Done

/// gh#219 slice C — exactness pins for the (title -> Color) catalog memo and
/// the effort-opacity overload on `CalendarLayout.eventColor`.
@MainActor
final class RenderReadColorTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "RenderReadColorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        if let suiteName, let defaults { defaults.removePersistentDomain(forName: suiteName) }
        defaults = nil; suiteName = nil
        super.tearDown()
    }

    // MARK: - C(i): memo behavior-preservation + exactness

    /// The memoized resolver returns the same value the old uncached path did:
    /// `ColorHex.toColor(hex-from-the-ladder)`.
    func testColorMatchesUncachedToColorForSeededTemplate() {
        let catalog = EventTypeCatalog.forDefaults(defaults)
        _ = catalog.setTemplates([EventTypeTemplate(title: "Work", colorHex: "#0A84FF")])
        XCTAssertEqual(EventTypeTemplateStore.color(for: "Work", defaults: defaults),
                       ColorHex.toColor("#0A84FF"))
        // ... and repeated reads (which now hit the cache) stay identical.
        XCTAssertEqual(EventTypeTemplateStore.color(for: "Work", defaults: defaults),
                       ColorHex.toColor("#0A84FF"))
    }

    /// "Two colors of the same type are equal" (proof-obligation wording).
    func testTwoColorsOfSameTypeAreEqual() {
        let catalog = EventTypeCatalog.forDefaults(defaults)
        _ = catalog.setTemplates([EventTypeTemplate(title: "Study", colorHex: "#34C759")])
        let a = EventTypeTemplateStore.color(for: "Study", defaults: defaults)
        let b = EventTypeTemplateStore.color(for: "Study", defaults: defaults)
        XCTAssertEqual(a, b)
    }

    /// THE exactness pin. First read caches "#0A84FF"; after the catalog hex
    /// changes to "#FF0000" the resolved color MUST change. A memo that
    /// ignored the mutation would return the stale first value here.
    func testColorChangesWhenCatalogHexChanges() {
        let catalog = EventTypeCatalog.forDefaults(defaults)
        _ = catalog.setTemplates([EventTypeTemplate(title: "Work", colorHex: "#0A84FF")])
        let before = EventTypeTemplateStore.color(for: "Work", defaults: defaults)  // caches
        _ = catalog.setTemplates([EventTypeTemplate(title: "Work", colorHex: "#FF0000")])
        let after = EventTypeTemplateStore.color(for: "Work", defaults: defaults)
        XCTAssertEqual(before, ColorHex.toColor("#0A84FF"))
        XCTAssertEqual(after, ColorHex.toColor("#FF0000"))
        XCTAssertNotEqual(before, after)
    }

    /// The color-history rung feeds the same cache and must also invalidate it.
    func testColorReflectsColorHistoryChange() {
        let catalog = EventTypeCatalog.forDefaults(defaults)
        _ = catalog.setTemplates([])   // no template match -> history / default
        let d1 = EventTypeTemplateStore.color(for: "Ghost", defaults: defaults)  // default, caches
        _ = catalog.setColorHistory(["Ghost": "#123456"])
        let d2 = EventTypeTemplateStore.color(for: "Ghost", defaults: defaults)
        XCTAssertEqual(d1, ColorHex.toColor(EventTypeTemplateStore.defaultColorHex(for: "Ghost")))
        XCTAssertEqual(d2, ColorHex.toColor("#123456"))
        XCTAssertNotEqual(d1, d2)
    }

    /// The static `colorHex(for:)` (now single-sourced through `resolvedColorHex`)
    /// still walks template -> history -> default in that precedence.
    func testColorHexLadderPrecedenceUnchanged() {
        let catalog = EventTypeCatalog.forDefaults(defaults)
        // template wins over history
        _ = catalog.setColorHistory(["Work": "#111111"])
        _ = catalog.setTemplates([EventTypeTemplate(title: "Work", colorHex: "#222222")])
        XCTAssertEqual(EventTypeTemplateStore.colorHex(for: "Work", defaults: defaults), "#222222")
        // history wins over default when no template
        _ = catalog.setTemplates([])
        XCTAssertEqual(EventTypeTemplateStore.colorHex(for: "Work", defaults: defaults), "#111111")
        // default when neither
        XCTAssertEqual(EventTypeTemplateStore.colorHex(for: "Nope", defaults: defaults),
                       EventTypeTemplateStore.defaultColorHex(for: "Nope"))
    }

    // MARK: - C(ii): effort-opacity overload + hoist

    private func alpha(of color: Color) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return a
    }

    private func withStandardEffortOpacity(_ enabled: Bool, _ body: () -> Void) {
        let key = "calendarEffortOpacityEnabled"
        let prev = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(enabled, forKey: key)
        defer {
            if let prev { UserDefaults.standard.set(prev, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        body()
    }

    /// The overload uses the PASSED flag and reads no defaults for it: set
    /// .standard to the opposite value and confirm the argument still wins.
    func testEventColorOverloadHonorsPassedFlagNotDefaults() {
        let unlogged = Event(title: "x", type: "Study")   // base "#34C759", opaque
        withStandardEffortOpacity(true) {   // would dim if the overload re-read defaults
            let off = CalendarLayout.eventColor(for: unlogged, effortOpacityEnabled: false)
            XCTAssertEqual(alpha(of: off), 1.0, accuracy: 0.02)
        }
        withStandardEffortOpacity(false) {  // would stay full if it re-read defaults
            let on = CalendarLayout.eventColor(for: unlogged, effortOpacityEnabled: true)
            XCTAssertLessThan(alpha(of: on), 0.99)
        }
    }

    /// Behavior preservation: the no-arg convenience equals the overload fed
    /// the current default, for both setting states.
    func testEventColorConvenienceEqualsOverloadWithDefault() {
        let logged = Event(title: "y", type: "Study", colorDepth: Event.colorDepth(forEffort: 3))
        for state in [true, false] {
            withStandardEffortOpacity(state) {
                XCTAssertEqual(
                    CalendarLayout.eventColor(for: logged),
                    CalendarLayout.eventColor(for: logged,
                                              effortOpacityEnabled: Event.effortOpacityEnabledFromDefaults))
            }
        }
    }

    /// The month-day summary threads the passed flag into every descriptor,
    /// so the per-cell function no longer reads the setting (it is hoisted to
    /// the grid). Passing the flag drives the pill colors' opacity; .standard
    /// is set opposite to show it is not consulted.
    func testMonthDaySummaryThreadsEffortFlag() {
        let e = Event(title: "z", type: "Study")
        let occ = CalendarLayout.EventOccurrence(
            id: "z", event: e,
            range: Event.TimeRange(start: Date(), end: Date().addingTimeInterval(3600)))
        withStandardEffortOpacity(true) {
            let summary = calendarMonthDaySummary(
                occurrences: [occ], allDayOccurrences: [], effortOpacityEnabled: false)
            XCTAssertEqual(summary.items.count, 1)
            XCTAssertEqual(alpha(of: summary.items[0].color), 1.0, accuracy: 0.02)
        }
        withStandardEffortOpacity(false) {
            let summary = calendarMonthDaySummary(
                occurrences: [occ], allDayOccurrences: [], effortOpacityEnabled: true)
            XCTAssertLessThan(alpha(of: summary.items[0].color), 0.99)
        }
    }

    /// Probe on an injected settings source: the hoisted pattern reads the
    /// effort setting ONCE for N events (the pre-hoist path read it per color).
    func testEffortSettingReadOncePerPassPattern() {
        let counting = CountingDefaults(suiteName: "RenderReadCount-\(UUID().uuidString)")!
        counting.set(true, forKey: "calendarEffortOpacityEnabled")
        counting.readCount = 0
        let events = (0..<25).map { Event(title: "\($0)", type: "Study") }
        let flag = Event.effortOpacityEnabled(from: counting)   // ONE read
        _ = events.map { CalendarLayout.eventColor(for: $0, effortOpacityEnabled: flag) }
        XCTAssertEqual(counting.readCount, 1)
    }
}

/// Counts reads of the effort-opacity key so the hoist probe can assert one
/// read per pass. Scoped to a throwaway suite constructed by the test.
private final class CountingDefaults: UserDefaults {
    var readCount = 0
    override func object(forKey defaultName: String) -> Any? {
        if defaultName == "calendarEffortOpacityEnabled" { readCount += 1 }
        return super.object(forKey: defaultName)
    }

}
