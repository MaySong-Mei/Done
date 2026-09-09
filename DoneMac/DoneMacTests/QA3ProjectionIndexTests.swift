//
//  QA3ProjectionIndexTests.swift
//  DoneMacTests
//
//  INDEPENDENT QA round 2 — Phase 3 read-only calendar canvas.
//  Attack surfaces 1 (index incrementality under adversarial deltas),
//  4 (projection vs iOS semantics), 5 (overlapLayout mode), DST geometry.
//
//  TWO tests in this file are DELIBERATELY RED (suffix _BUGPROOF):
//    testRecurringSeriesAddedViaScopedHonestDeltaAppearsOnAllMatchingDays_BUGPROOF
//    testRecurringSeriesRemovedViaScopedHonestDeltaLeavesNoGhosts_BUGPROOF
//  Both pin the same root bug: DayKey.keys(of:) for a recurring series
//  covers only the SEED range's days, so every honest producer delta
//  (MacEventStore.add/replace/removeCalendarEvent all compute affected =
//  DayKey.keys(of:)) underclaims for a series — the L1 DayModel cache
//  keeps every other day stale. The DEBUG shadow-compare guards the
//  INDEX only (recurringIDs moves correctly), so the tripwire stays 0
//  while the canvas shows wrong days. See the QA3 findings report.
//

import XCTest
@testable import Done

@MainActor
final class QA3ProjectionIndexTests: XCTestCase {

