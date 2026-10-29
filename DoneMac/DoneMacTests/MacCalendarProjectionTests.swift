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
        XCTAssertEqual(block?.timeText(is24: true), "6:00 - 8:00")
    }

    /// The phone's 12h block text ("h:mm a", lowercase am/pm), and the
    /// 24h text past noon — picked by the synced clock setting at draw time.
    func testTimeTextInBothClockStyles() {
        let projection = makeProjection()
        let events = [event(hour: 15, durationHours: 1.5)]
        projection.rebuildIndex(from: events)
        let block = projection.dayModels(for: [dayKey], events: events)[0].blocks.first
        XCTAssertEqual(block?.timeText(is24: true), "15:00 - 16:30")
        XCTAssertEqual(block?.timeText(is24: false), "3:00 pm - 4:30 pm")
    }

    /// The block's style inputs reach the model from the event, not
    /// defaults: each is set to a non-default value and read back.
    func testStyleInputsPassThrough() {
        let deadline = dayStart.addingTimeInterval(20 * 3600)
        var interrupt = event(hour: 9)
        interrupt.displayKind = .interrupt
        interrupt.colorDepth = 0.6
        var todo = event(hour: 12, kind: .todo)
        todo.deadline = deadline
        let plain = event(hour: 15)
        let events = [interrupt, todo, plain]
        let projection = makeProjection()
        projection.rebuildIndex(from: events)
        let blocks = projection.dayModels(for: [dayKey], events: events)[0].blocks
        let byID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.eventID, $0) })
        XCTAssertEqual(byID[interrupt.id]?.isInterrupt, true)
        XCTAssertEqual(byID[interrupt.id]?.colorDepth ?? -1, 0.6, accuracy: 0.0001)
        XCTAssertEqual(byID[todo.id]?.deadline, deadline)
        XCTAssertEqual(byID[plain.id]?.isInterrupt, false)
        XCTAssertNil(byID[plain.id]?.deadline)
    }

    /// An embedded interrupt child takes its parent's column one z above it;
    /// the parent carries the child's range and its own day-clipped range.
    /// A detached interrupt is a plain block.
    func testEmbeddedInterruptFamily() {
        let parent = event(hour: 9, durationHours: 3)
        let other = event(hour: 9, durationHours: 3)
        var child = event(hour: 10)
        child.displayKind = .interrupt
        child.interruptRelation = EventInterruptRelation(parentEventID: parent.id, occurrenceDate: dayStart)
        var detached = event(hour: 15)
        detached.displayKind = .interrupt
        detached.interruptRelation = EventInterruptRelation(parentEventID: parent.id, occurrenceDate: dayStart,
                                                            state: .detached)
        let events = [parent, other, child, detached]
        let projection = makeProjection()
        projection.rebuildIndex(from: events)
        let blocks = projection.dayModels(for: [dayKey], events: events)[0].blocks
        let byID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.eventID, $0) })
        let p = byID[parent.id]!, c = byID[child.id]!, d = byID[detached.id]!
        XCTAssertTrue(c.isEmbeddedInterruptChild)
        XCTAssertEqual(c.xOffsetFraction, p.xOffsetFraction)
        XCTAssertEqual(c.widthFraction, p.widthFraction)
        // The child takes no column: parent and `other` split the hour in two.
        XCTAssertEqual(p.widthFraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(byID[other.id]!.widthFraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(c.zIndex, p.zIndex + 1)
        XCTAssertEqual(p.interruptChildRanges, [child.timeRanges[0]])
        XCTAssertEqual(p.compoundParentRange, parent.timeRanges[0])
        XCTAssertFalse(p.isEmbeddedInterruptChild)
        XCTAssertFalse(d.isEmbeddedInterruptChild)
        XCTAssertTrue(byID[other.id]!.interruptChildRanges.isEmpty)
        XCTAssertNil(byID[other.id]!.compoundParentRange)
    }

    /// A parent alone with its embedded child keeps the whole column.
    func testLoneInterruptParentKeepsFullWidth() {
        let parent = event(hour: 9, durationHours: 3)
        var child = event(hour: 10)
        child.displayKind = .interrupt
        child.interruptRelation = EventInterruptRelation(parentEventID: parent.id, occurrenceDate: dayStart)
        let events = [parent, child]
        let projection = makeProjection()
        projection.rebuildIndex(from: events)
        let blocks = projection.dayModels(for: [dayKey], events: events)[0].blocks
        XCTAssertEqual(blocks.count, 2)
        for block in blocks {
            XCTAssertEqual(block.xOffsetFraction, 0)
            XCTAssertEqual(block.widthFraction, 1)
        }
    }

    func testAgenticTimerAndTypeInputsPassThrough() {
        var timed = event(hour: 9)
        timed.timerStartedAt = dayStart
        timed.type = "Work"
        timed.additionalTypes = ["Study"]
        var failed = event(hour: 12)
        failed.agenticIntake = AgenticIntakeRecord(rawText: "x", source: .quickAdd, processingPhase: .failed)
        let plain = event(hour: 15)
        let events = [timed, failed, plain]
        let projection = makeProjection()
        projection.rebuildIndex(from: events)
        let blocks = projection.dayModels(for: [dayKey], events: events)[0].blocks
        let byID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.eventID, $0) })
        XCTAssertEqual(byID[timed.id]?.isTimerActive, true)
        XCTAssertEqual(byID[timed.id]?.hasAdditionalTypes, true)
        XCTAssertEqual(byID[timed.id]?.typeSubtitle, "Work · Study")
        XCTAssertEqual(byID[failed.id]?.agenticPhase, .failed)
        XCTAssertEqual(byID[plain.id]?.isTimerActive, false)
        XCTAssertEqual(byID[plain.id]?.hasAdditionalTypes, false)
        XCTAssertNil(byID[plain.id]?.agenticPhase)
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

    // MARK: - Drag-create reflow

    /// The phone's live drag-to-create layout: a draft over a block splits
    /// the column with it (literal halves), a block the draft does not
    /// touch keeps the full width, and the day cache is not rebuilt.
    func testCreationDraftSplitsTheBlocksItOverlaps() {
        let bill = MacWorkBill()
        let projection = makeProjection(bill: bill)
        let nine = event(hour: 9)
        let fifteen = event(hour: 15)
        let events = [nine, fifteen]
        projection.rebuildIndex(from: events)
        let blocks = projection.dayModels(for: [dayKey], events: events)[0].blocks
        let builds = bill.count(.dayModelBuilds)
        let draft = Event.TimeRange(start: dayStart.addingTimeInterval(9.5 * 3600),
                                    end: dayStart.addingTimeInterval(10.5 * 3600))

        guard let reflow = projection.creationReflow(for: dayKey, draft: draft, events: events) else {
            return XCTFail("no reflow")
        }
        let reseated = Dictionary(uniqueKeysWithValues: reflow.apply(to: blocks).map { ($0.eventID, $0) })
        XCTAssertEqual(reseated[nine.id]?.widthFraction ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(reflow.draftSlot.widthFraction, 0.5, accuracy: 0.0001)
        XCTAssertNotEqual(reseated[nine.id]?.xOffsetFraction, reflow.draftSlot.xOffsetFraction,
                          "the draft takes the other half, not the block's")
        XCTAssertEqual(reseated[fifteen.id]?.widthFraction, 1)
        XCTAssertEqual(reseated[fifteen.id]?.xOffsetFraction, 0)
        XCTAssertEqual(reflow.draftTimeText24, "9:30 - 10:30")
        XCTAssertEqual(reflow.draftTimeText12, "9:30 am - 10:30 am")
        XCTAssertEqual(bill.count(.dayModelBuilds), builds, "the reflow builds no day model")

        // Positive control: a draft clear of every block leaves them all whole.
        let clear = Event.TimeRange(start: dayStart.addingTimeInterval(20 * 3600),
                                    end: dayStart.addingTimeInterval(21 * 3600))
        let untouched = projection.creationReflow(for: dayKey, draft: clear, events: events)
        XCTAssertEqual(untouched?.apply(to: blocks), blocks)
        XCTAssertEqual(untouched?.draftSlot.widthFraction, 1)
    }

    /// An embedded interrupt child keeps riding its parent's column when a
    /// draft re-seats the parent.
    func testCreationDraftReseatsAnEmbeddedChildWithItsParent() {
        let parent = event(hour: 9, durationHours: 3)
        var child = event(hour: 10)
        child.displayKind = .interrupt
        child.interruptRelation = EventInterruptRelation(parentEventID: parent.id, occurrenceDate: dayStart)
        let events = [parent, child]
        let projection = makeProjection()
        projection.rebuildIndex(from: events)
        let blocks = projection.dayModels(for: [dayKey], events: events)[0].blocks
        let draft = Event.TimeRange(start: dayStart.addingTimeInterval(9 * 3600),
                                    end: dayStart.addingTimeInterval(10 * 3600))
        guard let reflow = projection.creationReflow(for: dayKey, draft: draft, events: events) else {
            return XCTFail("no reflow")
        }
        let reseated = Dictionary(uniqueKeysWithValues: reflow.apply(to: blocks).map { ($0.eventID, $0) })
        XCTAssertEqual(reseated[parent.id]?.widthFraction ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(reseated[child.id]?.widthFraction, reseated[parent.id]?.widthFraction)
        XCTAssertEqual(reseated[child.id]?.xOffsetFraction, reseated[parent.id]?.xOffsetFraction)
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
