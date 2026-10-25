//
//  MacRecurrenceEditTests.swift
//  DoneMacTests
//
//  A1a: the Mac store's recurrence orchestration over the SHARED pure engine
//  (Event.applyEdit) — this/following/all landing as one commit, the
//  .following split's exception carry + instance re-parenting, first-occurrence
//  .following collapsing to .all — plus the composer minting a series.
//  The recurrence SEMANTICS themselves are pinned by the shared
//  LeanRecurrenceReplay suite that also runs on Mac; this pins the Mac
//  store's plumbing around them.
//

import XCTest
@testable import Done

@MainActor
final class MacRecurrenceEditTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let day0 = Date(timeIntervalSince1970: 1_773_100_800)  // 2026-03-10 UTC 00:00
    private func day(_ n: Int) -> Date { day0.addingTimeInterval(Double(n) * 86_400) }

    private struct Rig {
        let store: MacEventStore
        let composer: ComposerModel
        let bill: MacWorkBill
    }

    private func makeRig(events: [Event] = []) async throws -> Rig {
        let bill = MacWorkBill()
        let store = MacTestStore.make(bill: bill, calendar: calendar)
        await store.load()
        for e in events { store.addCalendarEvent(e, now: day0) }
        return Rig(store: store, composer: ComposerModel(store: store, calendar: calendar), bill: bill)
    }

    /// A weekly series starting 09:00 on day 0.
    private func weeklySeries(id: UUID = UUID(), title: String = "Standup", type: String = "Work") -> Event {
        let start = day0.addingTimeInterval(9 * 3600)
        var e = Event(id: id, title: title,
                      timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))],
                      kind: .event)
        e.type = type
        e.repeatUnit = .week
        e.repeatInterval = 1
        return e
    }

    private func event(id: UUID = UUID(), title: String = "E", hour: Double) -> Event {
        let start = day0.addingTimeInterval(hour * 3600)
        return Event(id: id, title: title,
                     timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))],
                     kind: .event)
    }

    private func stored(_ rig: Rig, _ id: UUID) -> Event? {
        rig.store.calendarEvents.first { $0.id == id }
    }

    // MARK: - .all

    func testAllEditsSeriesInPlace() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [weeklySeries(id: id)])
        let commits = rig.bill.count(.storeCommits)
        rig.store.applyRecurringEdit(seriesID: id, occurrenceDate: day(7), scope: .all, now: day0) {
            $0.title = "Renamed"
        }
        XCTAssertEqual(rig.bill.count(.storeCommits) - commits, 1)
        XCTAssertEqual(rig.store.calendarEvents.count, 1, "no rows added for .all")
        let s = stored(rig, id)
        XCTAssertEqual(s?.title, "Renamed")
        XCTAssertTrue(s?.isRecurringSeries ?? false, "still a series")
    }

    // MARK: - .single

    func testSingleMaterializesExceptionInstance() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [weeklySeries(id: id)])
        let commits = rig.bill.count(.storeCommits)
        let occ = day(7)
        rig.store.applyRecurringEdit(seriesID: id, occurrenceDate: occ, scope: .single, now: day0) {
            $0.type = "Study"
        }
        XCTAssertEqual(rig.bill.count(.storeCommits) - commits, 1, "single is one commit")

        let series = try XCTUnwrap(stored(rig, id))
        let key = Event.recurrenceDayKey(for: calendar.startOfDay(for: occ), calendar: calendar)
        XCTAssertTrue(series.recurrenceExceptionDayKeys.contains(key),
                      "the series records the exception day")
        XCTAssertTrue(series.isRecurringSeries, "series stays a series")

        let instance = try XCTUnwrap(rig.store.calendarEvents.first { $0.recurrenceParentId == id })
        XCTAssertEqual(instance.type, "Study", "the edit landed on the exception instance")
        XCTAssertEqual(instance.repeatUnit, .none, "the instance is non-recurring")
        XCTAssertTrue(instance.isExceptionInstance)
        XCTAssertEqual(rig.store.calendarEvents.count, 2, "series + one exception instance")
    }

    // MARK: - .following

    func testFollowingSplitsSeries() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [weeklySeries(id: id)])
        let commits = rig.bill.count(.storeCommits)
        let split = day(14)  // third occurrence — not the first
        rig.store.applyRecurringEdit(seriesID: id, occurrenceDate: split, scope: .following, now: day0) {
            $0.title = "New chapter"
        }
        XCTAssertEqual(rig.bill.count(.storeCommits) - commits, 1, "the whole split is ONE commit")

        let old = try XCTUnwrap(stored(rig, id))
        XCTAssertEqual(old.repeatEndType, .onDate, "old series is capped")
        // Independent pin (addition, not the engine's calendar subtraction):
        // split day 2026-03-24 − 1 = 2026-03-23 00:00 UTC = day(13).
        XCTAssertEqual(old.repeatEndDate, day(13))

        let new = try XCTUnwrap(rig.store.calendarEvents.first { $0.id != id && $0.isRecurringSeries })
        XCTAssertEqual(new.title, "New chapter", "the edit landed on the split-off series")
        XCTAssertEqual(new.repeatUnit, .week)
        XCTAssertEqual(rig.store.calendarEvents.count, 2, "old (capped) + new series")
    }

    func testFollowingFromFirstOccurrenceCollapsesToAll() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [weeklySeries(id: id)])
        // day 0 is the first occurrence → .following must resolve to .all.
        rig.store.applyRecurringEdit(seriesID: id, occurrenceDate: day0, scope: .following, now: day0) {
            $0.title = "Whole thing"
        }
        XCTAssertEqual(rig.store.calendarEvents.count, 1, "no split — collapsed to .all")
        let s = stored(rig, id)
        XCTAssertEqual(s?.title, "Whole thing")
        XCTAssertNil(s?.repeatEndDate, "not capped")
    }

    func testFollowingCarriesExceptionsAndReparentsInstances() async throws {
        let id = UUID()
        var series = weeklySeries(id: id)
        // An exception + a materialized instance on day 21 (≥ split at day 14).
        let laterDay = calendar.startOfDay(for: day(21))
        series.appendRecurrenceException(onDay: laterDay, calendar: calendar)
        let laterKey = Event.recurrenceDayKey(for: laterDay, calendar: calendar)

        var instance = weeklySeries(id: UUID())
        instance.repeatUnit = .none
        instance.recurrenceParentId = id
        instance.recurrenceInstanceDate = laterDay
        instance.recurrenceInstanceDayKey = laterKey
        instance.timeRanges = [.init(start: day(21).addingTimeInterval(9 * 3600),
                                     end: day(21).addingTimeInterval(10 * 3600))]

        let rig = try await makeRig(events: [series, instance])
        rig.store.applyRecurringEdit(seriesID: id, occurrenceDate: day(14), scope: .following, now: day0) {
            $0.title = "Split"
        }
        let new = try XCTUnwrap(rig.store.calendarEvents.first { $0.id != id && $0.id != instance.id && $0.isRecurringSeries })
        XCTAssertTrue(new.recurrenceExceptionDayKeys.contains(laterKey),
                      "the on-or-after-split exception carried to the new series")
        let movedInstance = try XCTUnwrap(stored(rig, instance.id))
        XCTAssertEqual(movedInstance.recurrenceParentId, new.id,
                       "the ≥-split materialized instance re-parented to the new series")
    }

    /// QA F1: the split's changed-ID set must include the capped old series,
    /// the reparented instance, AND the new series — that set is the ONLY
    /// thing that marks rows dirty for sync, so a dropped insert silently
    /// stops the reparent from propagating cross-device.
    func testFollowingMarksAllSplitRowsChanged() async throws {
        let id = UUID()
        let series = weeklySeries(id: id)
        let laterDay = calendar.startOfDay(for: day(21))
        var instance = weeklySeries(id: UUID())
        instance.repeatUnit = .none
        instance.recurrenceParentId = id
        instance.recurrenceInstanceDate = laterDay
        instance.recurrenceInstanceDayKey = Event.recurrenceDayKey(for: laterDay, calendar: calendar)
        instance.timeRanges = [.init(start: day(21).addingTimeInterval(9 * 3600),
                                     end: day(21).addingTimeInterval(10 * 3600))]
        let rig = try await makeRig(events: [series, instance])

        var captured: [CommitDelta] = []
        _ = rig.store.addObserver(interest: StoreInterest(slots: [.calendarEvents])) { captured.append($0) }
        rig.store.applyRecurringEdit(seriesID: id, occurrenceDate: day(14), scope: .following, now: day0) {
            $0.title = "Split"
        }
        XCTAssertEqual(captured.count, 1, "the split is exactly one delta")
        let delta = try XCTUnwrap(captured.first)
        let new = try XCTUnwrap(rig.store.calendarEvents.first {
            $0.id != id && $0.id != instance.id && $0.isRecurringSeries
        })
        XCTAssertTrue(delta.changedIDs.isSuperset(of: [id, instance.id, new.id]),
                      "capped old series, reparented instance, and new series all ride the delta")
    }

    /// QA F2: an instance/exception landing EXACTLY on the split day belongs
    /// to the new series ("this and following" includes this) — the `>=`
    /// boundary, which the day-21 fixture never exercised.
    func testSplitDayBoundaryMovesToNewSeries() async throws {
        let id = UUID()
        var series = weeklySeries(id: id)
        let splitDay = calendar.startOfDay(for: day(14))
        let splitKey = Event.recurrenceDayKey(for: splitDay, calendar: calendar)
        series.appendRecurrenceException(onDay: splitDay, calendar: calendar)

        var instance = weeklySeries(id: UUID())
        instance.repeatUnit = .none
        instance.recurrenceParentId = id
        instance.recurrenceInstanceDate = splitDay
        instance.recurrenceInstanceDayKey = splitKey
        instance.timeRanges = [.init(start: day(14).addingTimeInterval(9 * 3600),
                                     end: day(14).addingTimeInterval(10 * 3600))]
        let rig = try await makeRig(events: [series, instance])
        rig.store.applyRecurringEdit(seriesID: id, occurrenceDate: day(14), scope: .following, now: day0) {
            $0.title = "Split"
        }
        let new = try XCTUnwrap(rig.store.calendarEvents.first {
            $0.id != id && $0.id != instance.id && $0.isRecurringSeries
        })
        XCTAssertEqual(stored(rig, instance.id)?.recurrenceParentId, new.id,
                       "an instance ON the split day moves to the new series (>=, not >)")
        XCTAssertTrue(new.recurrenceExceptionDayKeys.contains(splitKey),
                      "the split-day exception carries to the new series")
    }

    /// QA F3: a recurring edit renders on unbounded pattern days, so its
    /// commit must be all-days-dirty (nil) — never a narrow/empty set that
    /// leaves far-future day caches stale.
    func testRecurringEditEmitsBulkDelta() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [weeklySeries(id: id)])
        var captured: [CommitDelta] = []
        _ = rig.store.addObserver(interest: StoreInterest(slots: [.calendarEvents])) { captured.append($0) }

        rig.store.applyRecurringEdit(seriesID: id, occurrenceDate: day(7), scope: .single, now: day0) {
            $0.type = "Study"
        }
        rig.store.applyRecurringEdit(seriesID: id, occurrenceDate: day(14), scope: .following, now: day0) {
            $0.title = "Split"
        }
        XCTAssertEqual(captured.count, 2)
        for delta in captured {
            XCTAssertNil(delta.affectedDayKeys, "recurring edits are all-days-dirty, never a bounded set")
        }
    }

    // MARK: - removeRecurringOccurrence (QA F4 / review F7)

    /// A materialized instance to hang off a series on `dayN`.
    private func materializedInstance(parent: UUID, dayN: Int) -> Event {
        let dayDate = day(dayN)
        let dayStartN = calendar.startOfDay(for: dayDate)
        var e = weeklySeries(id: UUID())
        e.repeatUnit = .none
        e.recurrenceParentId = parent
        e.recurrenceInstanceDate = dayStartN
        e.recurrenceInstanceDayKey = Event.recurrenceDayKey(for: dayStartN, calendar: calendar)
        e.timeRanges = [.init(start: dayDate.addingTimeInterval(9 * 3600),
                              end: dayDate.addingTimeInterval(10 * 3600))]
        return e
    }

    func testRemoveAllRemovesSeriesAndChildren() async throws {
        let id = UUID()
        let child = materializedInstance(parent: id, dayN: 14)
        let rig = try await makeRig(events: [weeklySeries(id: id), child])
        rig.store.removeRecurringOccurrence(seriesID: id, occurrenceDate: day(7), scope: .all, now: day0)
        XCTAssertTrue(rig.store.calendarEvents.isEmpty, "series AND its exception instances removed")
    }

    func testRemoveFollowingCapsAndSweepsFromSplit() async throws {
        let id = UUID()
        let before = materializedInstance(parent: id, dayN: 7)    // < split (14)
        let after = materializedInstance(parent: id, dayN: 21)    // >= split
        let rig = try await makeRig(events: [weeklySeries(id: id), before, after])
        rig.store.removeRecurringOccurrence(seriesID: id, occurrenceDate: day(14), scope: .following, now: day0)

        let series = try XCTUnwrap(stored(rig, id))
        XCTAssertEqual(series.repeatEndType, .onDate)
        XCTAssertEqual(series.repeatEndDate, day(13), "capped at split − 1")
        XCTAssertNotNil(stored(rig, before.id), "a pre-split instance survives")
        XCTAssertNil(stored(rig, after.id), "an on/after-split instance is swept")
    }

    func testRemoveSingleSkipsDayAndSweepsThatInstance() async throws {
        let id = UUID()
        let child = materializedInstance(parent: id, dayN: 7)
        let rig = try await makeRig(events: [weeklySeries(id: id), child])
        rig.store.removeRecurringOccurrence(seriesID: id, occurrenceDate: day(7), scope: .single, now: day0)

        let series = try XCTUnwrap(stored(rig, id))
        XCTAssertTrue(series.isRecurringSeries, "the series survives")
        let key = Event.recurrenceDayKey(for: calendar.startOfDay(for: day(7)), calendar: calendar)
        XCTAssertTrue(series.recurrenceExceptionDayKeys.contains(key), "the day is skipped")
        XCTAssertNil(stored(rig, child.id), "the materialized instance for that day is swept")
    }

    // MARK: - Composer creates a series

    func testComposerCreatesWeeklySeries() async throws {
        let rig = try await makeRig()
        rig.composer.openForCreate(day: DayKey(date: day0, calendar: calendar), now: day0)
        rig.composer.title = "Weekly sync"
        rig.composer.repeatUnit = .week
        rig.composer.repeatInterval = 2
        rig.composer.save(now: day0)
        let created = try XCTUnwrap(rig.store.calendarEvents.first)
        XCTAssertTrue(created.isRecurringSeries)
        XCTAssertEqual(created.repeatUnit, .week)
        XCTAssertEqual(created.repeatInterval, 2)
    }

    func testComposerNoRepeatIsOneOff() async throws {
        let rig = try await makeRig()
        rig.composer.openForCreate(day: DayKey(date: day0, calendar: calendar), now: day0)
        rig.composer.title = "Once"
        rig.composer.save(now: day0)
        let created = try XCTUnwrap(rig.store.calendarEvents.first)
        XCTAssertFalse(created.isRecurringSeries)
        XCTAssertEqual(created.repeatUnit, .none)
    }

    /// review #2 positive: an `.onDate` end actually survives applyRepeatRule.
    func testComposerOnDateEndSurvives() async throws {
        let rig = try await makeRig()
        rig.composer.openForCreate(day: DayKey(date: day0, calendar: calendar), now: day0)
        rig.composer.title = "Until"
        rig.composer.repeatUnit = .day
        rig.composer.repeatEndType = .onDate
        rig.composer.repeatEndDate = day(30)
        rig.composer.save(now: day0)
        let created = try XCTUnwrap(rig.store.calendarEvents.first)
        XCTAssertEqual(created.repeatEndType, .onDate)
        XCTAssertEqual(created.repeatEndDate, day(30))
    }

    /// review #2 positive: an `.afterCount` end survives applyRepeatRule.
    func testComposerAfterCountEndSurvives() async throws {
        let rig = try await makeRig()
        rig.composer.openForCreate(day: DayKey(date: day0, calendar: calendar), now: day0)
        rig.composer.title = "Ten times"
        rig.composer.repeatUnit = .week
        rig.composer.repeatEndType = .afterCount
        rig.composer.repeatEndCount = 10
        rig.composer.save(now: day0)
        let created = try XCTUnwrap(rig.store.calendarEvents.first)
        XCTAssertEqual(created.repeatEndType, .afterCount)
        XCTAssertEqual(created.repeatEndCount, 10)
    }

    /// review #1 regression: `.onDate` with NO date must not persist a nil
    /// end (which the render gate collapses to a single occurrence) — the
    /// model falls back to a real future date.
    func testComposerOnDateWithNilDateDoesNotCollapse() async throws {
        let rig = try await makeRig()
        rig.composer.openForCreate(day: DayKey(date: day0, calendar: calendar), now: day0)
        rig.composer.title = "Should run"
        rig.composer.repeatUnit = .day
        rig.composer.repeatEndType = .onDate
        rig.composer.repeatEndDate = nil   // user never touched the date picker
        rig.composer.save(now: day0)
        let created = try XCTUnwrap(rig.store.calendarEvents.first)
        XCTAssertEqual(created.repeatEndType, .onDate)
        let end = try XCTUnwrap(created.repeatEndDate)
        XCTAssertGreaterThan(end, day0, "a real future end, not nil → not collapsed to one occurrence")
    }

    /// review #2: the EDIT branch's applyRepeatRule — a plain one-off event
    /// gains a rule and becomes a series.
    func testEditBranchAddsRuleToPlainEvent() async throws {
        let id = UUID()
        let plain = event(id: id, title: "Was once", hour: 9)
        let rig = try await makeRig(events: [plain])
        XCTAssertTrue(rig.composer.openForEdit(eventID: id, now: day0))
        rig.composer.repeatUnit = .week
        rig.composer.save(now: day0)
        let saved = stored(rig, id)
        XCTAssertTrue(saved?.isRecurringSeries ?? false, "a plain event edited with a rule becomes a series")
        XCTAssertEqual(saved?.repeatUnit, .week)
    }

    /// No-op guard (review #5): an `.all` edit that changes nothing must not
    /// commit.
    func testNoopAllEditDoesNotCommit() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [weeklySeries(id: id, title: "Same")])
        let commits = rig.bill.count(.storeCommits)
        rig.store.applyRecurringEdit(seriesID: id, occurrenceDate: day(7), scope: .all, now: day0) {
            $0.title = "Same"   // identical → no change
        }
        XCTAssertEqual(rig.bill.count(.storeCommits), commits, "a no-op recurring edit must not commit")
    }

    /// applyRepeatRule normalization: an end set while unit is later cleared
    /// must not persist a dangling end.
    func testComposerNoneUnitForcesEndOff() async throws {
        let rig = try await makeRig()
        rig.composer.openForCreate(day: DayKey(date: day0, calendar: calendar), now: day0)
        rig.composer.title = "Once"
        rig.composer.repeatEndType = .afterCount
        rig.composer.repeatEndCount = 5
        rig.composer.repeatUnit = .none   // no cadence → end must be dropped
        rig.composer.save(now: day0)
        let created = try XCTUnwrap(rig.store.calendarEvents.first)
        XCTAssertEqual(created.repeatEndType, .none)
        XCTAssertNil(created.repeatEndCount)
    }
}
