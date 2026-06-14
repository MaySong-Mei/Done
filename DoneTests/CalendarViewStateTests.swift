import Combine
import XCTest
@testable import Done

/// Smoke coverage for the small contract surface of `CalendarViewState`
/// retained after issue #51's split (range-mode persistence + timeline-hour
/// gate/clamp). The high-frequency `selectedDayOffset` path is exercised by
/// drag tests; this file is the bare guarantee that the persisted/clamped
/// fields keep behaving after the focus-state split.
@MainActor
final class CalendarViewStateTests: XCTestCase {

    // MARK: - Helpers

    /// Fresh isolated UserDefaults so tests don't leak into the host app's
    /// real defaults.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "CalendarViewStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    // MARK: - persistRangeMode via didSet round-trip

    func testRangeModePersistsAcrossInstancesWhenRememberEnabled() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettingsKeys.calendarRememberViewMode)

        let writer = CalendarViewState(defaults: defaults)
        writer.rangeMode = .week

        let reader = CalendarViewState(defaults: defaults)
        XCTAssertEqual(reader.rangeMode, .week,
                       "rangeMode written via didSet should restore on next instance")
    }

    // MARK: - setTimelineHourHeight gate

    func testSetTimelineHourHeightSkipsNoOpAssignments() {
        let defaults = makeDefaults()
        let state = CalendarViewState(defaults: defaults)

        let expectation = expectation(description: "objectWillChange fires exactly once")
        expectation.expectedFulfillmentCount = 1
        expectation.assertForOverFulfill = true

        var cancellables = Set<AnyCancellable>()
        state.objectWillChange
            .sink { expectation.fulfill() }
            .store(in: &cancellables)

        let target: CGFloat = 48
        state.setTimelineHourHeight(target)
        state.setTimelineHourHeight(target)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(state.timelineHourHeight, target)
    }

    // MARK: - setTimelineHourHeight clamp

    func testSetTimelineHourHeightClampsBelowMin() {
        let defaults = makeDefaults()
        let state = CalendarViewState(defaults: defaults)

        state.setTimelineHourHeight(1)
        XCTAssertEqual(state.timelineHourHeight, calendarTimelineHourHeightMin,
                       "values below min should clamp to min")
    }

    func testSetTimelineHourHeightClampsAboveMax() {
        let defaults = makeDefaults()
        let state = CalendarViewState(defaults: defaults)

        state.setTimelineHourHeight(10_000)
        XCTAssertEqual(state.timelineHourHeight, calendarTimelineHourHeightMax,
                       "values above max should clamp to max")
    }
}
