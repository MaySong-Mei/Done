//
//  QA5SidecarPushPersistenceTests.swift
//  DoneMacTests
//
//  INDEPENDENT QA round 5 — markPushed's generation+1 sidecar submission
//  vs MacPersistence's monotonic sidecar gate (attack surface 5).
//
//  The collision, arithmetic'd: store generation G. markPushed submits the
//  clean sidecar at G+1 (deliberately ahead, so a quit right after a sync
//  keeps the clean state — that part works, see the green base case). But
//  the NEXT local commit bumps the store to exactly G+1 and submits its
//  sidecar at G+1 too — and drainSidecar requires `generation >
//  lastSidecarGeneration`, so G+1 > G+1 fails and that submission is
//  dropped as "redundant". The rows land on disk; the revision bump that
//  made them DIRTY does not. If the app quits there, the relaunched store
//  sees the edit as CLEAN: it will never be pushed, and the next pull
//  replaces it with the server's older copy. A real user edit is silently
//  lost. The window is "the first local edit after any successful sync,
//  with no second commit before quit" — a common shape, not a corner.
//

import XCTest
@testable import Done

@MainActor
final class QA5SidecarPushPersistenceTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let t0 = Date(timeIntervalSince1970: 1_773_100_800)  // 2026-03-10 UTC

    private func event(id: UUID = UUID(), title: String, hour: Double = 9) -> Event {
        let start = t0.addingTimeInterval(hour * 3600)
        return Event(id: id, title: title,
                     timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))],
                     kind: .event)
    }

    private func makeStore(at location: EventStorageLocation) async throws -> MacEventStore {
        let persistence = try MacPersistence(location: location)
        let store = MacEventStore(persistence: persistence, bill: MacWorkBill(), calendar: calendar)
        await store.load()
        return store
    }

    // MARK: - Base case (green): clean state survives relaunch

    /// The +1 submission's stated purpose works: markPushed then quit —
    /// the clean (pushed) state is on disk and the relaunched store does
    /// not re-push.
    func testMarkPushedCleanStateSurvivesRelaunch() async throws {
        let location = EventStorageLocation.ephemeral(id: UUID())
        let id = UUID()
        do {
            let store = try await makeStore(at: location)
            store.addCalendarEvent(event(id: id, title: "Pushed row"), now: t0)
            XCTAssertEqual(store.dirtyEventIDs(), [id])
            store.markPushed(store.dirtyRevisions())
            XCTAssertTrue(store.dirtyEventIDs().isEmpty)
            await store.flush()
        }
        let reloaded = try await makeStore(at: location)
        XCTAssertEqual(reloaded.calendarEvents.first?.id, id)
        XCTAssertTrue(reloaded.dirtyEventIDs().isEmpty,
                      "clean (pushed) state must survive the relaunch")
        XCTAssertEqual(reloaded.sidecar.records[id]?.lastPushedRevision, 1)
    }

    // MARK: - The collision (RED = real bug, QA5 report)

    /// EXPECTED RED under b4d85e3. Sequence: add E (gen 1) -> flush ->
    /// markPushed (sidecar submitted at gen 2) -> flush (sidecar gate now
    /// 2) -> edit E (gen 2 commit; sidecar bumps E to revision 2 = DIRTY;
    /// submitted at gen 2) -> flush: 2 > 2 is false, the dirty sidecar is
    /// dropped as redundant while the edited ROWS are written. Relaunch:
    /// the edit is present but reads as clean — it will never push, and
    /// the next pull will overwrite it with the server's older copy.
    func testEditAfterMarkPushedMustStayDirtyAcrossRelaunch() async throws {
        let location = EventStorageLocation.ephemeral(id: UUID())
        let id = UUID()
        do {
            let store = try await makeStore(at: location)
            store.addCalendarEvent(event(id: id, title: "v1"), now: t0)
            await store.flush()

            store.markPushed(store.dirtyRevisions())          // sidecar snapshot at generation 2
            await store.flush()             // sidecar gate advances to 2

            var edited = try XCTUnwrap(store.calendarEvents.first)
            edited.title = "v2 after push"
            store.replaceCalendarEvent(edited, now: t0.addingTimeInterval(60))  // commit gen 2
            XCTAssertEqual(store.dirtyEventIDs(), [id],
                           "in memory the edit is correctly dirty")
            await store.flush()
        }

        let reloaded = try await makeStore(at: location)
        XCTAssertEqual(reloaded.calendarEvents.first?.title, "v2 after push",
                       "the edited rows DID reach disk")
        XCTAssertEqual(reloaded.dirtyEventIDs(), [id],
                       "the edit's dirtiness must survive the relaunch — otherwise it never pushes and the next pull silently reverts it")
    }

    // MARK: - Window boundary (green): a second commit heals it

    /// One more commit before quit re-submits the FULL sidecar snapshot at
    /// generation 3, which clears the gate — proof the loss window is
    /// exactly "last commit before quit lands on generation collision".
    func testSecondCommitAfterTheCollisionCarriesTheDirtinessToDisk() async throws {
        let location = EventStorageLocation.ephemeral(id: UUID())
        let id = UUID()
        let other = UUID()
        do {
            let store = try await makeStore(at: location)
            store.addCalendarEvent(event(id: id, title: "v1"), now: t0)
            await store.flush()
            store.markPushed(store.dirtyRevisions())
            await store.flush()

            var edited = try XCTUnwrap(store.calendarEvents.first)
            edited.title = "v2 after push"
            store.replaceCalendarEvent(edited, now: t0.addingTimeInterval(60))   // gen 2 (collides)
            store.addCalendarEvent(event(id: other, title: "unrelated"), now: t0.addingTimeInterval(90))  // gen 3
            await store.flush()
        }

        let reloaded = try await makeStore(at: location)
        XCTAssertTrue(reloaded.dirtyEventIDs().contains(id),
                      "generation 3's sidecar snapshot carries the edit's revision bump")
        XCTAssertTrue(reloaded.dirtyEventIDs().contains(other))
    }
}
