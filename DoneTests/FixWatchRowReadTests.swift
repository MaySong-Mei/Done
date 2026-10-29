//
//  FixWatchRowReadTests.swift
//  DoneTests
//
//  The Settings row's 观察站 indicator is a READ (red-team S2). It runs on
//  every appear of the Settings page — pop-backs from each of its sub-pages
//  included — and used to borrow the deck's flush-then-load barrier, so each
//  appear appended a daily line and fired a `.deckOpen` upload. Now it folds
//  the live resident's unwritten day over the file instead; the deck keeps
//  its own flush.
//

import XCTest
@testable import Done

@MainActor
final class FixWatchRowReadTests: XCTestCase {
    private var location: SpikeRunStorageLocation!
    private var coordinator: SpikeSessionCoordinator!
    private var center: ResidentObservationCenter?
    private var triggers: [TelemetryTrigger] = []

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
        coordinator = SpikeSessionCoordinator()
        triggers = []
    }

    override func tearDown() {
        center?.deactivate()
        center = nil
        SpikeProbe.onSignal = nil
        try? FileManager.default.removeItem(at: location.directory)
        coordinator = nil
        location = nil
        super.tearDown()
    }

    /// A Release stamp: the tripwire verdict judges Release dailies only.
    private func releaseStamp() -> SpikeRunContext.Stamp {
        SpikeRunContext.Stamp(appVersion: "0.5.0", appBuild: "10", appCommit: nil, deviceModel: "iPhone17,2",
                              osVersion: "26.0", timeZoneIdentifier: "UTC", localeIdentifier: "en_US",
                              buildConfiguration: "release")
    }

    /// Activated, so it is `ResidentObservationCenter.shared` — the instance
    /// the row reads by default, as in the app.
    @discardableResult
    private func makeActiveCenter() -> ResidentObservationCenter {
        let made = ResidentObservationCenter(
            coordinator: coordinator, store: nil, location: location, calendar: .current,
            now: Date.init, mediaNow: { 500 }, makeFrameProbe: { SpikeFrameProbe() },
            ownerUID: { "owner-a" }, stamp: { [unowned self] in self.releaseStamp() }
        )
        made.onUploadTrigger = { [unowned self] trigger in self.triggers.append(trigger) }
        made.activate()
        center = made
        XCTAssertTrue(ResidentObservationCenter.shared === made, "rig: the row's default resident is this one")
        return made
    }

    private var dailyFile: URL {
        location.directory.appendingPathComponent("\(FixObservationRegistry.residentDailySpikeID).jsonl")
    }

    private func dailyLineCount() -> Int {
        guard let data = try? Data(contentsOf: dailyFile) else { return 0 }
        return data.split(separator: 0x0A).count
    }

    private func meTabGate(_ verdicts: [FixVerdict]) throws -> FixVerdict {
        try XCTUnwrap(verdicts.first { $0.entryID == FixObservationRegistry.meTabGateFixID })
    }

    private func hiddenComputes(_ verdict: FixVerdict) -> String? {
        verdict.readouts.first { $0.id == "hidden computes" }?.measured
    }

    /// The call the Settings view makes, twice (an appear and a pop-back), over
    /// a day with counts in memory: no line on disk and no upload trigger.
    func testTheRowIndicatorWritesNothingAndTriggersNoUpload() {
        makeActiveCenter()
        SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))

        _ = FixWatchAttention.needsAttention(location: location)
        _ = FixWatchAttention.needsAttention(location: location)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dailyFile.path), "the row wrote a daily line")
        XCTAssertEqual(triggers, [], "the row fired an upload")
    }

    /// No flush, and still no stale day: a tripwire counted only in memory
    /// fires the row's alarm.
    func testTheRowSeesTodaysUnwrittenTripwire() throws {
        makeActiveCenter()
        SpikeProbe.emit(.invariant(FixWatchSignalID.meComputedHidden))

        let gate = try meTabGate(FixWatchAttention.loadRowVerdicts(currentSegment: .thisDevice(), location: location))

        XCTAssertTrue(gate.alarm, "the unwritten tripwire is visible to the row")
        XCTAssertEqual(dailyLineCount(), 0)
    }

    /// The unwritten day REPLACES its own line on disk rather than adding to
    /// it — the same id, latest wins — so a count is never seen twice.
    func testTheUnwrittenDayReplacesItsOwnLineOnDisk() throws {
        let made = makeActiveCenter()
        SpikeProbe.emit(.invariant(FixWatchSignalID.meComputedHidden))
        made.flushDaily()
        SpikeProbe.emit(.invariant(FixWatchSignalID.meComputedHidden))
        XCTAssertEqual(dailyLineCount(), 1, "liveness: one line, carrying the first count")

        let gate = try meTabGate(FixWatchAttention.loadRowVerdicts(currentSegment: .thisDevice(), location: location))

        XCTAssertEqual(hiddenComputes(gate), "2", "one on disk, one more in memory: two, not three and not one")
        XCTAssertEqual(dailyLineCount(), 1)
    }

    /// Nothing unwritten, nothing folded: the line on disk is the day.
    func testAWrittenDayIsReadFromDiskAlone() throws {
        let made = makeActiveCenter()
        SpikeProbe.emit(.invariant(FixWatchSignalID.meComputedHidden))
        made.flushDaily()
        XCTAssertNil(made.unwrittenDailyRecord())

        let gate = try meTabGate(FixWatchAttention.loadRowVerdicts(currentSegment: .thisDevice(), location: location))
        XCTAssertEqual(hiddenComputes(gate), "1")
    }

    /// The deck's own open is unchanged: it still flushes today so far and is
    /// still an upload point.
    func testTheDeckStillFlushesAndTriggersItsUpload() {
        makeActiveCenter()
        SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))

        _ = FixWatchAttention.loadLocalRecords()

        XCTAssertEqual(triggers, [.deckOpen])
        XCTAssertEqual(dailyLineCount(), 1)
    }
}
