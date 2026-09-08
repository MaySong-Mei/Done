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
}