    // MARK: - Fixtures

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func nyCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }

    // 2026-03-10 00:00 UTC (same instant the implementer suite pins).
    private let day10Start = Date(timeIntervalSince1970: 1_773_100_800)
    private var key10: DayKey { DayKey(year: 2026, month: 3, day: 10) }
    private var key11: DayKey { DayKey(year: 2026, month: 3, day: 11) }
    private var key12: DayKey { DayKey(year: 2026, month: 3, day: 12) }
    private var key15: DayKey { DayKey(year: 2026, month: 3, day: 15) }

    private func event(id: UUID = UUID(), title: String = "E",
                       dayOffset: Double = 0, hour: Double, durationHours: Double = 1,
                       kind: Event.Kind = .event) -> Event {
        let start = day10Start.addingTimeInterval(dayOffset * 86_400 + hour * 3600)
        return Event(id: id, title: title,
                     timeRanges: [.init(start: start, end: start.addingTimeInterval(durationHours * 3600))],
                     kind: kind)
    }

    private func makeProjection(bill: MacWorkBill? = nil) -> CalendarProjection {
        CalendarProjection(calendar: calendar, bill: bill ?? MacWorkBill())
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int,
                      in cal: Calendar) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// Fixture self-check: if this fails, every literal below is suspect.
    func testFixtureEpochIsMarch10UTC() {
        XCTAssertEqual(DayKey(date: day10Start, calendar: calendar), key10)
        XCTAssertEqual(calendar.startOfDay(for: day10Start), day10Start)
    }

    // MARK: - Surface 1: adversarial deltas against the incremental index

    /// changedIDs naming an id ABSENT from the truth array (a deletion):
    /// the event must vanish from every day it indexed, including a
    /// cross-midnight pair.
    func testDeletedIDDeltaRemovesEventFromBothItsDays() {
        let bill = MacWorkBill()
        let projection = makeProjection(bill: bill)
        let night = event(title: "Night", hour: 23, durationHours: 2)  // 10th 23:00 → 11th 01:00
        projection.rebuildIndex(from: [night])
        var models = projection.dayModels(for: [key10, key11], events: [night])
        XCTAssertEqual(models.map { $0.blocks.count }, [1, 1], "positive control failed: the event must render before deletion")

        projection.apply(
            CommitDelta(slot: .calendarEvents, generation: 2,
                        changedIDs: [night.id], affectedDayKeys: [key10, key11]),
            events: []
        )
        models = projection.dayModels(for: [key10, key11], events: [])
        XCTAssertEqual(models.map { $0.blocks.count }, [0, 0],
                       "a deleted id must leave no block on either day")
        XCTAssertEqual(bill.count(.indexShadowMismatches), 0,
                       "incremental removal must match the full rebuild")
    }

    /// An event MOVING between days: apply re-derives from scratch per id,
    /// so the old day must hold zero residue — including after a fresh
    /// rebuild of the old day's model (which reads the index, not the cache).
    func testMovedEventLeavesNoResidueOnOldDay() {
        let bill = MacWorkBill()
        let projection = makeProjection(bill: bill)
        let id = UUID()
        let before = event(id: id, title: "Mover", hour: 6)
        projection.rebuildIndex(from: [before])
        XCTAssertEqual(projection.dayModels(for: [key10], events: [before])[0].blocks.count, 1,
                       "positive control failed")

        let after = event(id: id, title: "Mover", dayOffset: 2, hour: 6)  // moved to the 12th
        projection.apply(
            CommitDelta(slot: .calendarEvents, generation: 2,
                        changedIDs: [id], affectedDayKeys: [key10, key12]),
            events: [after]
        )
        let models = projection.dayModels(for: [key10, key12], events: [after])
        XCTAssertEqual(models[0].blocks.count, 0, "old-day residue after a move")
        XCTAssertEqual(models[1].blocks.count, 1, "moved event missing from its new day")
        XCTAssertEqual(bill.count(.indexShadowMismatches), 0)
    }

    /// isCanvasRenderable flip in BOTH directions (absorbedIntoEventID set,
    /// then cleared) through scoped deltas.
    func testAbsorptionFlipRemovesAndRestoresTheBlock() {
        let bill = MacWorkBill()
        let projection = makeProjection(bill: bill)
        let id = UUID()
        let free = event(id: id, title: "Todo", hour: 9, kind: .todo)
        projection.rebuildIndex(from: [free])
        XCTAssertEqual(projection.dayModels(for: [key10], events: [free])[0].blocks.count, 1,
                       "positive control failed")

        var absorbed = free
        absorbed.absorbedIntoEventID = UUID()
        XCTAssertFalse(absorbed.isCanvasRenderable, "fixture self-check")
        projection.apply(
            CommitDelta(slot: .calendarEvents, generation: 2,
                        changedIDs: [id], affectedDayKeys: [key10]),
            events: [absorbed]
        )
        XCTAssertEqual(projection.dayModels(for: [key10], events: [absorbed])[0].blocks.count, 0,
                       "an absorbed todo must vanish from the canvas")

        projection.apply(
            CommitDelta(slot: .calendarEvents, generation: 3,
                        changedIDs: [id], affectedDayKeys: [key10]),
            events: [free]
        )
        XCTAssertEqual(projection.dayModels(for: [key10], events: [free])[0].blocks.count, 1,
                       "clearing absorption must restore the block")
        XCTAssertEqual(bill.count(.indexShadowMismatches), 0)
    }

    /// Bucket movement single↔series works when invalidation is not the
    /// variable: BULK deltas (affected = nil) drop the whole cache, so any
    /// residual failure would be the index buckets themselves. This is the
    /// positive control that convicts INVALIDATION (not expansion) in the
    /// two _BUGPROOF tests below.
    func testRecurringFlipViaBulkDeltaMovesBucketsBothWays() {
        let bill = MacWorkBill()
        let projection = makeProjection(bill: bill)
        let id = UUID()
        let single = event(id: id, title: "Flip", hour: 8)
        projection.rebuildIndex(from: [single])
        XCTAssertEqual(projection.dayModels(for: [key10, key11, key12], events: [single]).map { $0.blocks.count },
                       [1, 0, 0], "positive control failed")

        var series = single
        series.repeatUnit = .day
        XCTAssertTrue(series.isRecurringSeries, "fixture self-check")
        projection.apply(
            CommitDelta(slot: .calendarEvents, generation: 2,
                        changedIDs: [id], affectedDayKeys: nil),
            events: [series]
        )
        XCTAssertEqual(projection.dayModels(for: [key10, key11, key12], events: [series]).map { $0.blocks.count },
                       [1, 1, 1], "single→series flip via bulk delta must expand everywhere")

        projection.apply(
            CommitDelta(slot: .calendarEvents, generation: 3,
                        changedIDs: [id], affectedDayKeys: nil),
            events: [single]
        )
        XCTAssertEqual(projection.dayModels(for: [key10, key11, key12], events: [single]).map { $0.blocks.count },
                       [1, 0, 0], "series→single flip via bulk delta must collapse back to the seed day")
        XCTAssertEqual(bill.count(.indexShadowMismatches), 0)
    }

    /// Was DELIBERATELY RED (round-2 blocker F2: an honest producer once
    /// emitted seed-day-only deltas for a series and the cache went stale).
    /// Adjudicated fixes, both pinned here: (a) MacEventStore now emits
    /// BULK for anything recurring (see QA3SurfaceWindowTests store-level
    /// test), so this scoped delta models a LYING caller; (b) the DEBUG
    /// cache shadow-compare catches the lie, trips the counter, and heals
    /// the stale days. Expected [1,1,1] WITH mismatches — never a silent
    /// wrong canvas.
    func testRecurringSeriesViaLyingScopedDeltaIsCaughtByTheCacheShadow() {
        let bill = MacWorkBill()
        let projection = makeProjection(bill: bill)
        projection.rebuildIndex(from: [])
        // Prime the cache: all three days cached empty, as after activate().
        XCTAssertEqual(projection.dayModels(for: [key10, key11, key12], events: []).map { $0.blocks.count },
                       [0, 0, 0])

        var series = event(title: "Daily", hour: 8)
        series.repeatUnit = .day
        XCTAssertEqual(DayKey.keys(of: series, calendar: calendar), [key10],
                       "raw keys(of:) is still seed-only — the honesty now lives in the store's affectedKeys(touching:), which overrides to nil for series")

        projection.apply(
            CommitDelta(slot: .calendarEvents, generation: 2,
                        changedIDs: [series.id], affectedDayKeys: [key10]),
            events: [series]
        )
        let counts = projection.dayModels(for: [key10, key11, key12], events: [series]).map { $0.blocks.count }
        XCTAssertGreaterThan(bill.count(.indexShadowMismatches), 0,
                             "the cache shadow must catch the underclaimed days")
        XCTAssertEqual(counts, [1, 1, 1],
                       "after the shadow heals, every matching day renders the series")
    }

    /// The removal direction of the same lie: ghosts are caught and cleared
    /// by the cache shadow (was DELIBERATELY RED pre-fix).
    func testRecurringSeriesRemovalGhostsAreCaughtByTheCacheShadow() {
        let bill = MacWorkBill()
        let projection = makeProjection(bill: bill)
        var series = event(title: "Daily", hour: 8)
        series.repeatUnit = .day
        projection.rebuildIndex(from: [series])
        XCTAssertEqual(projection.dayModels(for: [key10, key11, key12], events: [series]).map { $0.blocks.count },
                       [1, 1, 1], "positive control failed: the series must render before removal")

        projection.apply(
            CommitDelta(slot: .calendarEvents, generation: 2,
                        changedIDs: [series.id], affectedDayKeys: [key10]),
            events: []
        )
        let counts = projection.dayModels(for: [key10, key11, key12], events: []).map { $0.blocks.count }
        XCTAssertGreaterThan(bill.count(.indexShadowMismatches), 0,
                             "the cache shadow must see the ghost days")
        XCTAssertEqual(counts, [0, 0, 0],
                       "no ghost blocks survive the shadow heal")
    }

    /// Was a pinned parity gap (round-2 F6: capped spans never rendered on
    /// Mac). Adjudicated fix: nil-key events join the always-candidate
    /// `unboundedIDs` bucket, so they render on every covered day — the
    /// same over-inclusion contract as recurring series. Pins the heal
    /// against the iOS oracle.
    func testCappedSpanEventRendersViaTheUnboundedBucket() {
        let bill = MacWorkBill()
        let projection = makeProjection(bill: bill)
        let start = day10Start.addingTimeInterval(6 * 3600)
        let long = Event(id: UUID(), title: "Cursed",
                         timeRanges: [.init(start: start, end: start.addingTimeInterval(450 * 86_400))],
                         kind: .event)
        XCTAssertNil(DayKey.keys(of: long, calendar: calendar),
                     "precondition: a 450-day span must exceed the 400-step cap")

        projection.rebuildIndex(from: [long])
        let mac = projection.dayModels(for: [key15], events: [long])[0].blocks.count
        let oracle = CalendarLayout.occurrencesForDate([long], date: day10Start.addingTimeInterval(5 * 86_400), calendar: calendar).count
        XCTAssertEqual(oracle, 1, "oracle self-check: iOS layout renders the mid-span day")
        XCTAssertEqual(mac, oracle, "Mac must match the oracle on a mid-span day")

        // An incremental (even day-lying) delta keeps it a candidate and
        // the shadow stays quiet — index and rebuild agree.
        projection.apply(
            CommitDelta(slot: .calendarEvents, generation: 2,
                        changedIDs: [long.id], affectedDayKeys: [key15]),
            events: [long]
        )
        XCTAssertEqual(projection.dayModels(for: [key15], events: [long])[0].blocks.count, 1)
        XCTAssertEqual(bill.count(.indexShadowMismatches), 0)
    }

    /// Empty timeRanges: no crash, no block, on both the single and the
    /// recurring path (a series with no seed range expands nowhere).
    func testEmptyTimeRangesEventNeitherCrashesNorRenders() {
        let projection = makeProjection()
        let bare = Event(id: UUID(), title: "NoTime", timeRanges: [], kind: .todo)
        var bareSeries = Event(id: UUID(), title: "NoTimeSeries", timeRanges: [], kind: .event)
        bareSeries.repeatUnit = .day
        projection.rebuildIndex(from: [bare, bareSeries])
        let models = projection.dayModels(for: [key10, key11], events: [bare, bareSeries])
        XCTAssertEqual(models.map { $0.blocks.count }, [0, 0])
        XCTAssertEqual(models.map { $0.allDayChips.count }, [0, 0])

        // Scoped delta naming them must also be inert, not a crash.
        projection.apply(
            CommitDelta(slot: .calendarEvents, generation: 2,
                        changedIDs: [bare.id, bareSeries.id], affectedDayKeys: []),
            events: [bare, bareSeries]
        )
        XCTAssertEqual(projection.dayModels(for: [key10], events: [bare, bareSeries])[0].blocks.count, 0)
    }

    // MARK: - Surface 4: projection vs iOS semantics

    /// Was a pinned wall-clock leak (round-2 review #8 / QA3 F4: the shared
    /// layout substitutes [timerStart, max(Date(), …)] and a 1h stored
    /// event rendered 18h). Adjudicated fix: the projection neutralizes
    /// timerStartedAt before layout — Mac renders STORED ranges, the
    /// DayModel is now-free again, and index/render agree on every day.
    /// A live-timer surface (with its own clock registration) is a Phase
    /// 4+ feature, deliberately not this.
    func testTimerActiveEventRendersStoredRangesOnly() throws {
        let projection = makeProjection()
        var timed = event(title: "Timer", hour: 6, durationHours: 1)  // stored: 06:00-07:00 on the 10th
        timed.timerStartedAt = day10Start.addingTimeInterval(6 * 3600)
        projection.rebuildIndex(from: [timed])

        let day10 = projection.dayModels(for: [key10], events: [timed])[0]
        XCTAssertEqual(day10.blocks.count, 1)
        XCTAssertEqual(day10.blocks[0].yFraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(day10.blocks[0].heightFraction, 1.0 / 24.0, accuracy: 0.0001,
                       "the stored hour renders — never a Date()-decided end")

        // Day 11: index and render agree (stored range covers neither).
        let day11 = projection.dayModels(for: [key11], events: [timed])[0]
        XCTAssertEqual(day11.blocks.count, 0,
                       "index (stored ranges) and neutralized render agree on day 11")

        // The dateless-timer variant renders nowhere on Mac by the same
        // stored-ranges rule (no range, no block) — and no longer crashes
        // into a half-timer state.
        let projection2 = makeProjection()
        var dateless = Event(id: UUID(), title: "DatelessTimer", timeRanges: [], kind: .todo)
        dateless.timerStartedAt = day10Start.addingTimeInterval(6 * 3600)
        projection2.rebuildIndex(from: [dateless])
        XCTAssertEqual(projection2.dayModels(for: [key10], events: [dateless])[0].blocks.count, 0,
                       "no stored range, no block — the live-timer surface owns this case later")
    }

    /// Multi-day all-day event: a chip on EVERY covered civil day, a block
    /// on none — the all-day exclusion holds on the multi-day path too.
    func testMultiDayAllDayEventIsChipsEverywhereBlocksNowhere() {
        let projection = makeProjection()
        var span = Event(id: UUID(), title: "Retreat",
                         timeRanges: [.init(start: day10Start,
                                            end: day10Start.addingTimeInterval(3 * 86_400 - 1))],
                         kind: .event)
        span.isAllDay = true
        projection.rebuildIndex(from: [span])
        let models = projection.dayModels(for: [key10, key11, key12], events: [span])
        XCTAssertEqual(models.map { $0.allDayChips.count }, [1, 1, 1],
                       "each covered civil day carries the chip")
        XCTAssertEqual(models.map { $0.blocks.count }, [0, 0, 0],
                       "an all-day event must never surface as a timed block")
        XCTAssertEqual(models[0].allDayChips[0].title, "Retreat")
    }

    /// Recurring series with a suppressed occurrence: the shared expansion's
    /// exception day-keys are honored — [1, 0, 1] around the exception.
    func testRecurringSeriesExceptionDayRendersNothing() {
        let projection = makeProjection()
        let seed = day10Start.addingTimeInterval(8 * 3600)
        var series = Event(id: UUID(), title: "Daily",
                           timeRanges: [.init(start: seed, end: seed.addingTimeInterval(3600))],
                           kind: .event,
                           recurrenceExceptionDayKeys: [20_260_311])
        series.repeatUnit = .day
        projection.rebuildIndex(from: [series])
        let counts = projection.dayModels(for: [key10, key11, key12], events: [series]).map { $0.blocks.count }
        XCTAssertEqual(counts, [1, 0, 1],
                       "the 2026-03-11 exception must suppress exactly its own day")
    }

    // MARK: - Surface 5: overlapLayout mode through the projection

    /// Was a pinned contract skirt (round-2 review #11 / QA3 F5: .auto
    /// reached the stack-peek branch while DayBlockModel carries no
    /// coverRanges, exactly the consumer class CalendarLayout's doc says
    /// MUST pass .equalSplit). Adjudicated fix: the projection passes
    /// .equalSplit — an uneven pair column-packs, no full-width host, no
    /// text-under-sibling. There is still no API through which a drag
    /// could pass a mode into CalendarProjection (Phase 4 contract note).
    func testUnevenPairTakesEqualSplitPerTheSharedContract() throws {
        let projection = makeProjection()
        let host = event(title: "Host", hour: 9, durationHours: 6)
        let peek = event(title: "Peek", hour: 9, durationHours: 2)
        projection.rebuildIndex(from: [host, peek])
        let blocks = projection.dayModels(for: [key10], events: [host, peek])[0].blocks
        XCTAssertEqual(blocks.count, 2)
        let widths = blocks.map(\.widthFraction).sorted()
        XCTAssertEqual(widths[0], 0.5, accuracy: 0.0001,
                       "equalSplit: both members column-pack at half width")
        XCTAssertEqual(widths[1], 0.5, accuracy: 0.0001)
        let xs = blocks.map(\.xOffsetFraction).sorted()
        XCTAssertEqual(xs[0], 0, accuracy: 0.0001)
        XCTAssertEqual(xs[1], 0.5, accuracy: 0.0001)
    }

    /// Every occurrence gets a slot (overlapLayout backfills .default), so
    /// the projection's `?? .default` can't silently misplace an id: four
    /// simultaneous peers split the column exactly.
    func testEveryOverlappingOccurrenceGetsADisjointSlot() {
        let projection = makeProjection()
        let events = (0..<4).map { i in event(title: "P\(i)", hour: 9, durationHours: 1) }
        projection.rebuildIndex(from: events)
        let blocks = projection.dayModels(for: [key10], events: events)[0].blocks
        XCTAssertEqual(blocks.count, 4)
        let sorted = blocks.sorted { $0.xOffsetFraction < $1.xOffsetFraction }
        for (i, block) in sorted.enumerated() {
            XCTAssertEqual(block.xOffsetFraction, CGFloat(i) * 0.25, accuracy: 0.0001)
            XCTAssertEqual(block.widthFraction, 0.25, accuracy: 0.0001,
                           "four equal peers must each hold exactly a quarter column — a silent .default fallback would show width 1.0")
        }
    }

    // MARK: - Surface 2 control: L1 cache equivalence on the honest paths

    /// Positive control for the cache-staleness zero-findings on
    /// NON-recurring paths: after a chain of honest scoped deltas
    /// (add, move, remove), the incrementally maintained cache must equal a
    /// from-scratch projection over the same truth. (The recurring paths
    /// FAIL the analogous check — see the _BUGPROOF tests.)
    func testCacheEquivalenceControlAfterHonestScopedDeltaChain() {
        let projection = makeProjection()
        let a = event(title: "A", hour: 6)
        let bID = UUID()
        let b0 = event(id: bID, title: "B", hour: 9)
        projection.rebuildIndex(from: [a, b0])
        _ = projection.dayModels(for: [key10, key11, key12], events: [a, b0])

        // Move B to the 11th.
        let b1 = event(id: bID, title: "B", dayOffset: 1, hour: 9)
        projection.apply(
            CommitDelta(slot: .calendarEvents, generation: 2, changedIDs: [bID],
                        affectedDayKeys: [key10, key11]),
            events: [a, b1]
        )
        // Remove A.
        projection.apply(
            CommitDelta(slot: .calendarEvents, generation: 3, changedIDs: [a.id],
                        affectedDayKeys: [key10]),
            events: [b1]
        )
        let incremental = projection.dayModels(for: [key10, key11, key12], events: [b1])

        let fresh = makeProjection()
        fresh.rebuildIndex(from: [b1])
        let rebuilt = fresh.dayModels(for: [key10, key11, key12], events: [b1])
        XCTAssertEqual(incremental, rebuilt,
                       "incrementally maintained day models must equal a from-scratch build")
        XCTAssertEqual(incremental.map { $0.blocks.count }, [0, 1, 0])
    }

    // MARK: - DST geometry (America/New_York)

    /// Spring forward 2026-03-08 (23h civil day): geometry is ABSOLUTE
    /// seconds over a fixed 24h window anchored at startOfDay. Hand-computed:
    /// noon EDT is 11 absolute hours after 00:00 EST, so block AND now-line
    /// sit at 11/24 — they agree with each other (no internal skew), and
    /// they sit one gridline above the civil hour. Same shared math as iOS.
    func testSpringForwardDayBlockAndNowLineShareTheAbsoluteFrame() {
        let cal = nyCalendar()
        let projection = CalendarProjection(calendar: cal, bill: MacWorkBill())
        let noon = date(2026, 3, 8, 12, 0, in: cal)
        let block = Event(id: UUID(), title: "Noon",
                          timeRanges: [.init(start: noon, end: noon.addingTimeInterval(3600))],
                          kind: .event)
        projection.rebuildIndex(from: [block])
        let key = DayKey(year: 2026, month: 3, day: 8)
        let model = projection.dayModels(for: [key], events: [block])[0]
        XCTAssertEqual(model.blocks.count, 1)
        XCTAssertEqual(model.blocks[0].yFraction, 11.0 / 24.0, accuracy: 0.0001,
                       "noon on the 23h day = 11 absolute hours from midnight EST")
        XCTAssertEqual(model.blocks[0].heightFraction, 1.0 / 24.0, accuracy: 0.0001)

        let line = projection.nowLine(now: noon)
        XCTAssertEqual(line.dayKey, key)
        XCTAssertEqual(line.yFraction, 11.0 / 24.0, accuracy: 0.0001,
                       "now-line and block use the same absolute frame — no skew between them")
    }

    /// Fall back 2026-11-01 (25h civil day): noon EST = 13 absolute hours →
    /// 13/24; and the last civil hour lies BEYOND the 24h window — yFraction
    /// clamps to 1.0, so a 23:30 EST block pins to the bottom edge (drawn
    /// height 1/96 below the clip). Inherited from the shared 24h-window
    /// contract, pinned here so the Mac canvas's behavior is on record.
    func testFallBackDayNoonAndLateBlockGeometry() throws {
        let cal = nyCalendar()
        let projection = CalendarProjection(calendar: cal, bill: MacWorkBill())
        let noon = date(2026, 11, 1, 12, 0, in: cal)  // EST, post-transition
        let late = date(2026, 11, 1, 23, 30, in: cal)
        let noonBlock = Event(id: UUID(), title: "Noon",
                              timeRanges: [.init(start: noon, end: noon.addingTimeInterval(3600))],
                              kind: .event)
        let lateBlock = Event(id: UUID(), title: "Late",
                              timeRanges: [.init(start: late, end: late.addingTimeInterval(900))],
                              kind: .event)
        projection.rebuildIndex(from: [noonBlock, lateBlock])
        let key = DayKey(year: 2026, month: 11, day: 1)
        let model = projection.dayModels(for: [key], events: [noonBlock, lateBlock])[0]
        XCTAssertEqual(model.blocks.count, 2)
        let noonB = try XCTUnwrap(model.blocks.first { $0.title == "Noon" })
        let lateB = try XCTUnwrap(model.blocks.first { $0.title == "Late" })
        XCTAssertEqual(noonB.yFraction, 13.0 / 24.0, accuracy: 0.0001,
                       "noon on the 25h day = 13 absolute hours from midnight EDT")
        XCTAssertEqual(lateB.yFraction, 1.0, accuracy: 0.0001,
                       "PINNED: 23:30 EST is 24.5 absolute hours in — clamped to the bottom edge (25h-day tail is not representable in the 24h window)")
        XCTAssertEqual(lateB.heightFraction, 1.0 / 96.0, accuracy: 0.0001)
    }
}
