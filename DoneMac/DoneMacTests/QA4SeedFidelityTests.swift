//
//  QA4SeedFidelityTests.swift
//  DoneMacTests
//
//  Independent QA (round 3, Phase 4) — the load-bearing seeding rule.
//
//  Fixture: a detached recurrence instance minted in another frame
//  (America/New_York) and read on a UTC device — the one construction
//  where Event.renderTimeRanges differs from the raw stored ranges, so
//  "seeds from the projection, not the raw instants" becomes falsifiable.
//  Buildable without EventStore machinery via the memberwise Event init
//  (recurrenceParentId + recurrenceInstanceDate + recurrenceInstanceDayKey).
//
//  Arithmetic of the fixture (rig calendar UTC, mint frame NY/EDT = UTC-4):
//    nominal day 2026-03-10 (key 20260310); UTC nominal midnight
//    = dayStart; NY mint midnight (mirror) = dayStart+4h.
//    range1 raw  = mirror+22h = Mar 11 02:00 UTC  (22:00 Mar 10 NY)
//      dayShift = floor(22h/24h) = 0, UTC time-of-day 02:00
//      -> render1 = Mar 10 02:00 UTC = raw1 - 86400   (shifted)
//    range2 raw  = mirror+34h = Mar 11 14:00 UTC  (10:00 Mar 11 NY)
//      dayShift = floor(34h/24h) = 1, UTC time-of-day 14:00
//      -> render2 = Mar 11 14:00 UTC = raw2           (identity)
//  The per-range divergence is NON-uniform (-86400 vs 0), so a
//  raw-seeded write cannot hide behind a uniform-shift cancellation.
//
//  The RED test pins the missing write-side pairing: Event.swift's
//  write-side rule requires every instance-range write to be paired with
//  Event.rebasedExceptionInstanceAfterRangeWrite (iOS applies it inside
//  EventStore.mutateCalendarEvent, Done/Models/EventStore.swift:1941).
//  MacEventStore.replaceCalendarEvent has no such pairing, so a
//  projection-seeded write leaves the stale mint-frame mirror in place
//  and renderTimeRanges re-projects the fresh ranges a day off — and the
//  error COMPOUNDS on every subsequent save.
//

import XCTest
@testable import Done

