//
//  QA3SurfaceWindowTests.swift
//  DoneMacTests
//
//  INDEPENDENT QA round 2 — attack surface 3 (surface/window semantics)
//  plus end-to-end producer-honesty checks (surface 2) through the real
//  MacEventStore → CalendarSurfaceModel pipeline.
//
//  Three tests below were DELIBERATELY RED at QA time (suffix was
//  _BUGPROOF); the round-2 adjudication fixed all three and the
//  coordinator flipped them to pin the fixed contracts:
//
//  1. testOutOfWindowCommitThenShiftShowsTheEvent
//     The delta-∩-interest gate drops out-of-window deltas BEFORE
//     projection.apply, so the OccurrenceIndex never learns about the
//     commit. shift() rebuilds day models from that stale index — the
//     committed event is simply absent from the week that now shows it,
//     and no later scoped delta heals it (apply re-derives only its own
//     changedIDs). Interest scoping must gate the FRAME REBUILD only,
//     never the truth intake.
//
//  2. testAddDailySeriesThroughStoreShowsOnEveryWindowDay
//     End-to-end producer half of the projection-level recurring bug
//     (see QA3ProjectionIndexTests): MacEventStore.addCalendarEvent
//     computes affected = DayKey.keys(of:) = the SEED day for a series,
//     so all other visible (cached) days stay stale.
//
//  3. testDoubleActivateThenDeactivateStopsTheClock
//     activate() overwrites clockToken without unregistering the previous
//     handler: a second activate() leaks a minute-tick registration that
//     deactivate() can never remove — the overlay keeps updating after
//     deactivation.
//

import XCTest
@testable import Done

@MainActor
final class QA3SurfaceWindowTests: XCTestCase {

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    // 2027-01-15 08:00 UTC — same anchor instant as the implementer budget
    // suite; window = Jan 15 … Jan 21.
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Rig {
        let store: MacEventStore
        let surface: CalendarSurfaceModel
        let bill: MacWorkBill
        let clock: ClockHub
    }

    private func makeRig(calendar: Calendar? = nil, anchor: Date? = nil,
                         seed: [Event] = []) async throws -> Rig {
        let cal = calendar ?? utc
        let location = EventStorageLocation.ephemeral(id: UUID())
        do {
            let seeder = try MacPersistence(location: location)
            await seeder.submitCalendarEvents(seed, generation: 1, dominoStamp: nil)
            await seeder.flush()
        }
        let bill = MacWorkBill()
        let persistence = try MacPersistence(location: location)
        let store = MacEventStore(persistence: persistence, bill: bill, calendar: cal)
        await store.load()
        let clock = ClockHub(calendar: cal, bill: bill, drivesTimer: false)
        let surface = CalendarSurfaceModel(
            store: store, clock: clock, calendar: cal, bill: bill,
            anchor: anchor ?? t0, dayCount: 7
        )
        return Rig(store: store, surface: surface, bill: bill, clock: clock)
    }

    private func timedEvent(_ title: String, dayOffset: Int, hour: Double,
                            durationHours: Double = 1, kind: Event.Kind = .event) -> Event {
        let dayStart = utc.startOfDay(for: t0)
        let start = utc.date(byAdding: .day, value: dayOffset, to: dayStart)!
            .addingTimeInterval(hour * 3600)
        return Event(id: UUID(), title: title,
                     timeRanges: [.init(start: start, end: start.addingTimeInterval(durationHours * 3600))],
                     kind: kind)
    }

    private func blockTitles(_ frame: CanvasFrame) -> [String] {
        frame.days.flatMap { $0.blocks.map(\.title) }
    }

    // MARK: - BUGPROOF 1: out-of-window commit is dropped from truth intake

