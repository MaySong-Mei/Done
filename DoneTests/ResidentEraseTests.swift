//
//  ResidentEraseTests.swift
//  DoneTests
//
//  "Erase all local data" against the resident observer's day in memory.
//
//  `SpikeRunStore.wipe()` takes the files, but the center kept its counters,
//  followers, gesture log, daily id, the claim that id was minted under, and
//  any auto-window open at the time. The next flush (deck open, a background
//  edge) then wrote the whole pre-erase day back into the wiped directory
//  under the erased owner — a claim change closes the old id under its OWN
//  claim — and the open window's close wrote the pre-erase gestures.
//
//  The eraser cannot be driven from a test (see `EraseWiringScan`); its
//  wiring and order are pinned in `EraseWiringQATests`. These drive the two
//  calls it makes for this — the directory wipe and the center's forget — in
//  its order, then every path that writes the center's day afterwards.
//

import XCTest
@testable import Done

@MainActor
final class ResidentEraseTests: XCTestCase {
    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private static let erasedOwner = "owner-before-erase"

    private var location: SpikeRunStorageLocation!
    private var coordinator: SpikeSessionCoordinator!
    private var center: ResidentObservationCenter?
    private var followerClock: FollowerManualClock!
    private var displaced: FollowerTimingRecorder?

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
        coordinator = SpikeSessionCoordinator()
        followerClock = FollowerManualClock()
        displaced = FollowerTiming.recorder
        FollowerTiming.recorder = nil
    }

    override func tearDown() {
        center?.deactivate()
        center = nil
        FollowerTiming.recorder = displaced
        SpikeProbe.onSignal = nil
        try? FileManager.default.removeItem(at: location.directory)
        coordinator = nil
        location = nil
        super.tearDown()
    }

    private func makeCenter(owner: Box<String?>, clock: Box<Date>) -> ResidentObservationCenter {
        let followerClock = followerClock!
        let made = ResidentObservationCenter(
            coordinator: coordinator, store: nil, location: location, calendar: .current,
            now: { clock.value }, mediaNow: { 500 },
            makeFrameProbe: { SpikeFrameProbe() },
            ownerUID: { owner.value },
            followerClock: { followerClock.ns },
            installsFollowerProbe: true,
            isAppActive: { true }
        )
        center = made
        return made
    }

    private func emitTap() {
        SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .changed, eventTime: nil, locationX: 100))
        SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .ended, eventTime: nil, locationX: 100))
        SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .commitStart, eventTime: nil, locationX: 0))
        SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .commitEnd, eventTime: nil, locationX: 0))
    }

    private func follower(ms: Double) {
        FollowerTiming.measure(FollowerID.allCases[0]) { followerClock.advance(ms: ms) }
    }

    private func dailies() -> [SpikeRun] {
        SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.residentDailySpikeID, location: location)
    }

    private func windows() -> [SpikeRun] {
        SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.effortPathFixID, location: location)
    }

    /// Counts, followers and an open window under the erased owner; a line
    /// already on disk for that day; then the erase in the eraser's order —
    /// the wipe, the sign-out, the forget (when `forget`) — and then both
    /// writers of the center's day: the window's close and the next flush.
    private func eraseWithADirtyDayAndAnOpenWindow(forget: Bool) throws -> UUID {
        let owner = Box<String?>(Self.erasedOwner)
        let clock = Box(Date())
        let made = makeCenter(owner: owner, clock: clock)
        made.activate()

        SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))
        SpikeProbe.emit(.invariant(FixWatchSignalID.meComputedHidden))
        follower(ms: 40)
        made.flushDaily()
        let preErase = try XCTUnwrap(dailies().first, "liveness: the pre-erase day is on disk")
        XCTAssertEqual(preErase.ownerUID, Self.erasedOwner)

        SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))
        follower(ms: 25)
        emitTap()
        XCTAssertNotNil(made.window, "liveness: a completed tap opened an auto-window")

        SpikeRunStore.wipe(location: location)
        owner.value = nil
        if forget {
            made.forgetAfterErase()
            XCTAssertNil(made.window, "the open window is gone")
            XCTAssertFalse(FileManager.default.fileExists(atPath: location.directory.path),
                           "the forget itself writes nothing")
        }

        made.closeWindow()      // the window's deadline, or a lifecycle edge
        made.flushDaily()       // a deck open; a lifecycle edge runs the same write
        return preErase.id
    }

    /// The fix: after the forget, nothing on disk carries the erased day — no
    /// line for its id, no line for its owner, no window, and the next day
    /// line counts from zero (followers included).
    func testAfterTheForgetNothingWrittenCarriesThePreEraseDay() throws {
        let preEraseID = try eraseWithADirtyDayAndAnOpenWindow(forget: true)

        XCTAssertTrue(windows().isEmpty, "the window open at the erase held the erased owner's gestures")
        let after = dailies()
        XCTAssertFalse(after.contains { $0.id == preEraseID }, "the erased day's id is never written again")
        XCTAssertFalse(after.contains { $0.ownerUID == Self.erasedOwner }, "nothing is written for the erased owner")
        let zero = ResidentCounterSet().metrics
        // The follower this test drove; the host app's own followers share
        // the main thread, so no claim is made about the others.
        let driven = FollowerID.allCases[0]
        let followerKeys = [FollowerStatTable.dailyCountKey(driven), FollowerStatTable.dailyTotalKey(driven)]
        for record in after {
            for (key, value) in zero {
                XCTAssertEqual(record.metrics[key], value, "\(key) starts over at the erase")
            }
            for key in followerKeys {
                XCTAssertEqual(record.metrics[key], .number(0), "\(key) starts over at the erase")
            }
        }
    }

    /// The control: the same sequence without the forget writes the erased
    /// day back — its id, its owner, its counts, as revision 1 because the
    /// wipe also took the revision cache — and the window's gestures. If this
    /// stops reproducing, the test above no longer tells the fix from its
    /// absence.
    func testWithoutTheForgetThePreEraseDayAndWindowComeBack() throws {
        let preEraseID = try eraseWithADirtyDayAndAnOpenWindow(forget: false)

        let resurrected = try XCTUnwrap(dailies().first { $0.id == preEraseID })
        XCTAssertEqual(resurrected.ownerUID, Self.erasedOwner)
        XCTAssertEqual(resurrected.revision, 1)
        XCTAssertEqual(resurrected.metrics["meComputedVisible"], .number(2))
        XCTAssertEqual(windows().count, 1)
        XCTAssertEqual(windows().first?.ownerUID, Self.erasedOwner)
    }

    /// An erase after midnight with no signal since: the center still holds
    /// yesterday's day bound. The forget re-bases without writing, so the
    /// next flush writes today's line for the fresh id — never a line closed
    /// at yesterday's end, which for an id minted after midnight would end
    /// before it started.
    func testAnEraseAfterAQuietMidnightRebasesTheDayWithoutWriting() throws {
        let calendar = Calendar.current
        let lateEvening = calendar.date(bySettingHour: 23, minute: 50, second: 0, of: Date())!
        let owner = Box<String?>(Self.erasedOwner)
        let clock = Box(lateEvening)
        let made = makeCenter(owner: owner, clock: clock)
        made.activate()
        SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))

        clock.value = lateEvening.addingTimeInterval(20 * 60)
        SpikeRunStore.wipe(location: location)
        owner.value = nil
        made.forgetAfterErase()
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.directory.path),
                       "the forget writes nothing, not even yesterday's close")

        made.flushDaily()
        let after = dailies()
        XCTAssertEqual(after.count, 1)
        let line = try XCTUnwrap(after.first)
        let today = TelemetryClaimKey.dayKey(forDayStart: calendar.startOfDay(for: clock.value), calendar: calendar).dayKey
        XCTAssertEqual(line.dayKey, today)
        XCTAssertEqual(line.startedAt, clock.value)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(line.endedAt), line.startedAt)
        XCTAssertEqual(line.metrics["meComputedVisible"], .number(0))
    }
}
