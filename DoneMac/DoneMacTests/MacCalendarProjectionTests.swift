//
//  MacCalendarProjectionTests.swift
//  DoneMacTests
//
//  Projection correctness: fractions pinned by hand-computed literals
//  (never by the function under test), delta-driven cache invalidation,
//  and the incremental-index shadow-compare tripwire.
//

import XCTest
@testable import Done

@MainActor
final class MacCalendarProjectionTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    // 2026-03-10 00:00 UTC.
    private let dayStart = Date(timeIntervalSince1970: 1_773_100_800)
    private var dayKey: DayKey { DayKey(year: 2026, month: 3, day: 10) }

    private func event(id: UUID = UUID(), title: String = "E",
                       hour: Double, durationHours: Double = 1,
                       kind: Event.Kind = .event) -> Event {
        let start = dayStart.addingTimeInterval(hour * 3600)
        return Event(id: id, title: title,
                     timeRanges: [.init(start: start, end: start.addingTimeInterval(durationHours * 3600))],
                     kind: kind)
    }

    private func makeProjection(bill: MacWorkBill? = nil) -> CalendarProjection {
        CalendarProjection(calendar: calendar, bill: bill ?? MacWorkBill())
    }

    // MARK: - Fraction literals

    func testSingleEventFractionsAreLiteral() {
        let projection = makeProjection()
        let events = [event(title: "Six", hour: 6, durationHours: 2)]
        projection.rebuildIndex(from: events)
        let models = projection.dayModels(for: [dayKey], events: events)
        XCTAssertEqual(models.count, 1)
        let block = models[0].blocks.first
        // 6:00 of a 24h window = 0.25; 2h = 1/12 — hand-computed, not
        // derived from calendarTimelineYFraction (the shared-function trap).
        XCTAssertEqual(block?.yFraction ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(block?.heightFraction ?? -1, 1.0 / 12.0, accuracy: 0.0001)
        XCTAssertEqual(block?.xOffsetFraction, 0)
        XCTAssertEqual(block?.widthFraction, 1)
        XCTAssertEqual(block?.timeText, "6:00")
    }

    /// B2/F1: a cross-midnight event's clipped edges are marked NOT-real, so
    /// the canvas won't offer a resize handle at a midnight clip line (which
    /// would relocate the real start/end into the wrong day).
    func testStraddleEdgeRealnessFlags() {
        let day1 = DayKey(year: 2026, month: 3, day: 11)
        let projection = makeProjection()
        let events = [event(title: "Overnight", hour: 22, durationHours: 5)]  // 22:00 d10 → 03:00 d11
        projection.rebuildIndex(from: events)
        let models = projection.dayModels(for: [dayKey, day1], events: events)
        let head = models[0].blocks.first
        let tail = models[1].blocks.first
        XCTAssertEqual(head?.topIsRealStart, true, "head top is the real 22:00 start")
        XCTAssertEqual(head?.bottomIsRealEnd, false, "head bottom is a midnight clip, not the real end")
        XCTAssertEqual(tail?.topIsRealStart, false, "tail top is a midnight clip, not the real start")
        XCTAssertEqual(tail?.bottomIsRealEnd, true, "tail bottom is the real 03:00 end")

        // A single-day event has both real edges.
        let plain = [event(title: "Noon", hour: 12, durationHours: 1)]
        projection.rebuildIndex(from: plain)
        let block = projection.dayModels(for: [dayKey], events: plain)[0].blocks.first
        XCTAssertEqual(block?.topIsRealStart, true)
        XCTAssertEqual(block?.bottomIsRealEnd, true)
    }

    func testOverlappingPairSharesTheColumnWithoutXOverlap() {
        let projection = makeProjection()
        let events = [
            event(title: "A", hour: 9, durationHours: 2),
            event(title: "B", hour: 9.5, durationHours: 2),
        ]
        projection.rebuildIndex(from: events)
        let blocks = projection.dayModels(for: [dayKey], events: events)[0].blocks
        XCTAssertEqual(blocks.count, 2)
        // Structural facts, not mirrored math: both present, x-ranges
        // disjoint, together spanning the column.
        let sorted = blocks.sorted { $0.xOffsetFraction < $1.xOffsetFraction }
        XCTAssertEqual(sorted[0].xOffsetFraction, 0, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(sorted[1].xOffsetFraction + 0.0001,
                                    sorted[0].xOffsetFraction + sorted[0].widthFraction)
        XCTAssertEqual(sorted[1].xOffsetFraction + sorted[1].widthFraction, 1, accuracy: 0.0001)
    }

    func testAllDayEventBecomesChipNotBlock() {
        let projection = makeProjection()
        var allDay = event(title: "AllDay", hour: 0, durationHours: 24)
        allDay.isAllDay = true
        let events = [allDay]
        projection.rebuildIndex(from: events)
        let model = projection.dayModels(for: [dayKey], events: events)[0]
        XCTAssertEqual(model.blocks.count, 0)
        XCTAssertEqual(model.allDayChips.map(\.title), ["AllDay"])
    }

    func testRecurringSeriesExpandsOnMatchingDaysOnly() {
        let projection = makeProjection()
        var series = event(title: "Daily", hour: 8)
        series.repeatUnit = .day
        series.repeatInterval = 2
        let events = [series]
        projection.rebuildIndex(from: events)
        let day0 = dayKey
        let day1 = DayKey(year: 2026, month: 3, day: 11)
        let day2 = DayKey(year: 2026, month: 3, day: 12)
        let models = projection.dayModels(for: [day0, day1, day2], events: events)
        XCTAssertEqual(models.map { $0.blocks.count }, [1, 0, 1],
                       "an every-2-days series must appear on day 0 and 2, not day 1")
    }

    // MARK: - Cache behavior

    func testSecondQueryIsAllHitsAndDeltaDropsOnlyAffectedDays() {
        let bill = MacWorkBill()
        let projection = makeProjection(bill: bill)
        let a = event(title: "A", hour: 6)
        let day1 = DayKey(year: 2026, month: 3, day: 11)
        var events = [a]
        projection.rebuildIndex(from: events)

        _ = projection.dayModels(for: [dayKey, day1], events: events)
        XCTAssertEqual(bill.count(.dayModelBuilds), 2)
        _ = projection.dayModels(for: [dayKey, day1], events: events)
        XCTAssertEqual(bill.count(.dayModelBuilds), 2, "cached days must not rebuild")

        // A commit touching only day 0 leaves day 1 cached.
        let b = event(title: "B", hour: 10)
        events.append(b)
        projection.apply(
            CommitDelta(slot: .calendarEvents, generation: 2,
                        changedIDs: [b.id], affectedDayKeys: [dayKey]),
            events: events
        )
        _ = projection.dayModels(for: [dayKey, day1], events: events)
        XCTAssertEqual(bill.count(.dayModelBuilds), 3,
                       "only the affected day rebuilds after a scoped delta")
        XCTAssertEqual(bill.count(.indexShadowMismatches), 0,
                       "the incremental index must match the full rebuild")
    }

    func testBulkDeltaRebuildsEverything() {
        let bill = MacWorkBill()
        let projection = makeProjection(bill: bill)
        var events = [event(title: "A", hour: 6)]
        projection.rebuildIndex(from: events)
        _ = projection.dayModels(for: [dayKey], events: events)
        XCTAssertEqual(bill.count(.dayModelBuilds), 1)

        events.append(event(title: "B", hour: 7))
        projection.apply(
            CommitDelta(slot: .calendarEvents, generation: 2,
                        changedIDs: [events[1].id], affectedDayKeys: nil),
            events: events
        )
        let model = projection.dayModels(for: [dayKey], events: events)[0]
        XCTAssertEqual(model.blocks.count, 2, "a bulk delta must not leave a stale cache behind")
        XCTAssertEqual(bill.count(.dayModelBuilds), 2)
    }

    func testCrossMidnightEventAppearsClippedOnBothDays() {
        let projection = makeProjection()
        let events = [event(title: "Night", hour: 23, durationHours: 2)]
        projection.rebuildIndex(from: events)
        let day1 = DayKey(year: 2026, month: 3, day: 11)
        let models = projection.dayModels(for: [dayKey, day1], events: events)
        XCTAssertEqual(models[0].blocks.count, 1)
        XCTAssertEqual(models[1].blocks.count, 1, "the tail must render on the next civil day")
        // Day-0 tail: starts 23:00 (fraction 23/24), clipped height 1h.
        XCTAssertEqual(models[0].blocks[0].yFraction, 23.0 / 24.0, accuracy: 0.0001)
        XCTAssertEqual(models[0].blocks[0].heightFraction, 1.0 / 24.0, accuracy: 0.0001)
        // Day-1 head: starts at the clip (midnight), 1h remaining.
        XCTAssertEqual(models[1].blocks[0].yFraction, 0, accuracy: 0.0001)
    }

    // MARK: - Now overlay

    func testNowLineIsMinuteFractionOfTheDay() {
        let projection = makeProjection()
        let now = dayStart.addingTimeInterval(12 * 3600)  // noon
        let line = projection.nowLine(now: now)
        XCTAssertEqual(line.dayKey, dayKey)
        XCTAssertEqual(line.yFraction, 0.5, accuracy: 0.0001)
    }
}