    /// Fixed contract (was red pre-fix). Commit lands 10 days out (invisible), user scrolls
    /// one week forward (day now visible) — the event must be there. The
    /// interest filter swallowed the delta before projection.apply, the
    /// index is stale, and the freshly built day model omits a committed,
    /// canvas-renderable event. Nothing heals it short of re-activation or
    /// a bulk delta.
    func testOutOfWindowCommitThenShiftShowsTheEvent() async throws {
        let rig = try await makeRig()
        rig.surface.activate(now: t0)
        XCTAssertEqual(blockTitles(rig.surface.frame), [], "positive-control precondition: empty store renders empty")

        rig.store.addCalendarEvent(timedEvent("Ghost", dayOffset: 10, hour: 10), now: t0)
        rig.surface.shift(byDays: 7, now: t0)

        XCTAssertTrue(rig.surface.windowKeys.contains(DayKey(year: 2027, month: 1, day: 25)),
                      "fixture self-check: the shifted window must contain the commit's day")
        XCTAssertTrue(blockTitles(rig.surface.frame).contains("Ghost"),
                      "a committed event must appear when its week becomes visible — the out-of-window delta never reached projection.apply, so the index is permanently stale")
    }

    /// The healthy sibling as positive control: the SAME sequence with the
    /// commit in-window renders fine — proving the red test isolates the
    /// interest gate, not the shift/rebuild machinery.
    func testInWindowCommitThenShiftKeepsCachedTruth() async throws {
        let rig = try await makeRig()
        rig.surface.activate(now: t0)
        rig.store.addCalendarEvent(timedEvent("Visible", dayOffset: 2, hour: 10), now: t0)
        XCTAssertTrue(blockTitles(rig.surface.frame).contains("Visible"), "positive control failed")
        rig.surface.shift(byDays: 7, now: t0)
        XCTAssertFalse(blockTitles(rig.surface.frame).contains("Visible"))
        rig.surface.shift(byDays: -7, now: t0)
        XCTAssertTrue(blockTitles(rig.surface.frame).contains("Visible"),
                      "scrolling back must still show the in-window commit")
    }

    // MARK: - BUGPROOF 2: recurring series through the real producer

    /// Fixed contract (was red pre-fix). The store's delta for a new daily series
    /// claims only the seed day; the six other visible days were cached at
    /// activate() and never invalidated. Expected: a block on all 7 window
    /// days. Actual: only the seed day.
    func testAddDailySeriesThroughStoreShowsOnEveryWindowDay() async throws {
        let rig = try await makeRig()
        rig.surface.activate(now: t0)

        var series = timedEvent("Standup", dayOffset: 0, hour: 9)
        series.repeatUnit = .day
        XCTAssertTrue(series.isRecurringSeries, "fixture self-check")
        rig.store.addCalendarEvent(series, now: t0)

        let perDay = rig.surface.frame.days.map { $0.blocks.count }
        XCTAssertEqual(perDay, [1, 1, 1, 1, 1, 1, 1],
                       "a daily series added through MacEventStore must appear on every visible day — its honest delta (affected = seed day) leaves the other cached days stale")
    }

    // MARK: - Interest re-registration on shift (kills mutant e; green)

    /// After shift(), the OLD window's days must cost nothing and the NEW
    /// window's days must rebuild — both directions asserted, so dropping
    /// registerInterest() from shift() fails this twice. The re-registration
    /// gap (remove → add) is synchronous MainActor code: no delta can
    /// interleave, which this test's determinism relies on.
    func testShiftRetargetsInterestBothDirections() async throws {
        let rig = try await makeRig()
        rig.surface.activate(now: t0)
        rig.surface.shift(byDays: 7, now: t0)
        let rebuildsAfterShift = rig.bill.count(.surfaceRebuilds)

        // Old window (day 1 = Jan 16): must NOT reach the surface.
        rig.store.addCalendarEvent(timedEvent("OldWindow", dayOffset: 1, hour: 9), now: t0)
        XCTAssertEqual(rig.bill.count(.surfaceRebuilds), rebuildsAfterShift,
                       "a commit into the pre-shift window must not reach the shifted surface")
        XCTAssertFalse(blockTitles(rig.surface.frame).contains("OldWindow"))

        // New window (day 8 = Jan 23): must rebuild and render.
        rig.store.addCalendarEvent(timedEvent("NewWindow", dayOffset: 8, hour: 9), now: t0)
        XCTAssertEqual(rig.bill.count(.surfaceRebuilds), rebuildsAfterShift + 1,
                       "a commit into the shifted window must reach the surface exactly once")
        XCTAssertTrue(blockTitles(rig.surface.frame).contains("NewWindow"))
        XCTAssertEqual(rig.store.observerCount, 1,
                       "shift must swap the observer token, not accumulate them")
    }

