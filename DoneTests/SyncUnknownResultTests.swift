//
//  SyncUnknownResultTests.swift
//  DoneTests
//
//  Survey S4 / gaps G10 and G23: a write that was sent but whose result is
//  unknown leaves the `?` marker in the baseline, so the row is re-verified
//  instead of reading clean, and a local delete of such a row still sends
//  its tombstone PATCH.
//

import XCTest
@testable import Done

@MainActor
final class SyncUnknownResultTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var server: SyncFakeServer!
    private var service: SupabaseSyncService!
    private let uid = "44444444-4444-4444-4444-444444444444"

    override func setUp() {
        super.setUp()
        suiteName = "SyncUnknownResultTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        server = SyncFakeServer(userId: uid)
        service = SupabaseSyncService(gateway: server, userId: uid, defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeEvent(_ title: String, note: String = "") -> Event {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        return Event(title: title, note: note,
                     timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))])
    }

    private func entry(_ event: Event) -> SyncBaselineEntry? {
        service.baseline.entry(table: "calendar_events", id: event.id.uuidString)
    }

    /// The answer was lost after the request left: the transport error a
    /// dropped connection surfaces.
    private let lostAnswer = URLError(.networkConnectionLost)

    // MARK: G23 — the delete that never went out

    func testG23_newRowWhosePostAnswerWasLostIsDeletedLocally_theTombstoneStillGoesOut_killsAwaitingEchoDeleteDropped() async throws {
        let e = makeEvent("posted, answer lost")
        server.dropResponseWhen = { verb, _ in verb == .insert ? self.lostAnswer : nil }
        await service.syncEvents([e], kind: "calendar")
        server.dropResponseWhen = nil
        XCTAssertNotNil(server.row(table: "events", key: e.id.uuidString), "the POST landed; only its answer was lost")

        await service.syncEvents([], kind: "calendar")

        XCTAssertEqual(server.requests(.tombstone).count, 1, "the local delete must reach the server")
        XCTAssertEqual(server.requests(.tombstone).first?.keys, [e.id.uuidString])
        XCTAssertTrue(server.isTombstoned(table: "events", key: e.id.uuidString), "other devices see the delete")
        XCTAssertNil(entry(e), "a 2xx tombstone clears the entry")
    }

    /// The echo-wait path of G23 when the first tombstone does not get
    /// out: the delete is owed until a tombstone lands, so the `?` entry
    /// must outlive the awaitingEcho sweep and the failed request.
    func testG23_echoWaitRowDeletedLocallyWhoseFirstTombstoneNeverLeft_isResentOnTheNextFlush_killsSweepDropsBaselineKey() async throws {
        let e = makeEvent("gone before its echo, offline")
        server.seed(table: "events", rows: [service.eventToRow(e, kind: "calendar")])
        await service.syncEvents([e], kind: "calendar")
        let key = SyncBaselineKey(table: "calendar_events", id: e.id.uuidString)
        XCTAssertEqual(service.awaitingEcho, [key], "the POST answered []: the row is in the echo wait")
        XCTAssertEqual(entry(e), .unknown(seq: nil))

        server.failWhen = { verb, _ in verb == .tombstone ? URLError(.notConnectedToInternet) : nil }
        await service.syncEvents([], kind: "calendar")
        server.failWhen = nil

        XCTAssertEqual(server.requests(.tombstone).count, 1)
        XCTAssertFalse(server.isTombstoned(table: "events", key: e.id.uuidString), "the request never left")
        XCTAssertTrue(service.awaitingEcho.isEmpty, "the echo bookkeeping lets go of a row that left the local array")
        XCTAssertEqual(entry(e), .unknown(seq: nil), "the delete is still owed; the mutant dropped the entry in the sweep")
        XCTAssertEqual(SyncBaselineStore(defaults: defaults, userId: uid).entry(table: "calendar_events", id: e.id.uuidString),
                       .unknown(seq: nil), "persisted: a relaunch still owes the delete")

        await service.syncEvents([], kind: "calendar")

        XCTAssertEqual(server.requests(.tombstone).map(\.keys), [[e.id.uuidString], [e.id.uuidString]], "resent on the next flush")
        XCTAssertTrue(server.isTombstoned(table: "events", key: e.id.uuidString), "other devices see the delete")
        XCTAssertNil(entry(e))
    }

    func testPostAnswerLostLeavesTheMarkerWithNoSeqAndTheNextFlushPostsAgainIntoTheEchoWait() async throws {
        let e = makeEvent("posted twice")
        server.dropResponseWhen = { verb, _ in verb == .insert ? self.lostAnswer : nil }
        await service.syncEvents([e], kind: "calendar")
        server.dropResponseWhen = nil
        XCTAssertEqual(entry(e), .unknown(seq: nil))
        XCTAssertEqual(SyncBaselineStore(defaults: defaults, userId: uid).entry(table: "calendar_events", id: e.id.uuidString),
                       .unknown(seq: nil), "persisted: a relaunch still owes the verification")

        await service.syncEvents([e], kind: "calendar")

        XCTAssertEqual(server.requests(.insert).count, 2, "seq unknown: ignore-duplicates POST again")
        XCTAssertEqual(service.awaitingEcho, [SyncBaselineKey(table: "calendar_events", id: e.id.uuidString)],
                       "the row was already there, so the second POST answered [] and the echo settles it")
        XCTAssertEqual(entry(e), .unknown(seq: nil))
    }

    // MARK: G10 — the edit put back after a lost PATCH answer

    func testG10_patchLandedAnswerLostThenUserPutsTheOldValueBack_theOldValueReachesTheServer_killsBaselineUntouched() async throws {
        let c0 = makeEvent("X", note: "c0")
        await service.syncEvents([c0], kind: "calendar")
        let s0 = try XCTUnwrap(entry(c0)?.seq)
        var c1 = c0
        c1.note = "c1"
        server.dropResponseWhen = { verb, _ in verb == .patch ? self.lostAnswer : nil }
        await service.syncEvents([c1], kind: "calendar")
        server.dropResponseWhen = nil
        let s5 = try XCTUnwrap(server.seq(table: "events", key: c0.id.uuidString))
        XCTAssertGreaterThan(s5, s0, "the PATCH committed")
        XCTAssertEqual(entry(c0), .unknown(seq: s0), "result unknown: `?`, seq kept")

        // The user puts c0 back (an undo writes the old bytes back).
        await service.syncEvents([c0], kind: "calendar")

        XCTAssertEqual(server.requests(.patch).count, 2, "the mutant reads c0 as clean here and sends nothing")
        XCTAssertEqual(server.requests(.patch).last?.baseSeq, s0)
        let key = SyncBaselineKey(table: "calendar_events", id: c0.id.uuidString)
        XCTAssertTrue(service.pendingVerify.contains(key), "seq=eq.s0 against s5 → []")

        // The pull delivers X@s5 (c1, this device's own lost write). The
        // applier's dirty branch: c1 to the shelf, base := (h_in, s5).
        let c1Hash = SupabaseSyncService.rowHash(service.eventToRow(c1, kind: "calendar"))
        service.baseline.setEntry(SyncBaselineEntry(hash: c1Hash, seq: s5), table: "calendar_events", id: c0.id.uuidString)
        service.resolvePendingVerifyAtHead(seen: [key], pullIssue: 1)

        await service.syncEvents([c0], kind: "calendar")

        XCTAssertEqual(server.requests(.patch).last?.baseSeq, s5)
        XCTAssertEqual(server.row(table: "events", key: c0.id.uuidString)?.data["note"] as? String, "c0",
                       "the user's last intent is on the server")
    }

    /// Positive control for the marker's trigger: a request that never left
    /// leaves the baseline exactly as it was.
    func testPatchThatNeverLeftTheDeviceLeavesTheBaselineAlone_killsMarkOnEveryFailure() async throws {
        let e = makeEvent("X", note: "c0")
        await service.syncEvents([e], kind: "calendar")
        let before = try XCTUnwrap(entry(e))
        var edited = e
        edited.note = "c1"
        server.failWhen = { verb, _ in verb == .patch ? URLError(.notConnectedToInternet) : nil }

        await service.syncEvents([edited], kind: "calendar")

        XCTAssertEqual(entry(e), before)
        server.failWhen = nil
        await service.syncEvents([edited], kind: "calendar")
        XCTAssertEqual(server.row(table: "events", key: e.id.uuidString)?.data["note"] as? String, "c1")
    }

    func testHttpStatusMeansTheServerAnsweredSoNoMarker() async throws {
        let e = makeEvent("X", note: "c0")
        await service.syncEvents([e], kind: "calendar")
        let before = try XCTUnwrap(entry(e))
        var edited = e
        edited.note = "c1"
        server.failWhen = { verb, _ in
            verb == .patch ? SupabaseREST.SyncError.requestFailed(table: "events", method: "PATCH", status: 503, code: nil) : nil
        }

        await service.syncEvents([edited], kind: "calendar")

        XCTAssertEqual(entry(e), before, "a 503 is an answer: nothing was applied")
    }

    // MARK: Tombstones whose answer was lost

    func testTombstoneAnswerLostThenRowStaysDeleted_theTombstoneIsResentAndClears() async throws {
        let gone = makeEvent("gone"), keep = makeEvent("keep")
        await service.syncEvents([gone, keep], kind: "calendar")
        let s0 = try XCTUnwrap(entry(gone)?.seq)
        server.dropResponseWhen = { verb, _ in verb == .tombstone ? self.lostAnswer : nil }

        await service.syncEvents([keep], kind: "calendar")
        server.dropResponseWhen = nil

        XCTAssertTrue(server.isTombstoned(table: "events", key: gone.id.uuidString), "it landed")
        XCTAssertEqual(entry(gone), .unknown(seq: s0))

        await service.syncEvents([keep], kind: "calendar")

        XCTAssertEqual(server.requests(.tombstone).count, 2)
        XCTAssertNil(entry(gone), "the resend's 2xx (empty body: already dead) clears it")
    }

    /// Survey S4's restored-tombstone case. The server holds the tombstone; the restored
    /// row reads dirty and goes out on its old seq, which the tombstone
    /// moved, so the PATCH answers [] and the pull that follows brings the
    /// tombstone back. Whether the undo survives that is S2 / #140 (pending
    /// user decision); this pins only that the row is not silently clean.
    func testTombstoneAnswerLostThenRowRestoredLocally_readsDirtyAndIsReverified_killsBaselineUntouched() async throws {
        let e = makeEvent("merged away"), keep = makeEvent("keep")
        await service.syncEvents([e, keep], kind: "calendar")
        let s0 = try XCTUnwrap(entry(e)?.seq)
        server.dropResponseWhen = { verb, _ in verb == .tombstone ? self.lostAnswer : nil }
        await service.syncEvents([keep], kind: "calendar")
        server.dropResponseWhen = nil
        let patchesBefore = server.requests(.patch).count

        // Undo: the same bytes come back.
        await service.syncEvents([e, keep], kind: "calendar")

        XCTAssertEqual(server.requests(.patch).count, patchesBefore + 1, "the mutant reads the restored row as clean and sends nothing")
        XCTAssertEqual(server.requests(.patch).last?.baseSeq, s0)
        XCTAssertTrue(service.pendingVerify.contains(SyncBaselineKey(table: "calendar_events", id: e.id.uuidString)))
        XCTAssertTrue(server.isTombstoned(table: "events", key: e.id.uuidString), "a PATCH never clears a tombstone (I6)")
    }

    // MARK: Single-row tables

    func testSettingsPatchAnswerLostMarksTheChangedKeysSoPuttingThemBackIsStillSent() async throws {
        defaults.set(true, forKey: AppSettingsKeys.showTimerBanner)
        await service.syncSettings()
        let s0 = try XCTUnwrap(service.baseline.settings?.seq)
        guard case .versioned(_, let keysBefore, _)? = service.baseline.settings else { return XCTFail("versioned expected") }
        defaults.set(false, forKey: AppSettingsKeys.showTimerBanner)
        server.dropResponseWhen = { verb, table in verb == .patch && table == "user_settings" ? self.lostAnswer : nil }

        await service.syncSettings()
        server.dropResponseWhen = nil

        guard case .versioned(let seq, let keys, _)? = service.baseline.settings else { return XCTFail("versioned expected") }
        XCTAssertEqual(seq, s0)
        XCTAssertEqual(keys[AppSettingsKeys.showTimerBanner], SyncBaselineEntry.unknownHash)
        XCTAssertEqual(keys.filter { $0.key != AppSettingsKeys.showTimerBanner }, keysBefore.filter { $0.key != AppSettingsKeys.showTimerBanner },
                       "only the key the write changed is marked")

        defaults.set(true, forKey: AppSettingsKeys.showTimerBanner)
        let patchesBefore = server.requests(.patch, table: "user_settings").count
        await service.syncSettings()
        XCTAssertEqual(server.requests(.patch, table: "user_settings").count, patchesBefore + 1, "the old value put back is still sent")
    }

    func testScalarTablePatchAnswerLostLeavesTheMarkerAtTheKnownSeq() async throws {
        let prefs = AgentPreferenceStore(
            directoryURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("SyncUnknownResultTests-prefs-\(UUID().uuidString)", isDirectory: true))
        await service.syncAgentPreferences(prefs)
        let s0 = try XCTUnwrap(service.baseline.entry(table: "agent_preferences", id: uid)?.seq)
        // Force a dirty row without touching the store: a stale baseline hash.
        service.baseline.setEntry(SyncBaselineEntry(hash: "0ld3nc0d1ng00000", seq: s0), table: "agent_preferences", id: uid)
        server.dropResponseWhen = { verb, table in verb == .patch && table == "agent_preferences" ? self.lostAnswer : nil }

        await service.syncAgentPreferences(prefs)

        XCTAssertEqual(service.baseline.entry(table: "agent_preferences", id: uid), .unknown(seq: s0))
    }
}

