//
//  QATruthLayerEdgeTests.swift
//  DoneMacTests
//
//  INDEPENDENT QA — DayKey civil-day math (attack surface 4), interest
//  matching edges (surface 5), ClockHub DST/backwards/re-register edges
//  (surface 7).
//
//  One test in this file is DELIBERATELY RED:
//    testDayKeySpanBeyond400DaysMustNotDropMiddleDays_BUGPROOF
//  It asserts the documented contract of DayKey.keys(spanning:) ("Every
//  civil day a time range touches, endpoints inclusive") against the
//  400-step cap, which silently drops days 400..<end and then force-inserts
//  the end key — producing a delta that CLAIMS completeness while missing
//  days. See the QA findings report.
//

import XCTest
@testable import Done

@MainActor
final class QATruthLayerEdgeTests: XCTestCase {

    private func calendar(_ tzID: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tzID)!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int,
                      in cal: Calendar) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: - DayKey across DST (positive controls for the civil-day walk)

    /// America/Santiago 2023-09-03 had NO midnight (24:00 Sat -> 01:00 Sun,
    /// tzdata history — a past date, so stable). The walk must still emit
    /// every civil day. This is the positive control that makes the DST
    /// zero-finding meaningful.
    func testDayKeysSantiagoNoMidnightDayAllCivilDaysPresent() {
        let cal = calendar("America/Santiago")
        // Precondition self-check: the transition day starts at 01:00.
        let sep3 = date(2023, 9, 3, 12, 0, in: cal)
        XCTAssertEqual(cal.component(.hour, from: cal.startOfDay(for: sep3)), 1,
                       "precondition: 2023-09-03 Santiago must have no midnight; if this fails the fixture, not the code, is wrong")

        let range = Event.TimeRange(start: date(2023, 9, 2, 12, 0, in: cal),
                                    end: date(2023, 9, 5, 12, 0, in: cal))
        let keys = DayKey.keys(spanning: range, calendar: cal)
        XCTAssertEqual(keys, [
            DayKey(year: 2023, month: 9, day: 2),
            DayKey(year: 2023, month: 9, day: 3),
            DayKey(year: 2023, month: 9, day: 4),
            DayKey(year: 2023, month: 9, day: 5),
        ], "a no-midnight day must not be skipped or doubled by the walk")
    }

    /// America/New_York spring forward 2023-03-12 (23h day): every civil
    /// day present, none doubled.
    func testDayKeysNewYorkSpringForwardSpan() {
        let cal = calendar("America/New_York")
        let range = Event.TimeRange(start: date(2023, 3, 11, 22, 0, in: cal),
                                    end: date(2023, 3, 13, 1, 0, in: cal))
        let keys = DayKey.keys(spanning: range, calendar: cal)
        XCTAssertEqual(keys, [
            DayKey(year: 2023, month: 3, day: 11),
            DayKey(year: 2023, month: 3, day: 12),
            DayKey(year: 2023, month: 3, day: 13),
        ])
    }

    /// Documented: the end day is included even when the range ends exactly
    /// at midnight (deliberate over-invalidation).
    func testDayKeysRangeEndingExactlyAtMidnightIncludesEndDay() {
        let cal = calendar("UTC")
        let range = Event.TimeRange(start: date(2026, 5, 1, 23, 0, in: cal),
                                    end: date(2026, 5, 2, 0, 0, in: cal))
        let keys = DayKey.keys(spanning: range, calendar: cal)
        XCTAssertEqual(keys, [DayKey(year: 2026, month: 5, day: 1),
                              DayKey(year: 2026, month: 5, day: 2)],
                       "midnight-exact end must still claim the end day — over-invalidating is the documented safe direction")
    }

    /// PIN of current behavior (QA finding, MINOR): an inverted range
    /// (end < start, decoded garbage) claims ONLY the start day. The doc
    /// says "endpoints inclusive"; the end day is dropped here. Recorded
    /// as a pin, not a red test, because the input is out-of-model.
    func testDayKeysInvertedRangePinsStartDayOnly() {
        let cal = calendar("UTC")
        let range = Event.TimeRange(start: date(2026, 5, 10, 12, 0, in: cal),
                                    end: date(2026, 5, 8, 12, 0, in: cal))
        let keys = DayKey.keys(spanning: range, calendar: cal)
        XCTAssertEqual(keys, [DayKey(year: 2026, month: 5, day: 10)],
                       "PINS CURRENT BEHAVIOR: inverted range claims only the start day (end day silently absent) — see QA findings")
    }

    /// Was DELIBERATELY RED (QA round 1 finding #1: the 400-step cap dropped
    /// days 400..449 while claiming completeness). Adjudicated fix: a capped
    /// walk degrades to nil — the documented bulk semantics — so a truncated
    /// span over-invalidates instead of lying. This now pins the fixed
    /// contract: never a confident 401-key set for a 451-day span.
    func testDayKeySpanBeyond400DaysDegradesToBulkNotSilentTruncation() {
        let cal = calendar("UTC")
        let start = date(2026, 1, 1, 0, 30, in: cal)
        let range = Event.TimeRange(start: start,
                                    end: start.addingTimeInterval(450 * 86_400))
        XCTAssertNil(DayKey.keys(spanning: range, calendar: cal),
                     "a span beyond the bounded walk must be nil (bulk) — a day-scoped observer of day 425 then hears the commit via the bulk path")
        // Positive control: a 399-day span stays exact.
        let exact = Event.TimeRange(start: start,
                                    end: start.addingTimeInterval(398 * 86_400))
        XCTAssertEqual(DayKey.keys(spanning: exact, calendar: cal)?.count, 399)
    }

    // MARK: - Interest matching edges (surface 5)

    private func delta(slot: StorageSlot = .calendarEvents,
                       affected: Set<DayKey>?) -> CommitDelta {
        CommitDelta(slot: slot, generation: 1, changedIDs: [UUID()],
                    affectedDayKeys: affected)
    }

    func testEmptySlotsInterestMatchesNothingIncludingBulk() {
        let interest = StoreInterest(slots: [])
        XCTAssertFalse(interest.matches(delta(affected: nil)),
                       "an interest in zero slots must not hear bulk deltas")
        XCTAssertFalse(interest.matches(delta(affected: [DayKey(year: 2026, month: 1, day: 1)])))
    }

    func testEmptyDayKeySetHearsNoScopedDeltaButStillHearsBulk() {
        let interest = StoreInterest(slots: [.calendarEvents], dayKeys: [])
        XCTAssertFalse(interest.matches(delta(affected: [DayKey(year: 2026, month: 1, day: 1)])),
                       "empty dayKeys is disjoint from everything scoped")
        // PIN (QA finding, NOTE): a non-nil-but-empty dayKeys interest
        // still receives BULK deltas — over-notification, safe direction,
        // but "interested in zero days" reaching everyone is worth a record.
        XCTAssertTrue(interest.matches(delta(affected: nil)),
                      "PINS CURRENT BEHAVIOR: empty (non-nil) dayKeys still hears bulk deltas")
    }

    func testEmptyAffectedDayKeysReachesOnlyAllDayObservers() {
        // A commit touching an event with no timeRanges emits affected == []
        // (non-nil). Scoped observers correctly hear nothing; nil-dayKeys
        // (all-days) observers still hear it.
        let scoped = StoreInterest(slots: [.calendarEvents],
                                   dayKeys: [DayKey(year: 2026, month: 1, day: 1)])
        let allDays = StoreInterest(slots: [.calendarEvents], dayKeys: nil)
        XCTAssertFalse(scoped.matches(delta(affected: [])))
        XCTAssertTrue(allDays.matches(delta(affected: [])))
    }

    // MARK: - ClockHub edges (surface 7)

    /// The 23h spring-forward day: nextBoundary(.day) must land on the next
    /// civil midnight 23h later, and the day tick must fire exactly once.
    func testClockDayBoundaryAcrossSpringForwardIs23Hours() {
        let cal = calendar("America/New_York")
        let hub = ClockHub(calendar: cal, bill: nil, drivesTimer: false)
        let dstDayStart = cal.startOfDay(for: date(2023, 3, 12, 12, 0, in: cal))
        let next = ClockGranularity.day.nextBoundary(after: dstDayStart, calendar: cal)
        XCTAssertEqual(next.timeIntervalSince(dstDayStart), 23 * 3600,
                       "2023-03-12 America/New_York is a 23h day; a naive +86400 would overshoot into Mar 13 01:00")

        var fired = 0
        hub.register(.day) { _ in fired += 1 }
        hub.pump(now: date(2023, 3, 12, 12, 0, in: cal))     // seed
        hub.pump(now: date(2023, 3, 12, 23, 30, in: cal))    // same civil day
        XCTAssertEqual(fired, 0)
        hub.pump(now: date(2023, 3, 13, 0, 30, in: cal))     // crossed
        XCTAssertEqual(fired, 1, "exactly one day tick across the 23h day")
    }

    /// Fall-back 25h day: two moments 24h apart are the SAME civil day; the
    /// day tick must NOT fire between them.
    func testClockFallBack25HourDayDoesNotDoubleFire() {
        let cal = calendar("America/New_York")
        let hub = ClockHub(calendar: cal, bill: nil, drivesTimer: false)
        var fired = 0
        hub.register(.day) { _ in fired += 1 }
        let early = date(2023, 11, 5, 0, 30, in: cal)         // before fall-back
        hub.pump(now: early)                                  // seed
        hub.pump(now: early.addingTimeInterval(24 * 3600))    // still Nov 5 (25h day)
        XCTAssertEqual(fired, 0,
                       "24 elapsed hours on the fall-back day is still the same civil day — no tick")
        hub.pump(now: date(2023, 11, 6, 0, 30, in: cal))
        XCTAssertEqual(fired, 1)
    }

    /// PIN (QA finding, NOTE): un-occluding with a clock EARLIER than the
    /// last pump fires a catch-up tick into the past bucket, and the next
    /// forward pump fires AGAIN for the same wall-clock edge. Benign under
    /// the "consumers re-derive from now" contract, but it is two ticks
    /// where zero boundaries were crossed — recorded.
    func testClockBackwardsUnoccludePinsDoubleFire() {
        let bill = MacWorkBill()
        let cal = calendar("UTC")
        let hub = ClockHub(calendar: cal, bill: bill, drivesTimer: false)
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_100 - 800_000_100.truncatingRemainder(dividingBy: 60))
        var fired = 0
        hub.register(.minute) { _ in fired += 1 }
        hub.pump(now: t0)                                 // seed at bucket B0
        hub.pump(now: t0.addingTimeInterval(120))         // B2: fires (1)
        XCTAssertEqual(fired, 1)
        hub.setOccluded(true, now: t0.addingTimeInterval(120))
        hub.setOccluded(false, now: t0.addingTimeInterval(30))   // clock went BACK
        XCTAssertEqual(fired, 2,
                       "PINS CURRENT BEHAVIOR: backwards catch-up fires into the past bucket")
        hub.pump(now: t0.addingTimeInterval(130))         // forward again: B2 differs from B0
        XCTAssertEqual(fired, 3,
                       "PINS CURRENT BEHAVIOR: the same wall-clock edge delivers a second tick after the backwards excursion")
        XCTAssertEqual(bill.count(.clockTicksWhileOccluded), 0,
                       "setOccluded(false,...) pumps while un-occluded; the tripwire must stay clean")
    }

    /// Was a QA NOTE (stale seed survived a granularity emptying and fired
    /// a phantom tick at the next consumer). Adjudicated fix: unregister
    /// drops the seed for granularities with no consumers left, so a later
    /// re-register seeds fresh. Pins the fixed seeding contract.
    func testClockReRegisterAfterGranularityEmptiedSeedsFresh() {
        let cal = calendar("UTC")
        let hub = ClockHub(calendar: cal, bill: nil, drivesTimer: false)
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_100 - 800_000_100.truncatingRemainder(dividingBy: 60))
        let a = hub.register(.minute) { _ in }
        hub.pump(now: t0)                                 // seeds .minute at B0
        hub.unregister(a)                                 // last consumer leaves; seed is dropped
        var bFired = 0
        hub.register(.minute) { _ in bFired += 1 }
        hub.pump(now: t0.addingTimeInterval(65))          // first pump after re-register: seeds only
        XCTAssertEqual(bFired, 0,
                       "no phantom tick for boundaries crossed while nobody listened")
        hub.pump(now: t0.addingTimeInterval(125))         // a real boundary after the fresh seed
        XCTAssertEqual(bFired, 1)
    }
}