    // MARK: - BUGPROOF 3: duplicate activate() leaks a clock registration

    /// Fixed contract (was red pre-fix). Two activate() calls (SwiftUI can re-fire an
    /// appear path) leave TWO minute-tick registrations; deactivate()
    /// removes only the second token. Census first, then the symptom: the
    /// overlay keeps rebuilding after deactivation.
    func testDoubleActivateThenDeactivateStopsTheClock() async throws {
        let rig = try await makeRig()
        rig.surface.activate(now: t0)
        rig.surface.activate(now: t0)
        XCTAssertEqual(rig.store.observerCount, 1,
                       "store side is safe: registerInterest removes the old token (control)")
        XCTAssertEqual(rig.clock.registeredCount, 1,
                       "duplicate activate must not accumulate clock registrations")

        rig.surface.deactivate()
        XCTAssertEqual(rig.clock.registeredCount, 0,
                       "deactivate must leave zero clock registrations")

        let overlays = rig.bill.count(.overlayBuilds)
        rig.clock.pump(now: t0)                          // seed
        rig.clock.pump(now: t0.addingTimeInterval(61))   // minute edge
        XCTAssertEqual(rig.bill.count(.overlayBuilds), overlays,
                       "a deactivated surface must not keep updating its overlay — the first activate()'s handler leaked")
    }

    // MARK: - Deactivate is inert (green)

    /// deactivate() then a matching commit: no crash, no surface work, no
    /// frame change. Positive control precedes it (same commit shape while
    /// active DOES rebuild).
    func testDeactivateThenCommitDoesNoSurfaceWork() async throws {
        let rig = try await makeRig()
        rig.surface.activate(now: t0)
        rig.store.addCalendarEvent(timedEvent("WhileActive", dayOffset: 1, hour: 8), now: t0)
        XCTAssertTrue(blockTitles(rig.surface.frame).contains("WhileActive"),
                      "positive control failed: an active surface must consume the delta")

        rig.surface.deactivate()
        let rebuilds = rig.bill.count(.surfaceRebuilds)
        let frameBefore = rig.surface.frame
        rig.store.addCalendarEvent(timedEvent("AfterDeactivate", dayOffset: 1, hour: 10), now: t0)
        XCTAssertEqual(rig.bill.count(.surfaceRebuilds), rebuilds)
        XCTAssertEqual(rig.surface.frame, frameBefore,
                       "a deactivated surface's frame must be frozen")
        XCTAssertEqual(rig.store.observerCount, 0)
    }

    // MARK: - Now-line window membership (green)

    /// The now-line renders only when the window contains today: nil when
    /// activated with a now 40 days before the anchor, present (with
    /// hand-computed fraction 8/24) when now sits inside the window.
    func testNowLineNilOutsideWindowPresentInside() async throws {
        let rig = try await makeRig()
        rig.surface.activate(now: t0.addingTimeInterval(-40 * 86_400))
        XCTAssertNil(rig.surface.frame.nowLine,
                     "a window not containing today must carry no now-line")
        rig.surface.deactivate()

        let rig2 = try await makeRig()
        rig2.surface.activate(now: t0)  // 08:00 UTC on the anchor day
        let line = try XCTUnwrap(rig2.surface.frame.nowLine, "positive control failed")
        XCTAssertEqual(line.dayKey, DayKey(year: 2027, month: 1, day: 15))
        XCTAssertEqual(line.yFraction, 8.0 / 24.0, accuracy: 0.0001)
    }