@MainActor
final class QA4SeedFidelityTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    // 2026-03-10 00:00 UTC.
    private let dayStart = Date(timeIntervalSince1970: 1_773_100_800)
    private var day10: DayKey { DayKey(year: 2026, month: 3, day: 10) }

    private struct Rig {
        let store: MacEventStore
        let drag: DragController
        let composer: ComposerModel
        let bill: MacWorkBill
    }

    private func makeRig(events: [Event]) async throws -> Rig {
        let bill = MacWorkBill()
        let persistence = try MacPersistence(location: .ephemeral(id: UUID()))
        let store = MacEventStore(persistence: persistence, bill: bill, calendar: calendar)
        await store.load()
        for event in events { store.addCalendarEvent(event, now: dayStart) }
        return Rig(store: store,
                   drag: DragController(store: store, calendar: calendar),
                   composer: ComposerModel(store: store, calendar: calendar),
                   bill: bill)
    }

    /// NY mint-frame midnight of the nominal day.
    private var mirror: Date { dayStart.addingTimeInterval(4 * 3600) }

    private func traveledInstance(id: UUID = UUID(), secondRange: Bool) -> Event {
        var ranges = [Event.TimeRange(
            start: mirror.addingTimeInterval(22 * 3600),
            end: mirror.addingTimeInterval(23 * 3600)
        )]
        if secondRange {
            ranges.append(.init(
                start: mirror.addingTimeInterval(34 * 3600),
                end: mirror.addingTimeInterval(35 * 3600)
            ))
        }
        return Event(
            id: id, title: "Traveled",
            timeRanges: ranges,
            kind: .event,
            recurrenceParentId: UUID(),
            recurrenceInstanceDate: mirror,
            recurrenceInstanceDayKey: 20_260_310
        )
    }

    private var expectedRender1: Event.TimeRange {
        .init(start: dayStart.addingTimeInterval(2 * 3600),
              end: dayStart.addingTimeInterval(3 * 3600))
    }
    private var expectedRender2: Event.TimeRange {
        .init(start: dayStart.addingTimeInterval(38 * 3600),
              end: dayStart.addingTimeInterval(39 * 3600))
    }

    // MARK: - Fixture positive control

    /// The rig's own positive control: the fixture must actually project
    /// (render != raw, non-uniformly). If tzdata or the projection ever
    /// change under this file, every zero-result below dies here first
    /// instead of passing vacuously.
    func testTraveledInstanceFixtureActuallyProjects() {
        let traveled = traveledInstance(secondRange: true)
        let render = traveled.renderTimeRanges(calendar: calendar)
        XCTAssertEqual(render, [expectedRender1, expectedRender2])
        XCTAssertNotEqual(render, traveled.timeRanges, "fixture failed to travel")
        // Non-uniform divergence: -86400 on range1, 0 on range2.
        XCTAssertEqual(render[0].start.timeIntervalSince(traveled.timeRanges[0].start), -86_400)
        XCTAssertEqual(render[1].start, traveled.timeRanges[1].start)
    }

    // MARK: - Move drop seeding

    /// The drop must write projection-seeded instants shifted uniformly:
    /// pointer at 06:00 UTC on the nominal day = +4h from the RENDERED
    /// 02:00 start, so range2 (whose projection equals its raw value)
    /// must land at +4h from its projection. A raw-seeded mutant computes
    /// offset -20h from the raw Mar 11 02:00 start and drags range2 to
    /// Mar 10 18:00 — 86400 seconds away from the contract.
    func testMoveDropOnTraveledInstanceWritesProjectionSeededRanges() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [traveledInstance(id: id, secondRange: true)])
        guard let target = rig.store.calendarEvents.first(where: { $0.id == id }) else {
            return XCTFail("fixture missing")
        }
        rig.drag.beginMove(event: target, grabbedRange: target.renderTimeRanges(calendar: calendar)[0], grabFraction: 0)
        rig.drag.endMove(pointerDay: day10, pointerFraction: 6.0 / 24.0, now: dayStart)

        let moved = rig.store.calendarEvents.first { $0.id == id }
        XCTAssertEqual(moved?.timeRanges, [
            Event.TimeRange(start: dayStart.addingTimeInterval(6 * 3600),
                            end: dayStart.addingTimeInterval(7 * 3600)),
            Event.TimeRange(start: dayStart.addingTimeInterval(42 * 3600),
                            end: dayStart.addingTimeInterval(43 * 3600)),
        ], "drop must be seeded from renderTimeRanges and shifted uniformly from there")
    }

    /// Picking up a traveled block and dropping it exactly where it
    /// RENDERS is a no-op: offset 0, no commit, raw storage untouched.
    /// A raw-seeded mutant sees a -86400 offset instead and rewrites the
    /// event on a drop the user meant as "leave it".
    func testDropInPlaceOnTraveledInstanceCommitsNothing() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [traveledInstance(id: id, secondRange: false)])
        let raw = rig.store.calendarEvents.first { $0.id == id }?.timeRanges
        let commits = rig.bill.count(.storeCommits)
        guard let target = rig.store.calendarEvents.first(where: { $0.id == id }) else {
            return XCTFail("fixture missing")
        }
        rig.drag.beginMove(event: target, grabbedRange: target.renderTimeRanges(calendar: calendar)[0], grabFraction: 0)
        // 02:00 on the nominal day — exactly the rendered start.
        rig.drag.endMove(pointerDay: day10, pointerFraction: 2.0 / 24.0, now: dayStart)

        XCTAssertEqual(rig.bill.count(.storeCommits), commits,
                       "a drop on the rendered position must not commit")
        XCTAssertEqual(rig.store.calendarEvents.first { $0.id == id }?.timeRanges, raw,
                       "raw mint-frame storage must survive an in-place drop untouched")
    }

    // MARK: - Composer seeding

    /// Round-4 contract (review F2 superseded the old "write the seeds
    /// back" reading): an untouched time field is NOT ASSIGNED at all —
    /// the fresh row's stored ranges stand verbatim, so a rename can
    /// neither drag a moved row back nor disturb a traveled instance's
    /// mint-frame storage. Render stays stable because nothing changed.
    func testComposerUntouchedSaveLeavesStoredRangesAlone() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [traveledInstance(id: id, secondRange: true)])
        guard let before = rig.store.calendarEvents.first(where: { $0.id == id }) else {
            return XCTFail("fixture missing")
        }
        XCTAssertTrue(rig.composer.openForEdit(eventID: id, now: dayStart))
        rig.composer.title = "Renamed"
        rig.composer.save(now: dayStart)

        let saved = rig.store.calendarEvents.first { $0.id == id }
        XCTAssertEqual(saved?.timeRanges, before.timeRanges,
                       "untouched times must not be written at all — raw storage survives")
        XCTAssertEqual(saved?.renderTimeRanges(calendar: calendar),
                       before.renderTimeRanges(calendar: calendar),
                       "the rendered position is unchanged by a rename")
        XCTAssertEqual(saved?.title, "Renamed")
    }

    /// EXPECTED RED — real bug (missing write-side pairing). After the
    /// projection-seeded save above, the mirror still points at the NY
    /// mint midnight, so renderTimeRanges re-projects the fresh ranges:
    /// stored 02:00 UTC sits 2h BEFORE the mirror, dayShift floors to -1,
    /// and the block re-renders on Mar 9 — a rename moved the event a
    /// day back, and each further save walks it another day earlier.
    /// iOS pairs this exact write with
    /// Event.rebasedExceptionInstanceAfterRangeWrite inside
    /// EventStore.mutateCalendarEvent; MacEventStore.replaceCalendarEvent
    /// does not.
    func testComposerRenameKeepsTraveledInstanceRenderStable() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [traveledInstance(id: id, secondRange: true)])
        guard let before = rig.store.calendarEvents.first(where: { $0.id == id })?
            .renderTimeRanges(calendar: calendar) else { return XCTFail("fixture missing") }

        XCTAssertTrue(rig.composer.openForEdit(eventID: id, now: dayStart))
        rig.composer.title = "Renamed"
        rig.composer.save(now: dayStart)

        guard let after = rig.store.calendarEvents.first(where: { $0.id == id })?
            .renderTimeRanges(calendar: calendar) else { return XCTFail("event lost") }
        XCTAssertEqual(after, before,
                       "a rename must not move the block: the range write needs the " +
                       "rebasedExceptionInstanceAfterRangeWrite pairing (mirror rebase) " +
                       "that iOS applies in its mutate seam")
    }

    /// Untouched save on a plain multi-range event preserves EVERY range
    /// verbatim — a save that collapses to [ranges0] or re-derives the
    /// array drops the trailing ranges. (The implementer composer suite
    /// only ever saves single-range events.)
    func testComposerUntouchedSavePreservesEveryRange() async throws {
        let id = UUID()
        let r1 = Event.TimeRange(start: dayStart.addingTimeInterval(9 * 3600),
                                 end: dayStart.addingTimeInterval(10 * 3600))
        let r2 = Event.TimeRange(start: dayStart.addingTimeInterval(20 * 3600),
                                 end: dayStart.addingTimeInterval(21 * 3600))
        let multi = Event(id: id, title: "Multi", timeRanges: [r1, r2], kind: .event)
        let rig = try await makeRig(events: [multi])

        XCTAssertTrue(rig.composer.openForEdit(eventID: id, now: dayStart))
        rig.composer.title = "Renamed"
        rig.composer.save(now: dayStart)

        XCTAssertEqual(rig.store.calendarEvents.first { $0.id == id }?.timeRanges, [r1, r2],
                       "an untouched save must not drop or rewrite trailing ranges")
    }
}
