//
//  MacPersistenceTests.swift
//  DoneMacTests
//
//  The revision-gated write pipeline: latest-wins coalescing, equal
//  generation ⇒ zero bytes, and budget assertion 6 — a session that
//  changed nothing writes nothing.
//

import XCTest
@testable import Done

@MainActor
final class MacPersistenceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(id: UUID = UUID(), title: String = "R") -> Event {
        Event(id: id, title: title,
              timeRanges: [.init(start: t0, end: t0.addingTimeInterval(3600))],
              kind: .event)
    }

    func testSubmitFlushRoundTrip() async throws {
        let location = EventStorageLocation.ephemeral(id: UUID())
        let persistence = try MacPersistence(location: location)
        let id = UUID()
        await persistence.submitCalendarEvents([row(id: id)], generation: 1, dominoStamp: nil)
        var sidecar = SidecarFile()
        sidecar.bump([id], at: t0)
        await persistence.submitSidecar(sidecar, generation: 1)
        await persistence.flush()

        let reloaded = try MacPersistence(location: location)
        let result = await reloaded.loadAll()
        XCTAssertEqual(result.calendarEvents.map(\.id), [id])
        XCTAssertEqual(result.sidecar.records[id]?.revision, 1)
        XCTAssertFalse(result.sidecarWasUnreadable)
    }

    func testRedundantGenerationWritesZeroBytes() async throws {
        let persistence = try MacPersistence(location: .ephemeral(id: UUID()))
        let rows = [row()]
        await persistence.submitCalendarEvents(rows, generation: 1, dominoStamp: nil)
        await persistence.flush()
        let statsAfterFirst = await persistence.stats
        XCTAssertEqual(statsAfterFirst.slotWrites, 1)

        // Same generation again: the gate rejects it before the engine runs.
        await persistence.submitCalendarEvents(rows, generation: 1, dominoStamp: nil)
        await persistence.flush()
        let statsAfterSecond = await persistence.stats
        XCTAssertEqual(statsAfterSecond.slotWrites, 1)
        XCTAssertEqual(statsAfterSecond.redundantSubmissions, 1)
        XCTAssertEqual(statsAfterSecond.slotWriteBytes, statsAfterFirst.slotWriteBytes,
                       "an equal revision must cost zero bytes")
    }

    func testLatestWinsCoalescing() async throws {
        let persistence = try MacPersistence(location: .ephemeral(id: UUID()))
        let a = row(title: "gen1")
        let b = row(title: "gen2")
        // Two submissions land before any drain: only the latest hits disk.
        await persistence.submitCalendarEvents([a], generation: 1, dominoStamp: nil)
        await persistence.submitCalendarEvents([a, b], generation: 2, dominoStamp: nil)
        await persistence.flush()

        let stats = await persistence.stats
        XCTAssertEqual(stats.slotWrites, 1, "a burst of commits must collapse to one write")
        XCTAssertEqual(stats.supersededSubmissions, 1)
        let result = await persistence.loadAll()
        XCTAssertEqual(result.calendarEvents.count, 2, "the write that landed must be the LATEST snapshot")
    }

    func testByteIdenticalPayloadIsSkippedByTheEngine() async throws {
        let persistence = try MacPersistence(location: .ephemeral(id: UUID()))
        let rows = [row()]
        await persistence.submitCalendarEvents(rows, generation: 1, dominoStamp: nil)
        await persistence.flush()
        // Higher generation, identical bytes: passes the gate, engine skips.
        await persistence.submitCalendarEvents(rows, generation: 2, dominoStamp: nil)
        await persistence.flush()
        let stats = await persistence.stats
        XCTAssertEqual(stats.slotWrites, 1)
        XCTAssertEqual(stats.skippedIdenticalWrites, 1)
    }

    /// BUDGET ASSERTION 6: load → no mutation → flush ⇒ zero writes of any
    /// kind. The structural form of the O(1) dirty check the iOS backup
    /// path lacked (#219 E family).
    func testNoChangeSessionWritesNothing() async throws {
        let location = EventStorageLocation.ephemeral(id: UUID())
        do {
            let persistence = try MacPersistence(location: location)
            await persistence.submitCalendarEvents([row()], generation: 1, dominoStamp: nil)
            await persistence.flush()
        }
        let persistence = try MacPersistence(location: location)
        let bill = MacWorkBill()
        let store = MacEventStore(persistence: persistence, bill: bill, calendar: Calendar(identifier: .gregorian))
        await store.load()
        await store.flush()
        let stats = await persistence.stats
        XCTAssertEqual(stats.slotWrites, 0, "a no-change session wrote a slot")
        XCTAssertEqual(stats.slotWriteBytes, 0)
        XCTAssertEqual(stats.sidecarWrites, 0)
        XCTAssertEqual(stats.heartbeatWrites, 0)
        XCTAssertEqual(bill.count(.storeCommits), 0)
    }

    func testDominoStampRidesTheEnvelope() async throws {
        let location = EventStorageLocation.ephemeral(id: UUID())
        let stamp = t0.addingTimeInterval(1234)
        do {
            let persistence = try MacPersistence(location: location)
            await persistence.submitCalendarEvents([row()], generation: 1, dominoStamp: stamp)
            await persistence.flush()
        }
        let persistence = try MacPersistence(location: location)
        let result = await persistence.loadAll()
        XCTAssertEqual(result.dominoStamp, stamp)
    }

    func testHeartbeatAndEnvelopeCombineByMax() async throws {
        let location = EventStorageLocation.ephemeral(id: UUID())
        let older = t0
        let newer = t0.addingTimeInterval(9999)
        do {
            let persistence = try MacPersistence(location: location)
            await persistence.submitCalendarEvents([row()], generation: 1, dominoStamp: older)
            await persistence.flush()
            await persistence.writeDominoHeartbeat(newer)
        }
        let persistence = try MacPersistence(location: location)
        let result = await persistence.loadAll()
        XCTAssertEqual(result.dominoStamp, newer,
                       "the newer statement wins regardless of which file holds it")
    }
}
