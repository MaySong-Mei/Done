//
//  QA5SyncGuardrailTests.swift
//  DoneMacTests
//
//  INDEPENDENT QA round 5 — MacSyncEngine guardrail honesty and engine
//  lifecycle (attack surfaces 3 + 6): the in-memory server-stamp baseline
//  across a relaunch, push failure after adoption, the forget-own-stamp
//  rule, bulk-delta reach, re-entrancy, and failure recovery.
//
//  Convention: tests named QA5Finding_* PIN current behavior the report
//  flags (green on purpose; severity lives in the report).
//

import XCTest
@testable import Done

@MainActor
final class QA5SyncGuardrailTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let t0 = Date(timeIntervalSince1970: 1_773_100_800)  // 2026-03-10 UTC

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    @MainActor
    final class QA5Gateway: RemoteEventsGateway {
        var rowsToServe: [[String: Any]] = []
        var upserted: [[[String: Any]]] = []
        var fetchError: Error?
        var upsertError: Error?
        var fetchCount = 0
        /// When set before a fetch, the fetch parks on this until released —
        /// lets a test observe the engine mid-flight deterministically.
        var holdNextFetch = false
        var heldFetch: CheckedContinuation<Void, Never>?

        func fetchEventRows(userId: String) async throws -> [[String: Any]] {
            fetchCount += 1
            if holdNextFetch {
                holdNextFetch = false
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    heldFetch = c
                }
            }
            if let fetchError { throw fetchError }
            return rowsToServe
        }

        func upsertEventRows(_ rows: [[String: Any]]) async throws {
            if let upsertError { throw upsertError }
            upserted.append(rows)
        }

        var deletedIDs: [[String]] = []
        func deleteEventRows(ids: [String]) async throws {
            deletedIDs.append(ids)
        }
    }

    private struct Boom: Error {}

    private func event(id: UUID = UUID(), title: String, hour: Double = 9) -> Event {
        let start = t0.addingTimeInterval(hour * 3600)
        return Event(id: id, title: title,
                     timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))],
                     kind: .event)
    }

    private func serverRow(_ event: Event, updatedAt: String) -> [String: Any] {
        var row = SupabaseEventRowCodec.eventToRow(
            event, kind: "calendar", userId: "user-1", now: t0, iso: Self.iso
        )
        row["updated_at"] = updatedAt
        return row
    }

    private struct Rig {
        let store: MacEventStore
        let engine: MacSyncEngine
        let gateway: QA5Gateway
        let bill: MacWorkBill
    }

    private func makeRig(persistence: MacPersistence? = nil) async throws -> Rig {
        let bill = MacWorkBill()
        let p = try persistence ?? MacPersistence(location: .ephemeral(id: UUID()))
        let store = MacEventStore(persistence: p, bill: bill, calendar: calendar)
        await store.load()
        let gateway = QA5Gateway()
        let engine = MacSyncEngine(
            store: store, gateway: gateway,
            identity: { "user-1" }
        )
        return Rig(store: store, engine: engine, gateway: gateway, bill: bill)
    }

    // MARK: - Baseline control: within one session the rail holds

    /// Positive control for the relaunch finding below, built on the SAME
    /// rig machinery: with the baseline still in memory, a moved server
    /// stamp drops the Mac edit — iOS wins. (Implementer covers this too;
    /// repeated here so the pair of tests differs in exactly one variable:
    /// the relaunch.)
    func testControl_SameSessionRaceLosesToIOS() async throws {
        let rig = try await makeRig()
        let id = UUID()
        rig.gateway.rowsToServe = [serverRow(event(id: id, title: "Baseline"), updatedAt: "s1")]
        await rig.engine.syncNow(now: t0)  // baseline pull, row adopted clean

        var edited = try XCTUnwrap(rig.store.calendarEvents.first)
        edited.title = "Mac stale edit"
        rig.store.replaceCalendarEvent(edited, now: t0.addingTimeInterval(60))
        rig.gateway.rowsToServe = [serverRow(event(id: id, title: "iPhone newer write"), updatedAt: "s2")]

        await rig.engine.syncNow(now: t0.addingTimeInterval(600))

        XCTAssertEqual(rig.store.calendarEvents.first?.title, "iPhone newer write")
        XCTAssertTrue(rig.gateway.upserted.isEmpty)
    }

    // MARK: - The relaunch hole (surface 3, the round's product question)

    /// Was the relaunch-hole pin (round-6 fix: baselines persist in the
    /// sidecar beside the dirtiness that already did). The exact sequence
    /// that used to clobber the iPhone now resolves iOS-wins.
    func testRelaunchKeepsBaselineAndIOSWinsAcrossSessions() async throws {
        let location = EventStorageLocation.ephemeral(id: UUID())
        let id = UUID()

        // Session 1: baseline pull, local edit, quit without syncing.
        do {
            let rig = try await makeRig(persistence: try MacPersistence(location: location))
            rig.gateway.rowsToServe = [serverRow(event(id: id, title: "Baseline"), updatedAt: "s1")]
            await rig.engine.syncNow(now: t0)
            XCTAssertEqual(rig.store.calendarEvents.first?.title, "Baseline")

            var edited = try XCTUnwrap(rig.store.calendarEvents.first)
            edited.title = "Mac stale edit"
            rig.store.replaceCalendarEvent(edited, now: t0.addingTimeInterval(60))
            XCTAssertEqual(rig.store.dirtyEventIDs(), [id])
            await rig.store.flush()
        }

        // Session 2: fresh engine (empty stamp map), server moved to s2.
        let rig2 = try await makeRig(persistence: try MacPersistence(location: location))
        XCTAssertEqual(rig2.store.dirtyEventIDs(), [id],
                       "dirtiness survives the relaunch by design (sidecar)")
        rig2.gateway.rowsToServe = [serverRow(event(id: id, title: "iPhone newer write"), updatedAt: "s2")]

        await rig2.engine.syncNow(now: t0.addingTimeInterval(600))

        XCTAssertEqual(rig2.store.calendarEvents.first?.title, "iPhone newer write",
                       "the persisted baseline lets the guardrail fire across a relaunch — iOS wins")
        XCTAssertTrue(rig2.gateway.upserted.isEmpty,
                      "the stale edit must NOT ship over the newer iPhone write")
        XCTAssertTrue(rig2.engine.lastSummary.contains("updated on iPhone"),
                      "the override is surfaced")
    }

    // MARK: - Push failure after adoption (surface 3b)

    /// Upsert throws AFTER applyRemoteEvents committed: adoption stays (by
    /// design), rows stay dirty, and — the traced question — the baseline
    /// serverStamp assigned BEFORE the failed push must still judge
    /// correctly next sync. Server unchanged: old==new -> not conflicted ->
    /// the edit retries and lands.
    func testPushFailureKeepsDirtyAndNextSyncRecovers() async throws {
        let rig = try await makeRig()
        let id = UUID()
        rig.store.addCalendarEvent(event(id: id, title: "Mac edit"), now: t0)
        rig.gateway.rowsToServe = [serverRow(event(id: id, title: "Server old"), updatedAt: "s1")]
        rig.gateway.upsertError = Boom()

        await rig.engine.syncNow(now: t0.addingTimeInterval(60))
        if case .failed = rig.engine.phase {} else { XCTFail("push failure must surface") }
        XCTAssertEqual(rig.store.calendarEvents.first?.title, "Mac edit",
                       "adoption kept the dirty row; the failed push must not eat it")
        XCTAssertEqual(rig.store.dirtyEventIDs(), [id], "still dirty — nothing was marked pushed")

        rig.gateway.upsertError = nil
        await rig.engine.syncNow(now: t0.addingTimeInterval(120))

        XCTAssertEqual(rig.engine.phase, .idle)
        XCTAssertEqual(rig.gateway.upserted.count, 1)
        XCTAssertEqual(rig.gateway.upserted[0][0]["title"] as? String, "Mac edit",
                       "the pre-failure baseline must not misread an unchanged server as a conflict")
        XCTAssertTrue(rig.store.dirtyEventIDs().isEmpty)
    }

    /// Same failed push, but the iPhone writes BETWEEN the failure and the
    /// retry: the pre-failure baseline (s1) vs the new stamp (s2) is a real
    /// conflict and iOS must win.
    func testPushFailureThenIPhoneWriteStillLosesToIOS() async throws {
        let rig = try await makeRig()
        let id = UUID()
        rig.store.addCalendarEvent(event(id: id, title: "Mac edit"), now: t0)
        rig.gateway.rowsToServe = [serverRow(event(id: id, title: "Server old"), updatedAt: "s1")]
        rig.gateway.upsertError = Boom()
        await rig.engine.syncNow(now: t0.addingTimeInterval(60))  // baseline s1, push fails

        rig.gateway.upsertError = nil
        rig.gateway.rowsToServe = [serverRow(event(id: id, title: "iPhone won"), updatedAt: "s2")]
        await rig.engine.syncNow(now: t0.addingTimeInterval(120))

        XCTAssertEqual(rig.store.calendarEvents.first?.title, "iPhone won",
                       "a stamp that moved across the failed push is a real conflict — iOS wins")
        XCTAssertTrue(rig.gateway.upserted.isEmpty,
                      "the losing edit must not ship")
    }

    // MARK: - Forget-own-stamp rule (kills mutation d)

    /// After a successful push the engine forgets its baseline for pushed
    /// ids so the NEXT pull re-baselines from our own write's stamp. If it
    /// didn't (mutation d), the next sync would read our own push as a
    /// foreign conflict and drop a legitimate new local edit.
    func testOwnPushedStampIsNeverReadAsAForeignConflict() async throws {
        let rig = try await makeRig()
        let id = UUID()
        rig.store.addCalendarEvent(event(id: id, title: "v1"), now: t0)
        rig.gateway.rowsToServe = [serverRow(event(id: id, title: "Server old"), updatedAt: "s1")]

        await rig.engine.syncNow(now: t0.addingTimeInterval(60))  // keeps dirty v1, pushes it
        XCTAssertEqual(rig.gateway.upserted.count, 1)

        var edited = try XCTUnwrap(rig.store.calendarEvents.first)
        edited.title = "v2"
        rig.store.replaceCalendarEvent(edited, now: t0.addingTimeInterval(120))

        // The server now holds OUR push — same content, new stamp.
        rig.gateway.rowsToServe = [serverRow(event(id: id, title: "v1"), updatedAt: "s-mac-push")]
        await rig.engine.syncNow(now: t0.addingTimeInterval(180))

        XCTAssertEqual(rig.store.calendarEvents.first?.title, "v2",
                       "our own push's stamp change must not override the follow-up edit")
        XCTAssertEqual(rig.gateway.upserted.count, 2, "v2 pushes")
        XCTAssertEqual(rig.gateway.upserted[1][0]["title"] as? String, "v2")
    }

    // MARK: - Bulk delta reach (kills mutation f)

    /// The sync merge claims EVERYTHING (affectedDayKeys nil): a day-scoped
    /// observer on the adopted event's day must hear it. A scoped-empty
    /// delta would leave every day cache stale after a sync.
    func testSyncMergeEmitsBulkDeltaReachingDayScopedObservers() async throws {
        let rig = try await makeRig()
        let day = DayKey(date: t0.addingTimeInterval(9 * 3600), calendar: calendar)
        var received: [CommitDelta] = []
        rig.store.addObserver(
            interest: StoreInterest(slots: [.calendarEvents], dayKeys: [day])
        ) { received.append($0) }

        rig.gateway.rowsToServe = [serverRow(event(title: "Adopted", hour: 9), updatedAt: "s1")]
        await rig.engine.syncNow(now: t0)

        XCTAssertEqual(received.count, 1,
                       "the day-scoped observer must be reached by the sync merge")
        XCTAssertNil(received[0].affectedDayKeys,
                     "the merge's one commit must be the documented bulk (nil) delta")
    }

    // MARK: - Engine lifecycle (surface 6)

    func testOverlappingSyncNowIsRefusedByTheBusyGuard() async throws {
        let rig = try await makeRig()
        rig.gateway.rowsToServe = [serverRow(event(title: "Row"), updatedAt: "s1")]
        rig.gateway.holdNextFetch = true

        let first = Task { await rig.engine.syncNow(now: t0) }
        while rig.gateway.heldFetch == nil { await Task.yield() }
        XCTAssertTrue(rig.engine.isBusy)

        await rig.engine.syncNow(now: t0.addingTimeInterval(1))  // second call while busy
        XCTAssertEqual(rig.gateway.fetchCount, 1,
                       "an overlapping syncNow must not start a second fetch")

        rig.gateway.heldFetch?.resume()
        rig.gateway.heldFetch = nil
        await first.value
        XCTAssertEqual(rig.engine.phase, .idle)
        XCTAssertEqual(rig.store.calendarEvents.count, 1, "the first sync completes normally")
    }

    func testFetchFailureRecoversOnTheNextSync() async throws {
        let rig = try await makeRig()
        rig.gateway.fetchError = Boom()
        await rig.engine.syncNow(now: t0)
        if case .failed = rig.engine.phase {} else { XCTFail("failure must surface") }

        rig.gateway.fetchError = nil
        rig.gateway.rowsToServe = [serverRow(event(title: "After recovery"), updatedAt: "s1")]
        await rig.engine.syncNow(now: t0.addingTimeInterval(60))

        XCTAssertEqual(rig.engine.phase, .idle, "a failed phase must not wedge the engine")
        XCTAssertEqual(rig.store.calendarEvents.first?.title, "After recovery")
    }
}