    /// A minute tick that crosses midnight moves the now-line to the new
    /// day's key (still inside the window).
    func testMidnightCrossingTickMovesNowLineToNextDay() async throws {
        let rig = try await makeRig()
        let lateNight = utc.startOfDay(for: t0).addingTimeInterval(23 * 3600 + 59 * 60)  // Jan 15 23:59
        rig.surface.activate(now: lateNight)
        XCTAssertEqual(rig.surface.frame.nowLine?.dayKey, DayKey(year: 2027, month: 1, day: 15))

        rig.clock.pump(now: lateNight.addingTimeInterval(10))  // seed 23:59:10
        rig.clock.pump(now: lateNight.addingTimeInterval(90))  // 00:00:30 next day
        let line = try XCTUnwrap(rig.surface.frame.nowLine)
        XCTAssertEqual(line.dayKey, DayKey(year: 2027, month: 1, day: 16),
                       "the overlay must follow now across midnight")
        XCTAssertEqual(line.yFraction, 30.0 / 86_400.0, accuracy: 0.0001)
    }

    // MARK: - Producer honesty end-to-end (surface 2; green)

    /// replaceCalendarEvent moving an event across days claims old ∪ new:
    /// both visible days update in one commit.
    func testReplaceMovingEventAcrossDaysUpdatesBothDays() async throws {
        let seedEvent = timedEvent("Wander", dayOffset: 1, hour: 9)
        let rig = try await makeRig(seed: [seedEvent])
        rig.surface.activate(now: t0)
        XCTAssertTrue(blockTitles(rig.surface.frame).contains("Wander"), "positive control failed")

        var moved = seedEvent
        let dayStart = utc.startOfDay(for: t0)
        let newStart = utc.date(byAdding: .day, value: 3, to: dayStart)!.addingTimeInterval(14 * 3600)
        moved.timeRanges = [.init(start: newStart, end: newStart.addingTimeInterval(3600))]
        rig.store.replaceCalendarEvent(moved, now: t0)

        let day16 = rig.surface.frame.days.first { $0.key == DayKey(year: 2027, month: 1, day: 16) }
        let day18 = rig.surface.frame.days.first { $0.key == DayKey(year: 2027, month: 1, day: 18) }
        XCTAssertEqual(day16?.blocks.count, 0, "old day must be cleared by the same commit")
        XCTAssertEqual(day18?.blocks.map(\.title), ["Wander"], "new day must show the moved event")
    }

    /// removeCalendarEvent claims the removed event's days: the block
    /// disappears from the visible frame in the same commit.
    func testRemoveEventClearsItsVisibleDay() async throws {
        let seedEvent = timedEvent("Doomed", dayOffset: 2, hour: 11)
        let rig = try await makeRig(seed: [seedEvent])
        rig.surface.activate(now: t0)
        XCTAssertTrue(blockTitles(rig.surface.frame).contains("Doomed"), "positive control failed")

        rig.store.removeCalendarEvent(id: seedEvent.id, now: t0)
        XCTAssertFalse(blockTitles(rig.surface.frame).contains("Doomed"),
                       "a removed event must leave the visible frame in the same commit")
    }

    // MARK: - Week window across a DST boundary (green)

    /// America/New_York window anchored 2026-03-05 spans the spring-forward
    /// day: seven DISTINCT consecutive civil keys, transition day included,
    /// and the frame carries exactly seven day models.
    func testWeekWindowAcrossSpringForwardHasSevenDistinctConsecutiveDays() async throws {
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        let anchor = ny.date(from: DateComponents(year: 2026, month: 3, day: 5, hour: 12))!
        let rig = try await makeRig(calendar: ny, anchor: anchor)
        rig.surface.activate(now: anchor)

        let expected = (5...11).map { DayKey(year: 2026, month: 3, day: $0) }
        XCTAssertEqual(rig.surface.windowKeys, expected,
                       "the 23h day must neither duplicate nor skip a key in the window walk")
        XCTAssertEqual(rig.surface.frame.days.map(\.key), expected,
                       "the frame must carry one model per civil day across the transition")
    }
}
