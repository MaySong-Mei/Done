//
//  QAPersistenceCoherenceTests.swift
//  DoneMacTests
//
//  INDEPENDENT QA — generation/persistence coherence across processes
//  (attack surface 2), the coalescing window and flush guarantees
//  (surface 3), sidecar corruption (surface 6), and the frozen-slot path
//  no implementer test exercises.
//
//  Tests named QAFinding_* PIN current behavior that the QA report flags
//  as a hazard — they are green on purpose so the suite stays adjudicable;
//  the report carries the severity.
//

import XCTest
@testable import Done

@MainActor
final class QAPersistenceCoherenceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let calendar = Calendar(identifier: .gregorian)

    private func row(id: UUID = UUID(), title: String = "R",
                     startOffset: TimeInterval = 0, kind: Event.Kind = .event) -> Event {
        let start = t0.addingTimeInterval(startOffset)
        return Event(id: id, title: title,
                     timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))],
                     kind: kind)
    }

    private func calendarPrimaryURL(_ location: EventStorageLocation) throws -> URL {
        try location.directoryURL().appendingPathComponent("calendarEvents.json")
    }

    private func sidecarFileURL(_ location: EventStorageLocation) throws -> URL {
        let dir = try location.directoryURL()
        return dir.deletingLastPathComponent()
            .appendingPathComponent(dir.lastPathComponent + "-Sidecar", isDirectory: true)
            .appendingPathComponent("revision-sidecar.json")
    }

    // MARK: - Surface 2: per-process generations over a persistent engine

    /// Process A commits generations 1..3; process B restarts at generation
    /// 1 over the same files. The gate is per-process by design — prove the
    /// DATA stays right across the restart, including the sidecar.
    func testCrossProcessGenerationRestartPersistsCorrectData() async throws {
        let location = EventStorageLocation.ephemeral(id: UUID())
        let a = UUID(), b = UUID(), c = UUID()
        do {
            let persistence = try MacPersistence(location: location)
            let store = MacEventStore(persistence: persistence, bill: MacWorkBill(), calendar: calendar)
            await store.load()
            store.addCalendarEvent(row(id: a, title: "A"), now: t0)
            store.addCalendarEvent(row(id: b, title: "B"), now: t0)
            store.addCalendarEvent(row(id: c, title: "C"), now: t0)
            await store.flush()
        }
        do {
            // "Process B": fresh persistence, lastAccepted resets to 0.
            let persistence = try MacPersistence(location: location)
            let store = MacEventStore(persistence: persistence, bill: MacWorkBill(), calendar: calendar)
            await store.load()
            XCTAssertEqual(store.calendarEvents.count, 3)
            store.removeCalendarEvent(id: b, now: t0.addingTimeInterval(60))  // generation 1 again
            await store.flush()
            let stats = await persistence.stats
            XCTAssertEqual(stats.redundantSubmissions, 0,
                           "process B's generation 1 must pass the fresh gate")
            XCTAssertEqual(stats.failedWrites, 0)
        }
        let persistence = try MacPersistence(location: location)
        let result = await persistence.loadAll()
        XCTAssertEqual(Set(result.calendarEvents.map(\.id)), [a, c],
                       "the restart-numbered write must carry the newer DATA")
        XCTAssertNil(result.sidecar.records[b], "removed record's sidecar entry must be gone on disk")
        XCTAssertNotNil(result.sidecar.records[a])
        XCTAssertNotNil(result.sidecar.records[c])
    }

    /// The gate must not wedge: accept, reject-as-redundant, then accept
    /// the next generation.
    func testGateAcceptsNextGenerationAfterRedundantRejection() async throws {
        let location = EventStorageLocation.ephemeral(id: UUID())
        let persistence = try MacPersistence(location: location)
        let a = row(title: "gen1")
        let b = row(title: "gen2")
        await persistence.submitCalendarEvents([a], generation: 1, dominoStamp: nil)
        await persistence.flush()
        await persistence.submitCalendarEvents([a], generation: 1, dominoStamp: nil)
        await persistence.flush()
        await persistence.submitCalendarEvents([a, b], generation: 2, dominoStamp: nil)
        await persistence.flush()
        let stats = await persistence.stats
        XCTAssertEqual(stats.redundantSubmissions, 1)
        XCTAssertEqual(stats.slotWrites, 2, "generation 2 must be accepted after the redundant 1")
        let result = await persistence.loadAll()
        XCTAssertEqual(result.calendarEvents.count, 2)
    }

    /// Gate contract pin: a submission reusing an already-accepted
    /// generation with DIFFERENT rows is dropped as redundant. Inside one
    /// MacEventStore this is unreachable (generations are monotonic and
    /// load() seeds from the watermark since the QA-round fix); this pins
    /// the raw actor API's behavior so a future caller can't presume merge
    /// semantics.
    func testQAFinding_SameGenerationDifferentDataSilentlyDropped() async throws {
        let location = EventStorageLocation.ephemeral(id: UUID())
        let persistence = try MacPersistence(location: location)
        let a = row(title: "kept")
        let b = row(title: "dropped")
        await persistence.submitCalendarEvents([a], generation: 1, dominoStamp: nil)
        await persistence.flush()
        await persistence.submitCalendarEvents([a, b], generation: 1, dominoStamp: nil)
        await persistence.flush()
        let stats = await persistence.stats
        XCTAssertEqual(stats.redundantSubmissions, 1)
        XCTAssertEqual(stats.failedWrites, 0, "the drop is SILENT — no failure surfaced anywhere")
        let result = await persistence.loadAll()
        XCTAssertEqual(result.calendarEvents.map(\.title), ["kept"],
                       "PINS CURRENT BEHAVIOR: equal-generation data is discarded, not merged or errored")
    }

    /// Was a MAJOR QA finding (a second store over a live persistence
    /// numbered itself below the gate and its commits vanished as
    /// "redundant"). Adjudicated fix: load() seeds the store's generations
    /// from the actor's watermark. This pins the fixed contract: nothing is
    /// dropped, no redundant classification, the data lands.
    func testSecondStoreOverLivePersistenceContinuesFromWatermark() async throws {
        let location = EventStorageLocation.ephemeral(id: UUID())
        let persistence = try MacPersistence(location: location)
        let d = UUID()
        do {
            let store1 = MacEventStore(persistence: persistence, bill: MacWorkBill(), calendar: calendar)
            await store1.load()
            store1.addCalendarEvent(row(title: "A"), now: t0)
            store1.addCalendarEvent(row(title: "B"), now: t0)
            store1.addCalendarEvent(row(title: "C"), now: t0)
            await store1.flush()                            // gate now at generation 3
        }
        let store2 = MacEventStore(persistence: persistence, bill: MacWorkBill(), calendar: calendar)
        await store2.load()
        XCTAssertEqual(store2.revision[.calendarEvents], 3,
                       "load() must seed the generation from the persistence watermark")
        store2.addCalendarEvent(row(id: d, title: "D"), now: t0.addingTimeInterval(60))  // generation 4
        await store2.flush()

        let stats = await persistence.stats
        XCTAssertEqual(stats.redundantSubmissions, 0,
                       "a watermark-seeded store can never number itself below the gate")
        XCTAssertEqual(stats.failedWrites, 0)

        let check = try MacPersistence(location: location)
        let result = await check.loadAll()
        XCTAssertTrue(result.calendarEvents.contains { $0.id == d },
                      "store2's commit reached disk")
    }

    // MARK: - Surface 3: the coalescing window vs process exit

    /// Inside the drain window nothing is on disk: a commit followed by
    /// process exit WITHOUT flush() is lost. flush() is the only guarantee
    /// — and (finding, report) nothing in DoneMacApp wires it to terminate.
    func testQAFinding_UnflushedSubmitInsideDrainWindowIsNotOnDisk() async throws {
        let location = EventStorageLocation.ephemeral(id: UUID())
        // 5s window stands in for "the process died inside the window".
        let persistence = try MacPersistence(location: location,
                                             drainDelayNanoseconds: 5_000_000_000)
        await persistence.submitCalendarEvents([row(title: "doomed")], generation: 1, dominoStamp: nil)

        let observer = try MacPersistence(location: location)
        let before = await observer.loadAll()
        XCTAssertEqual(before.calendarEvents.count, 0,
                       "PINS CURRENT BEHAVIOR: a submitted-but-undrained commit exists only in actor memory")

        await persistence.flush()                            // the positive control
        let after = await observer.loadAll()
        XCTAssertEqual(after.calendarEvents.count, 1,
                       "flush() is what puts it on disk — nothing else does")
    }

    /// An explicit flush() racing the scheduled drain task must not double-
    /// write or corrupt the stats.
    func testFlushRacingScheduledDrainWritesOnce() async throws {
        let persistence = try MacPersistence(location: .ephemeral(id: UUID()))  // default 40ms window
        await persistence.submitCalendarEvents([row()], generation: 1, dominoStamp: nil)
        await persistence.flush()                            // beat the sleeping drain
        try await Task.sleep(nanoseconds: 150_000_000)       // let the sleeping drain fire on nothing
        let stats = await persistence.stats
        XCTAssertEqual(stats.slotWrites, 1, "the late drain must find nothing pending")
        XCTAssertEqual(stats.redundantSubmissions, 0)
        XCTAssertEqual(stats.supersededSubmissions, 0)
    }

    // MARK: - Surface 6: sidecar corruption

    /// Was a MAJOR QA finding (unreadable sidecar dropped on the floor:
    /// revision histories silently restarted at 1, poisoning future sync
    /// dirtiness; the only trace an unread counter). Adjudicated fix:
    /// load() consumes the flag — the sidecarUnreadableSeen tripwire fires,
    /// revision bumping FREEZES for the run (no restart-at-1 poison, no
    /// futile writes against the frozen value file), calendar rows keep
    /// working. Pins the fixed contract.
    func testCorruptSidecarTripsWireAndFreezesRevisionBumping() async throws {
        let location = EventStorageLocation.ephemeral(id: UUID())
        let a = UUID()
        do {
            let persistence = try MacPersistence(location: location)
            let store = MacEventStore(persistence: persistence, bill: MacWorkBill(), calendar: calendar)
            await store.load()
            store.addCalendarEvent(row(id: a, title: "A"), now: t0)
            store.replaceCalendarEvent(row(id: a, title: "A2"), now: t0.addingTimeInterval(60))
            await store.flush()
        }
        // Sanity: revision 2 is on disk before the corruption.
        do {
            let check = try MacPersistence(location: location)
            let result = await check.loadAll()
            XCTAssertEqual(result.sidecar.records[a]?.revision, 2)
        }
        try Data("not json".utf8).write(to: sidecarFileURL(location))

        let persistence2 = try MacPersistence(location: location)
        let bill = MacWorkBill()
        let store2 = MacEventStore(persistence: persistence2, bill: bill, calendar: calendar)
        await store2.load()
        XCTAssertTrue(store2.sidecarFrozen, "load() must consume the unreadable flag")
        XCTAssertEqual(bill.count(.sidecarUnreadableSeen), 1,
                       "the tripwire is the loud signal — metadata loss is never invisible")

        store2.replaceCalendarEvent(row(id: a, title: "A3"), now: t0.addingTimeInterval(120))
        await store2.flush()

        // Calendar rows keep evolving; no revision restarts at 1, and no
        // futile sidecar writes hit the frozen value file.
        XCTAssertEqual(store2.calendarEvents.first?.title, "A3")
        XCTAssertNil(store2.sidecar.records[a],
                     "frozen sidecar must not mint a restarted revision history")
        let stats2 = await persistence2.stats
        XCTAssertEqual(stats2.failedWrites, 0,
                       "no sidecar submission is attempted while frozen")
        XCTAssertEqual(stats2.sidecarWrites, 0)
    }

    // MARK: - Frozen slot (no implementer test exercises this path)

    /// Positive control for the freeze plumbing end to end: a corrupt
    /// calendarEvents.json (no backup — single prior commit never creates
    /// one) must freeze the slot, and every store mutation must refuse:
    /// no generation bump, no delta, no stamp seed.
    func testCorruptCalendarSlotFreezesStoreMutations() async throws {
        let location = EventStorageLocation.ephemeral(id: UUID())
        do {
            let persistence = try MacPersistence(location: location)
            let store = MacEventStore(persistence: persistence, bill: MacWorkBill(), calendar: calendar)
            await store.load()
            store.addCalendarEvent(row(title: "original"), now: t0)
            await store.flush()
        }
        try Data("garbage, no header newline".utf8).write(to: calendarPrimaryURL(location))

        let persistence = try MacPersistence(location: location)
        let store = MacEventStore(persistence: persistence, bill: MacWorkBill(), calendar: calendar)
        await store.load()
        XCTAssertTrue(store.frozenSlots.contains(.calendarEvents),
                      "an unreadable slot must arrive frozen")

        var deltas = 0
        store.addObserver(interest: StoreInterest(slots: [.calendarEvents])) { _ in deltas += 1 }
        store.addCalendarEvent(row(title: "refused"), now: t0)
        store.dominoPush(now: t0, horizonDays: 7)
        XCTAssertEqual(store.calendarEvents.count, 0, "a frozen slot must refuse mutations")
        XCTAssertEqual(store.revision[.calendarEvents], 0, "no generation bump on a refused mutation")
        XCTAssertEqual(deltas, 0, "no delta on a refused mutation")
        XCTAssertNil(store.dominoLastPushEffective,
                     "dominoPush must not seed a stamp while frozen")
    }

    // MARK: - Mutation before load (the stamp rule's structural gap)

    /// Was a MAJOR QA finding (a pre-load commit clobbered the whole slot
    /// AND regressed the domino stamp to the stale heartbeat — the exact
    /// corruption iOS documents as must-be-unreachable). Adjudicated fix,
    /// two independent layers: (a) mutations are refused until load()
    /// completes (preLoadMutationRefused tripwire); (b) the drain enforces
    /// stamp monotonicity against the on-disk value regardless. Pins both.
    func testMutationBeforeLoadIsRefusedAndClobberNothing() async throws {
        let location = EventStorageLocation.ephemeral(id: UUID())
        let far = UUID()
        do {
            let persistence = try MacPersistence(location: location)
            let store = MacEventStore(persistence: persistence, bill: MacWorkBill(), calendar: calendar)
            await store.load()
            store.dominoPush(now: t0, horizonDays: 7)               // heartbeat = t0
            store.addCalendarEvent(row(id: far, title: "Far", startOffset: 30 * 86_400, kind: .todo), now: t0)
            store.dominoPush(now: t0.addingTimeInterval(3600), horizonDays: 7)  // envelope stamp = t0+3600
            await store.flush()
        }
        do {
            // "Process B" mutates before (or without) load(): refused.
            let persistence = try MacPersistence(location: location)
            let bill = MacWorkBill()
            let store = MacEventStore(persistence: persistence, bill: bill, calendar: calendar)
            store.addCalendarEvent(row(title: "PreLoad"), now: t0.addingTimeInterval(7200))
            XCTAssertEqual(bill.count(.preLoadMutationRefused), 1,
                           "the refusal must be counted, not silent")
            await store.flush()
        }
        let persistence = try MacPersistence(location: location)
        let store = MacEventStore(persistence: persistence, bill: MacWorkBill(), calendar: calendar)
        await store.load()
        XCTAssertEqual(store.calendarEvents.map(\.title), ["Far"],
                       "the slot survives — nothing was clobbered")
        XCTAssertEqual(store.dominoLastPushEffective, t0.addingTimeInterval(3600),
                       "the envelope stamp survives — no regression to the stale heartbeat")
    }
}
