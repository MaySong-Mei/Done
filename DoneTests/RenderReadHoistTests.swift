import XCTest
@testable import Done

/// gh#219 slices D and E — pins for the per-pass hoists: header-date computed
/// once, `CalendarAnnotations.annotations` pure overload, and the TimeAxis
/// 1Hz-body loop-invariant hoists.
final class RenderReadHoistTests: XCTestCase {

    private func utcGregorian() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// A date this calendar year that carries at least one TOGGLE-GATED
    /// annotation (solar term or Gregorian holiday), found data-agnostically
    /// so the equivalence/gating pins below have something to gate on.
    private func gatedProbeDate(_ cal: Calendar) -> Date {
        let yearStart = cal.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        for off in 0..<366 {
            let d = cal.date(byAdding: .day, value: off, to: yearStart)!
            if !CalendarAnnotations.annotations(
                on: d, solarTermsEnabled: true, gregorianHolidaysEnabled: true,
                anniversaries: [], calendar: cal).isEmpty {
                return d
            }
        }
        return yearStart
    }

    // MARK: - D: CalendarAnnotations pure overload

    /// The reading convenience delegates to the overload fed the current
    /// sources — byte-identical result. (No UserDefaults mutation: it reads
    /// whatever the sources currently are.)
    func testAnnotationsConvenienceEqualsOverloadWithCurrentSources() {
        let cal = utcGregorian()
        let date = gatedProbeDate(cal)
        let reading = CalendarAnnotations.annotations(on: date, calendar: cal)
        let overload = CalendarAnnotations.annotations(
            on: date,
            solarTermsEnabled: CalendarAnnotations.solarTermsEnabled,
            gregorianHolidaysEnabled: CalendarAnnotations.gregorianHolidaysEnabled,
            anniversaries: CustomAnniversaryStore.load(),
            calendar: cal)
        XCTAssertEqual(reading.map(\.id), overload.map(\.id))
    }

    /// Both toggles gate: a probe date with a gated annotation yields it when
    /// enabled and nothing (no gated items, no anniversaries) when disabled.
    func testAnnotationsOverloadTogglesGateGatedSets() {
        let cal = utcGregorian()
        let date = gatedProbeDate(cal)
        let on = CalendarAnnotations.annotations(
            on: date, solarTermsEnabled: true, gregorianHolidaysEnabled: true,
            anniversaries: [], calendar: cal)
        let off = CalendarAnnotations.annotations(
            on: date, solarTermsEnabled: false, gregorianHolidaysEnabled: false,
            anniversaries: [], calendar: cal)
        XCTAssertFalse(on.isEmpty, "probe date should carry a gated annotation")
        XCTAssertTrue(off.isEmpty, "both toggles off suppresses every gated set")
    }

    /// The anniversary rung is a yearly month/day match, comes first, and is
    /// NOT gated by the two display toggles.
    func testAnnotationsOverloadIncludesAnniversaryUngated() {
        let cal = utcGregorian()
        let date = cal.date(from: DateComponents(year: 2026, month: 6, day: 15))!
        let anni = CustomAnniversary(
            title: "Bday",
            date: cal.date(from: DateComponents(year: 1990, month: 6, day: 15))!)
        let out = CalendarAnnotations.annotations(
            on: date, solarTermsEnabled: false, gregorianHolidaysEnabled: false,
            anniversaries: [anni], calendar: cal)
        XCTAssertEqual(out.map(\.title), ["Bday"])
        XCTAssertEqual(out.first?.kind, .anniversary)
    }

    // MARK: - D: header display date computed once

    /// `calendarResolvedHeaderDisplayDate` is deterministic for fixed inputs,
    /// which is what makes computing it once and threading the result
    /// byte-identical to the old compute-it-twice (once for the header, once
    /// re-entered through the subtitle). The refactor additionally removes the
    /// two-`Date()` midnight-straddle race the double compute could hit.
    func testResolvedHeaderDisplayDateIsDeterministicForFixedInputs() {
        let cal = utcGregorian()
        let ref = cal.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 9))!
        func compute() -> Date {
            calendarResolvedHeaderDisplayDate(
                selectedDayOffset: 0,
                rangeMode: .day,
                currentScrollY: 120,
                headerHeight: 44,
                hourHeight: 60,
                boundaryExtensionState: .none,
                referenceDate: ref,
                calendar: cal)
        }
        XCTAssertEqual(compute(), compute())
    }
}
