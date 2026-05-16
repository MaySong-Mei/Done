import XCTest
@testable import Done

final class CalendarMidnightHandlerTests: XCTestCase {

    // Use UTC for arithmetic precision; the helper is timezone-agnostic
    // (callers always pass `Calendar.current`).  These tests pick UTC to
    // avoid surprises from the host machine's locale.
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!
    }

    // MARK: - CalendarMidnightHandler.daysCrossed

    func testDaysCrossedReturnsZeroWithinSameDay() {
        let yesterdayStart = date(2026, 5, 16)
        let stillSameDay = date(2026, 5, 16, 23, 59)
        XCTAssertEqual(
            CalendarMidnightHandler.daysCrossed(from: yesterdayStart, to: stillSameDay, calendar: calendar),
            0
        )
    }

    func testDaysCrossedReturnsOneAfterMidnight() {
        let yesterdayStart = date(2026, 5, 16)
        let pastMidnight = date(2026, 5, 17, 0, 1)
        XCTAssertEqual(
            CalendarMidnightHandler.daysCrossed(from: yesterdayStart, to: pastMidnight, calendar: calendar),
            1
        )
    }

    /// Backstop scenario: app was backgrounded across multiple midnights.
    /// `UIApplication.didBecomeActiveNotification` triggers a single call
    /// that must collapse N midnights into one shift, not lose any.
    func testDaysCrossedCountsAllMidnightsAcrossLongBackground() {
        let monday = date(2026, 5, 11)
        let friday = date(2026, 5, 15, 9, 30)
        XCTAssertEqual(
            CalendarMidnightHandler.daysCrossed(from: monday, to: friday, calendar: calendar),
            4
        )
    }

    /// Defensive: the wall clock can move backwards via manual time changes or
    /// DST repeats.  The helper must report a negative number rather than crash
    /// or clamp to zero — callers can decide whether to apply it.
    func testDaysCrossedReturnsNegativeWhenClockMovedBackward() {
        let later = date(2026, 5, 17)
        let earlier = date(2026, 5, 15, 12)
        XCTAssertEqual(
            CalendarMidnightHandler.daysCrossed(from: later, to: earlier, calendar: calendar),
            -2
        )
    }

    func testDaysCrossedHandlesIdenticalInstants() {
        let now = date(2026, 5, 16, 14, 30)
        let start = calendar.startOfDay(for: now)
        XCTAssertEqual(
            CalendarMidnightHandler.daysCrossed(from: start, to: now, calendar: calendar),
            0
        )
    }

    // MARK: - Regression: the bug this work fixes

    /// Locks in the failure mode that motivated the midnight handler.  Without
    /// the handler, the occurrence cache holds events for day N (filtered
    /// against day N's window) while the render-time filter compares those
    /// events against day N+1's window.  The intersection is exactly the set
    /// of events that straddle the N→N+1 midnight boundary.
    func testCacheBuiltForYesterdayThenFilteredForTodayLeavesOnlyMultiDayEvents() {
        let yesterday = date(2026, 5, 16)
        let today = date(2026, 5, 17)

        // Single-day events on each side of midnight.
        let singleDayYesterdayMorning = Event(
            title: "Yesterday 09:00",
            timeRanges: [.init(start: date(2026, 5, 16, 9), end: date(2026, 5, 16, 10))]
        )
        let singleDayYesterdayEvening = Event(
            title: "Yesterday 22:00",
            timeRanges: [.init(start: date(2026, 5, 16, 22), end: date(2026, 5, 16, 23))]
        )
        let singleDayTodayMorning = Event(
            title: "Today 09:00",
            timeRanges: [.init(start: date(2026, 5, 17, 9), end: date(2026, 5, 17, 10))]
        )
        // Multi-day event straddling midnight.
        let multiDay = Event(
            title: "Overnight 22:00 → 02:00",
            timeRanges: [.init(start: date(2026, 5, 16, 22), end: date(2026, 5, 17, 2))]
        )
        let allEvents = [
            singleDayYesterdayMorning,
            singleDayYesterdayEvening,
            singleDayTodayMorning,
            multiDay
        ]

        // Step 1 — pre-midnight cache build, anchored on yesterday.
        let cachedForYesterday = CalendarLayout.occurrencesForDate(
            allEvents, date: yesterday, calendar: calendar
        )
        let cachedEventTitles = Set(cachedForYesterday.map { $0.event.title })
        XCTAssertTrue(cachedEventTitles.contains("Yesterday 09:00"))
        XCTAssertTrue(cachedEventTitles.contains("Yesterday 22:00"))
        XCTAssertTrue(cachedEventTitles.contains("Overnight 22:00 → 02:00"))
        XCTAssertFalse(cachedEventTitles.contains("Today 09:00"))

        // Step 2 — after midnight without a cache rebuild, the render-time
        // filter compares those cached entries against today's day window.
        let visibleToday = CalendarLayout.timelineVisibleOccurrences(
            forDayOffset: 0,
            reference: today,
            calendar: calendar,
            occurrencesForOffset: { offset in
                offset == 0 ? cachedForYesterday : []
            }
        )

        let visibleTitles = Set(visibleToday.map { $0.event.title })
        XCTAssertEqual(
            visibleTitles, ["Overnight 22:00 → 02:00"],
            "Without a midnight rebuild, only events straddling the boundary survive"
        )
    }

    /// And confirms the fix: once the cache is rebuilt against the new "today"
    /// and the visible offset is shifted by -1, the user's column shows the
    /// same physical date they were looking at before midnight, with the full
    /// single-day event set intact.
    func testRebuiltCacheAtOffsetMinusOneRestoresYesterdaysFullEventSet() {
        let today = date(2026, 5, 17)

        let yesterdayMorning = Event(
            title: "Yesterday 09:00",
            timeRanges: [.init(start: date(2026, 5, 16, 9), end: date(2026, 5, 16, 10))]
        )
        let yesterdayEvening = Event(
            title: "Yesterday 22:00",
            timeRanges: [.init(start: date(2026, 5, 16, 22), end: date(2026, 5, 16, 23))]
        )
        let todayMorning = Event(
            title: "Today 09:00",
            timeRanges: [.init(start: date(2026, 5, 17, 9), end: date(2026, 5, 17, 10))]
        )
        let multiDay = Event(
            title: "Overnight 22:00 → 02:00",
            timeRanges: [.init(start: date(2026, 5, 16, 22), end: date(2026, 5, 17, 2))]
        )
        let allEvents = [yesterdayMorning, yesterdayEvening, todayMorning, multiDay]

        // Rebuild the cache with today as the new reference, populating
        // offsets -1 (yesterday) and 0 (today).
        let cache: [Int: [CalendarLayout.EventOccurrence]] = [
            -1: CalendarLayout.occurrencesForDate(allEvents, date: date(2026, 5, 16), calendar: calendar),
             0: CalendarLayout.occurrencesForDate(allEvents, date: today, calendar: calendar)
        ]

        // User was visually on yesterday's column; after the midnight shift
        // their offset became -1.  Render filter still uses live "today".
        let visible = CalendarLayout.timelineVisibleOccurrences(
            forDayOffset: -1,
            reference: today,
            calendar: calendar,
            occurrencesForOffset: { cache[$0] ?? [] }
        )

        let visibleTitles = Set(visible.map { $0.event.title })
        XCTAssertEqual(
            visibleTitles,
            ["Yesterday 09:00", "Yesterday 22:00", "Overnight 22:00 → 02:00"],
            "After the midnight shift the user's column should show yesterday's full event set"
        )
    }
}
