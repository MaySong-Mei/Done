//
//  ObsReadQAEraseRowTests.swift
//  DoneTests
//
//  Independent QA for perf/obs-read, steps 1, 2 and 4:
//    * the erase: the resident observer forgets its day, so nothing from
//      before an erase comes back — on disk or on the wire — whichever way
//      the erase arrives (account kept or signed out, across midnight, with
//      an auto-window open, followed by another account, during the launch
//      seed's background check);
//    * the Settings row's 观察站 dot: a pure read that lights exactly when
//      the 3111ef1 row (flush, then read) lit, held against that row on
//      random sequences of signals, flushes, owner changes, relaunches,
//      midnights and erases;
//    * the healing newline: an append after a torn tail stands on its own.
//
//  Every absence is paired with a positive control that shows the rig
//  would have seen the thing.
//

import QuartzCore
import UIKit
import XCTest
@testable import Done

private final class QABox<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

@MainActor
private func qaReleaseStamp(build: String = "10", configuration: String = "release") -> SpikeRunContext.Stamp {
    SpikeRunContext.Stamp(appVersion: "0.5.0", appBuild: build, appCommit: nil, deviceModel: "iPhone17,2",
                          osVersion: "26.0", timeZoneIdentifier: "UTC", localeIdentifier: "en_US",
                          buildConfiguration: configuration)
}

/// Today at `hour:minute:second` on the device calendar.
private func qaToday(_ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
    Calendar.current.date(bySettingHour: hour, minute: minute, second: second, of: Date())!
}

@MainActor
private func qaSpin(_ seconds: Double) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

@MainActor
private func qaTap() {
    SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .changed, eventTime: nil, locationX: 100))
    SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .ended, eventTime: nil, locationX: 100))
    SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .commitStart, eventTime: nil, locationX: 0))
    SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .commitEnd, eventTime: nil, locationX: 0))
}

@MainActor
private func qaVisible(_ count: Int) {
    for _ in 0..<count { SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible)) }
}

@MainActor
private func qaHidden(_ count: Int) {
    for _ in 0..<count { SpikeProbe.emit(.invariant(FixWatchSignalID.meComputedHidden)) }
}

// MARK: - Step 1: the erase

@MainActor
final class ObsReadQAEraseTests: XCTestCase {
    private var location: SpikeRunStorageLocation!
    private var coordinator: SpikeSessionCoordinator!
    private var center: ResidentObservationCenter?
    private let owner = QABox<String?>("owner-a")
    private let clock = QABox(qaToday(15))
    private var trail: [String] = []
    private var displaced: FollowerTimingRecorder?

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
        coordinator = SpikeSessionCoordinator()
        owner.value = "owner-a"
        clock.value = qaToday(15)
        trail = []
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

    @discardableResult
    private func makeCenter(verifies: Bool = false) -> ResidentObservationCenter {
        let clock = clock
        let owner = owner
        let made = ResidentObservationCenter(
            coordinator: coordinator, store: nil, location: location, calendar: .current,
            now: { clock.value }, mediaNow: { CACurrentMediaTime() }, makeFrameProbe: { SpikeFrameProbe() },
            ownerUID: { owner.value }, stamp: { qaReleaseStamp() },
            installsFollowerProbe: false, isAppActive: { true },
            verifiesSeed: verifies, seedTrail: { [unowned self] in self.trail.append($0) }
        )
        center = made
        made.activate()
        return made
    }

    /// What the erase does to this center, in the eraser's order: the epoch
    /// first; the session (signed out, or — an account switch — already the
    /// account switched to); the wipe; the center's forget, last.
    private func erase(_ center: ResidentObservationCenter, keepingSession: Bool, switchedTo: String? = "owner-b") {
        LocalDataEraseEpoch.bump()
        owner.value = keepingSession ? switchedTo : nil
        SpikeRunStore.wipe(location: location)
        center.forgetAfterErase()
    }

    private func allLines() -> [(file: String, raw: Data, run: SpikeRun?)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: location.directory.path)) ?? []
        var out: [(String, Data, SpikeRun?)] = []
        for name in names.sorted() where name.hasSuffix(".jsonl") {
            let data = (try? Data(contentsOf: location.directory.appendingPathComponent(name))) ?? Data()
            for raw in data.split(separator: 0x0A) {
                out.append((name, Data(raw), try? ObsReadQAOracle.decoder().decode(SpikeRun.self, from: Data(raw))))
            }
        }
        return out
    }

    private func dailies() -> [SpikeRun] {
        SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.residentDailySpikeID, location: location)
    }

    private func windows() -> [SpikeRun] {
        SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.effortPathFixID, location: location)
    }

    private struct PreErase {
        var ids: Set<UUID>
        var erasedAt: Date
    }

    /// The pre-erase world: a day under owner A with 7 visible + 3 hidden
    /// counted (part of it on disk, part only in memory) and an auto-window
    /// open. Returns what must never come back.
    private func dirtyDay(_ center: ResidentObservationCenter) throws -> PreErase {
        qaVisible(5)
        qaHidden(3)
        center.flushDaily()
        let written = try XCTUnwrap(dailies().first, "liveness: the pre-erase day is on disk")
        XCTAssertEqual(written.ownerUID, "owner-a")
        qaVisible(2)
        qaTap()
        XCTAssertNotNil(center.window, "liveness: an auto-window is open")
        return PreErase(ids: [written.id], erasedAt: clock.value)
    }

    /// Nothing on disk is the pre-erase day: no pre-erase id's text in any
    /// byte, no day line carrying a pre-erase count, no window that opened
    /// before the erase, and no line under `forbiddenOwner`.
    private func assertNothingFromBeforeTheErase(_ pre: PreErase, forbiddenOwner: String?, maxVisible: Int,
                                                 file: StaticString = #filePath, line: UInt = #line) {
        let lines = allLines()
        for (name, raw, run) in lines {
            let text = String(decoding: raw, as: UTF8.self).uppercased()
            for id in pre.ids {
                XCTAssertFalse(text.contains(id.uuidString), "\(name): the pre-erase id \(id) came back", file: file, line: line)
            }
            guard let run else { continue }
            if let forbiddenOwner {
                XCTAssertNotEqual(run.ownerUID, forbiddenOwner, "\(name): a line under the erased owner", file: file, line: line)
            }
            if run.spikeID == FixObservationRegistry.residentDailySpikeID {
                let counters = ResidentCounterSet(metrics: run.metrics)
                XCTAssertEqual(counters.meComputedHidden, 0, "\(name): a pre-erase hidden count came back", file: file, line: line)
                XCTAssertLessThanOrEqual(counters.meComputedVisible, maxVisible, "\(name): pre-erase visible counts came back", file: file, line: line)
            } else {
                XCTAssertGreaterThanOrEqual(run.startedAt, pre.erasedAt.addingTimeInterval(-1),
                                            "\(name): a window opened before the erase", file: file, line: line)
            }
        }
    }

    // MARK: Signed out, and account kept

    func testSignedOutEraseThenEveryWriterOfTheDay() throws {
        try LocalDataEraseEpoch.withIsolatedEpoch {
            let center = makeCenter()
            let pre = try dirtyDay(center)
            erase(center, keepingSession: false)
            XCTAssertNil(center.window, "the open window is gone")
            XCTAssertFalse(FileManager.default.fileExists(atPath: location.directory.path), "the forget wrote nothing")

            qaVisible(2)
            center.closeWindow()
            center.flushDaily()
            // A lifecycle edge's writes, without posting the app-wide notification.
            center.closeWindow(outcome: .completed, closedByResign: true)
            center.flushForManualUpload()
            clock.value = clock.value.addingTimeInterval(60)
            qaVisible(1)
            center.flushForManualUpload()

            assertNothingFromBeforeTheErase(pre, forbiddenOwner: "owner-a", maxVisible: 3)
            let day = try XCTUnwrap(dailies().first, "liveness: the post-erase day was written")
            XCTAssertNil(day.ownerUID, "signed out: the day is ownerless")
            XCTAssertEqual(ResidentCounterSet(metrics: day.metrics).meComputedVisible, 3, "only what was counted after")
            XCTAssertEqual(day.revision, 2, "a fresh id, appended twice")
        }
    }

    func testAccountSwitchEraseWritesOnlyTheNewAccountsDay() throws {
        try LocalDataEraseEpoch.withIsolatedEpoch {
            let center = makeCenter()
            let pre = try dirtyDay(center)
            erase(center, keepingSession: true, switchedTo: "owner-b")
            qaVisible(2)
            center.closeWindow()
            center.flushDaily()
            assertNothingFromBeforeTheErase(pre, forbiddenOwner: "owner-a", maxVisible: 2)
            let day = try XCTUnwrap(dailies().first)
            XCTAssertEqual(day.ownerUID, "owner-b")
            XCTAssertEqual(ResidentCounterSet(metrics: day.metrics).meComputedVisible, 2)
        }
    }

    /// Positive control for both: the same steps without the forget bring
    /// the pre-erase day back — so the assertions above can see it.
    func testControlWithoutTheForgetThePreEraseDayComesBack() throws {
        let center = makeCenter()
        let pre = try dirtyDay(center)
        owner.value = nil
        SpikeRunStore.wipe(location: location)
        center.closeWindow()
        center.flushDaily()
        let lines = allLines()
        XCTAssertTrue(lines.contains { $0.run.map { pre.ids.contains($0.id) } ?? false }, "control: the pre-erase id is back")
        XCTAssertTrue(lines.contains { $0.run?.ownerUID == "owner-a" }, "control: under the erased owner")
        XCTAssertFalse(windows().isEmpty, "control: the pre-erase window is back")
    }

    // MARK: Midnight

    /// A signal just after midnight schedules the rollover hop and lands in
    /// yesterday's counters; the erase arrives before the hop runs. The hop
    /// must not close yesterday's (pre-erase) day.
    func testEraseBetweenAPostMidnightSignalAndItsRolloverHop() throws {
        try LocalDataEraseEpoch.withIsolatedEpoch {
            clock.value = qaToday(23, 50)
            let center = makeCenter()
            let pre = try dirtyDay(center)
            clock.value = qaToday(23, 59, 59).addingTimeInterval(11)   // 00:00:10 tomorrow
            qaVisible(1)                                                // schedules the hop
            erase(center, keepingSession: false)
            qaSpin(0.2)                                                 // the hop runs now
            XCTAssertFalse(FileManager.default.fileExists(atPath: location.directory.path), "the hop wrote nothing")
            qaVisible(2)
            center.flushDaily()
            assertNothingFromBeforeTheErase(pre, forbiddenOwner: "owner-a", maxVisible: 2)
            let day = try XCTUnwrap(dailies().first)
            XCTAssertEqual(day.dayKey, TelemetryClaimKey.dayKey(forDayStart: Calendar.current.startOfDay(for: clock.value),
                                                                calendar: .current).dayKey, "the new day's key")
        }
    }

    /// Erased a few seconds before midnight; the next signal is after it.
    /// The rollover then closes the POST-erase day at its end and starts the
    /// next — only post-erase counts in either.
    func testEraseJustBeforeMidnightThenTheRollover() throws {
        try LocalDataEraseEpoch.withIsolatedEpoch {
            clock.value = qaToday(23, 0)
            let center = makeCenter()
            let pre = try dirtyDay(center)
            clock.value = qaToday(23, 59, 50)
            erase(center, keepingSession: false)
            qaVisible(1)
            clock.value = qaToday(23, 59, 59).addingTimeInterval(6)
            qaVisible(1)
            qaSpin(0.2)
            center.flushDaily()
            assertNothingFromBeforeTheErase(pre, forbiddenOwner: "owner-a", maxVisible: 2)
            XCTAssertEqual(dailies().count, 2, "the post-erase day closed at midnight, and the next one")
        }
    }

    // MARK: The auto-window

    /// The open window's own deadline passes after the erase; then a new
    /// window opens and closes. Nothing of the pre-erase window is written,
    /// and the new window holds only its own gestures.
    func testAWindowOpenAtTheEraseNeverClosesAndTheNextIsClean() throws {
        try LocalDataEraseEpoch.withIsolatedEpoch {
            let center = makeCenter()
            let pre = try dirtyDay(center)
            erase(center, keepingSession: false)
            qaSpin(ResidentWindowModel.durationSeconds + 0.5)
            XCTAssertTrue(windows().isEmpty, "the cancelled deadline wrote no window")

            clock.value = clock.value.addingTimeInterval(30)
            qaTap()
            XCTAssertNotNil(center.window, "liveness: a post-erase window opened")
            center.closeWindow()
            let window = try XCTUnwrap(windows().first)
            if case .number(let gestures)? = window.metrics["wGestures"] {
                XCTAssertLessThanOrEqual(gestures, 1, "at most the post-erase trigger")
            } else {
                XCTFail("the window carries its gesture count")
            }
            assertNothingFromBeforeTheErase(pre, forbiddenOwner: "owner-a", maxVisible: 0)
        }
    }

    // MARK: Another account afterwards

    func testSignedOutEraseThenSignInToAnotherAccount() throws {
        try LocalDataEraseEpoch.withIsolatedEpoch {
            let center = makeCenter()
            let pre = try dirtyDay(center)
            erase(center, keepingSession: false)
            qaVisible(1)
            center.flushDaily()
            owner.value = "owner-b"
            qaVisible(2)
            center.flushDaily()   // closes the signed-out id under its own claim, mints B's
            qaVisible(4)
            center.flushDaily()
            assertNothingFromBeforeTheErase(pre, forbiddenOwner: "owner-a", maxVisible: 4)
            let days = dailies()
            let byOwner = Dictionary(grouping: days, by: { $0.ownerUID ?? "nil" })
            XCTAssertEqual(Set(byOwner.keys), ["nil", "owner-b"])
            let total = days.reduce(0) { $0 + ResidentCounterSet(metrics: $1.metrics).meComputedVisible }
            XCTAssertEqual(total, 7, "every post-erase count once, none from before")
        }
    }

    // MARK: The launch seed's background check

    private func todaysLineUnderA(hidden: Int) {
        var counters = ResidentCounterSet()
        counters.meComputedHidden = hidden
        counters.meComputedVisible = 4
        var run = SpikeRun(
            id: UUID(), spikeID: FixObservationRegistry.residentDailySpikeID,
            scenarioID: FixObservationRegistry.residentDailyScenarioID, variantID: nil,
            startedAt: clock.value.addingTimeInterval(-3_600), endedAt: clock.value.addingTimeInterval(-60),
            appVersion: "0.5.0", appBuild: "10", appCommit: nil, deviceModel: "iPhone17,2", osVersion: "26.0",
            timeZoneIdentifier: "UTC", localeIdentifier: "en_US", buildConfiguration: "release",
            metrics: counters.metrics, note: nil, outcome: .completed, abortReason: nil)
        run.ownerUID = "owner-a"
        run.revision = 3
        run.kind = .dailyRollup
        try? FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
        try? ObsReadQABytes.line(run).write(to: location.directory.appendingPathComponent("\(FixObservationRegistry.residentDailySpikeID).jsonl"))
    }

    private func waitForVerification(_ center: ResidentObservationCenter) {
        let deadline = Date().addingTimeInterval(10)
        while center.seedVerification == .pending && Date() < deadline { qaSpin(0.01) }
    }

    /// Control: with no erase the check comes back and logs one line.
    func testControlTheSeedCheckDeliversWithoutAnErase() {
        todaysLineUnderA(hidden: 2)
        let center = makeCenter(verifies: true)
        waitForVerification(center)
        guard case .logged(let report) = center.seedVerification else {
            return XCTFail("control: expected a logged report, got \(center.seedVerification)")
        }
        XCTAssertEqual(report.result, .agree)
        XCTAssertEqual(trail.count, 1)
    }

    /// The erase lands while the background read is still running.
    func testEraseDuringTheSeedChecksReadDropsItAndWritesNothing() {
        LocalDataEraseEpoch.withIsolatedEpoch {
            todaysLineUnderA(hidden: 2)
            let center = makeCenter(verifies: true)
            XCTAssertEqual(center.seedVerification, .pending)
            erase(center, keepingSession: false)
            waitForVerification(center)
            XCTAssertEqual(center.seedVerification, .dropped(reason: "erase"))
            XCTAssertEqual(trail, ["resident.seed.verify result=dropped reason=erase"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: location.directory.path), "the check wrote nothing")
            center.flushDaily()
            XCTAssertTrue(dailies().allSatisfy { ResidentCounterSet(metrics: $0.metrics).meComputedHidden == 0 },
                          "the adopted pre-erase day is not written back")
        }
    }

    /// Each way an erase can reach the check, alone: the center told (an
    /// erase the epoch did not see), the epoch bumped (one the center was not
    /// told of), and the owner gone. Any one of them drops the result.
    func testEachDropReasonAloneDropsTheSeedCheck() {
        LocalDataEraseEpoch.withIsolatedEpoch {
            todaysLineUnderA(hidden: 2)
            let byCenter = makeCenter(verifies: true)
            byCenter.forgetAfterErase()
            waitForVerification(byCenter)
            XCTAssertEqual(byCenter.seedVerification, .dropped(reason: "erase"), "the center's forget alone")
            byCenter.deactivate()

            trail = []
            todaysLineUnderA(hidden: 2)
            let byEpoch = makeCenter(verifies: true)
            LocalDataEraseEpoch.bump()
            waitForVerification(byEpoch)
            XCTAssertEqual(byEpoch.seedVerification, .dropped(reason: "erase"), "the epoch alone")
            byEpoch.deactivate()

            trail = []
            todaysLineUnderA(hidden: 2)
            let byOwner = makeCenter(verifies: true)
            owner.value = "owner-b"
            waitForVerification(byOwner)
            XCTAssertEqual(byOwner.seedVerification, .dropped(reason: "owner"), "the owner alone")
            XCTAssertEqual(trail, ["resident.seed.verify result=dropped reason=owner"])
        }
    }

    /// The read finished before the erase; only its delivery comes after.
    func testEraseAfterTheSeedChecksReadButBeforeItsDeliveryDropsIt() {
        LocalDataEraseEpoch.withIsolatedEpoch {
            todaysLineUnderA(hidden: 2)
            let center = makeCenter(verifies: true)
            Thread.sleep(forTimeInterval: 0.5)     // the read completes; its delivery waits for the main queue
            XCTAssertEqual(center.seedVerification, .pending, "rig: delivery not yet run")
            erase(center, keepingSession: true, switchedTo: "owner-a")
            waitForVerification(center)
            XCTAssertEqual(center.seedVerification, .dropped(reason: "erase"))
            XCTAssertFalse(trail.contains { $0.contains("result=agree") || $0.contains("idsToday") })
        }
    }

    // MARK: On the wire

    /// End to end with the real uploader on a fake server: account A uploads
    /// its day; the account switches to B with the erase; B's counts upload.
    /// No request after the erase carries the pre-erase id, owner A, or a
    /// pre-erase count; and after a later sign-in as A again, A's server row
    /// still holds the pre-erase revision — nothing re-sent it.
    func testNothingFromBeforeTheEraseIsUploadedAfterIt() async throws {
        let suite = "ObsReadQAEraseTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let user = QABox<String>(TelemetryFixtures.uid)
        let serverA = SyncFakeServer(userId: TelemetryFixtures.uid)
        let serverB = SyncFakeServer(userId: TelemetryFixtures.otherUID)
        owner.value = TelemetryFixtures.uid
        clock.value = Date()

        var deps = TelemetryUploader.Dependencies()
        deps.defaults = defaults
        deps.location = location
        deps.now = { [clock] in clock.value }
        deps.launchDelay = 0
        deps.makeKeepAlive = { nil }
        deps.bootstrapOwner = { nil }
        let uploader = TelemetryUploader(dependencies: deps)
        func attach(_ server: SyncFakeServer) {
            uploader.attach(TelemetryUploader.Attachment(
                gateway: server, isBlockedByBuild: { false },
                currentUserID: { user.value }, isSignedIn: { true }))
        }
        attach(serverA)
        defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        TelemetryConsentStore.recordGrant(defaults, at: clock.value.addingTimeInterval(-3_600))

        let center = makeCenter()
        uploader.connect(center: center)
        qaVisible(5)
        qaHidden(3)
        center.flushDaily()
        await uploader.drain()
        let preDay = try XCTUnwrap(dailies().first)
        let preRow = try XCTUnwrap(serverA.telemetryRow(runID: preDay.id), "liveness: A's day reached the server")
        let preRevision = preRow.revision
        let requestsBefore = serverA.requests(.telemetryUpsert).count
        qaVisible(2)

        // The account switch: the session is B's, then the erase.
        user.value = TelemetryFixtures.otherUID
        owner.value = TelemetryFixtures.otherUID
        attach(serverB)
        LocalDataEraseEpoch.withIsolatedEpoch {
            LocalDataEraseEpoch.bump()
            SpikeRunStore.wipe(location: location)
            uploader.forgetAfterErase()
            center.forgetAfterErase()
        }
        qaVisible(4)
        clock.value = clock.value.addingTimeInterval(60)
        center.flushDaily()
        await uploader.drain()

        let rowsB = serverB.requests(.telemetryUpsert).flatMap { ($0.body as? [[String: Any]]) ?? [] }
        XCTAssertFalse(rowsB.isEmpty, "liveness: B's day was uploaded")
        for row in rowsB {
            XCTAssertNotEqual((row["run_id"] as? String)?.lowercased(), preDay.id.uuidString.lowercased(), "the pre-erase id went out")
            XCTAssertEqual(row["user_id"] as? String, TelemetryFixtures.otherUID)
            let metrics = row["metrics"] as? [String: Any] ?? [:]
            XCTAssertEqual((metrics["meComputedHidden"] as? NSNumber)?.intValue ?? 0, 0, "a pre-erase count went out")
            XCTAssertEqual((metrics["meComputedVisible"] as? NSNumber)?.intValue, 4, "only B's counts")
        }

        // Back to A: whatever A's phone writes now, the pre-erase day is not
        // in it and A's server row is untouched.
        user.value = TelemetryFixtures.uid
        owner.value = TelemetryFixtures.uid
        attach(serverA)
        qaVisible(1)
        clock.value = clock.value.addingTimeInterval(60)
        center.flushDaily()
        await uploader.drain()
        for request in serverA.requests(.telemetryUpsert).dropFirst(requestsBefore) {
            XCTAssertFalse(request.keys.map { $0.lowercased() }.contains(preDay.id.uuidString.lowercased()),
                           "the pre-erase id was re-sent to A")
        }
        XCTAssertEqual(serverA.telemetryRow(runID: preDay.id)?.revision, preRevision)
        XCTAssertEqual(serverA.telemetryRow(runID: preDay.id)?.writes, 1, "A's pre-erase row was written once, before the erase")
    }
}

// MARK: - Step 2: the Settings row's dot

@MainActor
final class ObsReadQASettingsRowTests: XCTestCase {
    private var location: SpikeRunStorageLocation!
    private var coordinator: SpikeSessionCoordinator!
    private var center: ResidentObservationCenter?
    private let owner = QABox<String?>("owner-a")
    private let clock = QABox(qaToday(10))
    private let configuration = QABox("release")
    private var triggers: [TelemetryTrigger] = []
    /// Before every entry's review date, so the dot is the alarm alone.
    private let rowNow = Date(timeIntervalSince1970: 1_767_225_600)   // 2026-01-01

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
        coordinator = SpikeSessionCoordinator()
        owner.value = "owner-a"
        clock.value = qaToday(10)
        configuration.value = "release"
        triggers = []
        XCTAssertFalse(FixObservationRegistry.all.contains { FixWatchAttention.isOverdue($0, now: rowNow) },
                       "rig: no entry is overdue at the row's clock")
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

    @discardableResult
    private func launch() -> ResidentObservationCenter {
        center?.deactivate()
        let clock = clock
        let owner = owner
        let configuration = configuration
        let made = ResidentObservationCenter(
            coordinator: coordinator, store: nil, location: location, calendar: .current,
            now: { clock.value }, mediaNow: { 500 }, makeFrameProbe: { SpikeFrameProbe() },
            ownerUID: { owner.value }, stamp: { qaReleaseStamp(configuration: configuration.value) },
            installsFollowerProbe: false, isAppActive: { true }, verifiesSeed: false
        )
        made.onUploadTrigger = { [unowned self] in self.triggers.append($0) }
        made.activate()
        center = made
        return made
    }

    private var dailyURL: URL {
        location.directory.appendingPathComponent("\(FixObservationRegistry.residentDailySpikeID).jsonl")
    }

    private func directorySnapshot() -> [String: Data] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: location.directory.path)) ?? []
        var out: [String: Data] = [:]
        for name in names { out[name] = try? Data(contentsOf: location.directory.appendingPathComponent(name)) }
        return out
    }

    /// The row today: a read, nothing else.
    private func newRow(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let before = directorySnapshot()
        let triggersBefore = triggers.count
        let lit = FixWatchAttention.needsAttention(now: rowNow, location: location, defaults: StatisticsOffDefaults.make())
        XCTAssertEqual(directorySnapshot(), before, "the row wrote", file: file, line: line)
        XCTAssertEqual(triggers.count, triggersBefore, "the row triggered an upload", file: file, line: line)
        return lit
    }

    /// The row at 3111ef1: the deck's barrier (flush today so far, tell the
    /// uploader), then the read.
    private func oldRow() -> Bool {
        ResidentObservationCenter.shared?.flushDaily()
        let verdicts = FixWatchAttention.evaluate(
            dailies: SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.residentDailySpikeID, location: location),
            windows: SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.effortPathFixID, location: location),
            currentSegment: .thisDevice())
        return FixWatchAttention.needsAttention(verdicts: verdicts, entries: FixObservationRegistry.all, now: rowNow)
    }

    /// The 3111ef1 row's verdicts, read right after its flush (no new flush).
    private func oldVerdicts() -> [FixVerdict] {
        FixWatchAttention.evaluate(
            dailies: SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.residentDailySpikeID, location: location),
            windows: SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.effortPathFixID, location: location),
            currentSegment: .thisDevice())
    }

    private func alarmFacts(_ verdicts: [FixVerdict]) -> [String] {
        verdicts.map { verdict in
            let gate = verdict.entryID == FixObservationRegistry.meTabGateFixID
                ? verdict.readouts.map { "\($0.id)=\($0.measured)" }.joined(separator: ",") : ""
            return "\(verdict.entryID) alarm=\(verdict.alarm) \(gate)"
        }
    }

    // MARK: Against the 3111ef1 row, on random histories

    func testTheRowLightsExactlyWhenThe3111ef1RowLit() throws {
        var rng = ObsReadQARandom(seed: 0xD07_0001)
        var lit = 0
        var dark = 0
        var unwrittenAtCheck = 0
        for history in 0..<30 {
            try? FileManager.default.removeItem(at: location.directory)
            owner.value = "owner-a"
            clock.value = qaToday(9)
            configuration.value = "release"
            launch()
            for step in 0..<40 {
                switch Int.random(in: 0..<20, using: &rng) {
                case 0...5: qaVisible(Int.random(in: 1...3, using: &rng))
                case 6: qaHidden(1)
                case 7: center!.flushDaily()
                case 8:
                    // A lifecycle edge's write, without the app-wide notification.
                    center!.flushForManualUpload()
                case 9: owner.value = [nil, "owner-a", "owner-b"].randomElement(using: &rng)!
                case 10: clock.value = clock.value.addingTimeInterval(Double(Int.random(in: 60...20_000, using: &rng)))
                case 11:
                    // Midnight passes with no signal (the deck or the row is the next thing).
                    clock.value = Calendar.current.startOfDay(for: clock.value).addingTimeInterval(86_400 + 60)
                case 12: center!.remintDailyForConsent()
                case 13:
                    // A relaunch, sometimes as another build or a Debug build.
                    if Int.random(in: 0..<3, using: &rng) == 0 { configuration.value = Bool.random(using: &rng) ? "debug" : "release" }
                    launch()
                case 14:
                    if Int.random(in: 0..<4, using: &rng) == 0 {
                        SpikeRunStore.wipe(location: location)
                        center!.forgetAfterErase()
                    }
                default:
                    if center!.unwrittenDailyRecord() != nil { unwrittenAtCheck += 1 }
                    let verdictsNow = FixWatchAttention.loadRowVerdicts(currentSegment: .thisDevice(), location: location)
                    let now = newRow()
                    let then = oldRow()
                    // What the dot stands on: each entry's alarm and the
                    // tripwire's own counts. (Day and non-release counts may
                    // differ: the 3111ef1 flush wrote a zero-count line for a
                    // freshly minted id; the row does not fold one. The dot
                    // never reads them.)
                    XCTAssertEqual(alarmFacts(verdictsNow), alarmFacts(oldVerdicts()),
                                   "history \(history) step \(step): the alarms and the tripwire's counts")
                    XCTAssertEqual(now, then, "history \(history) step \(step): the row \(now ? "lit" : "stayed dark") where the 3111ef1 row \(then ? "lit" : "stayed dark")")
                    if now { lit += 1 } else { dark += 1 }
                }
            }
        }
        XCTAssertGreaterThan(lit, 20, "liveness")
        XCTAssertGreaterThan(dark, 20, "liveness")
        XCTAssertGreaterThan(unwrittenAtCheck, 20, "liveness: the row often had an unwritten day to fold")
    }

    // MARK: Directed

    func testTodaysUnwrittenTripwireAfterAQuietMidnightStillLights() {
        clock.value = qaToday(23, 30)
        launch()
        qaVisible(1)
        qaHidden(1)
        clock.value = qaToday(23, 59, 59).addingTimeInterval(600)   // 00:10, no signal since
        XCTAssertTrue(newRow(), "yesterday's unwritten tripwire")
        XCTAssertTrue(oldRow(), "control: the 3111ef1 row, which rolled the day over first")
    }

    func testATripwireCountedBeforeASignInStillLights() {
        owner.value = nil
        launch()
        qaHidden(1)
        owner.value = "owner-a"
        XCTAssertTrue(newRow())
        XCTAssertTrue(oldRow())
    }

    func testADebugBuildsTripwireLightsNeitherRow() {
        configuration.value = "debug"
        launch()
        qaHidden(2)
        XCTAssertFalse(newRow())
        XCTAssertFalse(oldRow(), "control")
    }

    /// The erase: the dot goes dark with the day (the fix), where without
    /// the forget it would light from the pre-erase day written back.
    func testAfterAnEraseTheDotIsDark() {
        launch()
        qaHidden(1)
        center!.flushDaily()
        qaHidden(1)
        XCTAssertTrue(newRow(), "liveness")
        SpikeRunStore.wipe(location: location)
        center!.forgetAfterErase()
        XCTAssertFalse(newRow())
        XCTAssertFalse(oldRow())
    }

    /// Where the two rows part: a daily file holding 200 ids, the oldest
    /// with a tripwire count, and today's id not yet on disk. The 3111ef1
    /// row's flush added today's id first, so the 200-newest cap pushed the
    /// oldest out and the dot stayed dark; the row now caps the file, then
    /// folds today in, and lights. Reported as a note (it needs more than
    /// 200 day ids between two compactions); pinned so a change is seen.
    func testWithTwoHundredIDsOnDiskTheRowCountsTheOldestOneTheOldRowCappedAway() throws {
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
        var bytes = Data()
        for index in 0..<SpikeRunStore.maxRunsPerSpike {
            var counters = ResidentCounterSet()
            counters.meComputedVisible = 1
            counters.meComputedHidden = index == 0 ? 1 : 0
            var run = ObsReadQABytes.run(
                id: UUID(), spikeID: FixObservationRegistry.residentDailySpikeID,
                startedAt: qaToday(0).addingTimeInterval(-86_400 * Double(SpikeRunStore.maxRunsPerSpike - index)),
                revision: 1, metrics: counters.metrics)
            run.kind = .dailyRollup
            bytes += ObsReadQABytes.line(run)
        }
        try bytes.write(to: dailyURL)
        launch()
        qaVisible(1)
        let now = newRow()
        let then = oldRow()
        XCTAssertTrue(now, "the row counts the oldest record")
        XCTAssertFalse(then, "the 3111ef1 row capped it away")
    }

    // MARK: No write, no upload — with the real uploader

    func testOpeningSettingsSendsNothingAndOpeningTheDeckStillSends() async throws {
        let suite = "ObsReadQASettingsRowTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = SyncFakeServer(userId: TelemetryFixtures.uid)
        owner.value = TelemetryFixtures.uid
        clock.value = Date()
        var deps = TelemetryUploader.Dependencies()
        deps.defaults = defaults
        deps.location = location
        deps.now = { [clock] in clock.value }
        deps.launchDelay = 0
        deps.makeKeepAlive = { nil }
        deps.bootstrapOwner = { nil }
        let uploader = TelemetryUploader(dependencies: deps)
        uploader.attach(TelemetryUploader.Attachment(
            gateway: server, isBlockedByBuild: { false },
            currentUserID: { TelemetryFixtures.uid }, isSignedIn: { true }))
        defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        TelemetryConsentStore.recordGrant(defaults, at: clock.value.addingTimeInterval(-3_600))

        let center = launch()
        uploader.connect(center: center)    // DoneApp's wiring: the center's edges schedule batches
        qaVisible(3)
        qaHidden(1)

        // The row reads the switch the uploader reads: on, so it reads nothing.
        for _ in 0..<3 {                      // an appear and two pop-backs
            let reads = SpikeRunStore.wholeFileReads
            XCTAssertFalse(FixWatchAttention.needsAttention(location: location, defaults: defaults), "uploads on: no dot")
            XCTAssertEqual(SpikeRunStore.wholeFileReads, reads, "uploads on: the row read nothing")
            await uploader.drain()
        }
        // The read path itself (the row with statistics off) still writes and sends nothing.
        let statisticsOff = StatisticsOffDefaults.make()
        for _ in 0..<3 {
            let reads = SpikeRunStore.wholeFileReads
            _ = FixWatchAttention.needsAttention(location: location, defaults: statisticsOff)
            XCTAssertGreaterThan(SpikeRunStore.wholeFileReads, reads, "positive control: with statistics off the row read")
            await uploader.drain()
        }
        XCTAssertEqual(server.requests(.telemetryUpsert).count, 0, "Settings sent nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dailyURL.path), "Settings wrote nothing")

        _ = FixWatchAttention.loadLocalRecords()    // the deck's appear
        await uploader.drain()
        XCTAssertEqual(server.requests(.telemetryUpsert).count, 1, "control: the deck still flushes and sends")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dailyURL.path))
    }
}

// MARK: - Step 4: the healing newline

@MainActor
final class ObsReadQAHealingTests: XCTestCase {
    private var location: SpikeRunStorageLocation!

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
        try? FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        SpikeRunStore.ownerProvider = nil
        try? FileManager.default.removeItem(at: location.directory)
        location = nil
        super.tearDown()
    }

    private var url: URL { location.directory.appendingPathComponent("\(FixObservationRegistry.residentDailySpikeID).jsonl") }

    /// Every tear point of a line, followed by the store's next append: the
    /// appended record always reads back, in this build and in the installed
    /// one; the bytes are exactly torn + `\n` + the line; and nothing else
    /// changes. Control: the same append without the heal (the installed
    /// build's append) loses it.
    func testAnAppendAfterATearAtEveryOffsetReadsBack() throws {
        let first = TelemetryFixtures.run(id: UUID(), startedAt: TelemetryFixtures.t0, revision: 1)
        let torn = TelemetryFixtures.run(id: UUID(), startedAt: TelemetryFixtures.t0.addingTimeInterval(60), note: "观察站 🙂", revision: 1)
        let tornLine = ObsReadQABytes.line(torn)
        var glued = 0
        for cut in 1..<tornLine.count {
            let prefix = ObsReadQABytes.line(first) + tornLine.prefix(cut)
            try prefix.write(to: url)
            let next = TelemetryFixtures.run(id: UUID(), startedAt: TelemetryFixtures.t0.addingTimeInterval(120), revision: nil)
            XCTAssertTrue(SpikeRunStore.finishRun(next, owner: .explicit(TelemetryFixtures.uid), location: location))
            let after = try Data(contentsOf: url)
            XCTAssertEqual(after.prefix(prefix.count), prefix, "cut \(cut): what was there is untouched")
            let added = after.suffix(from: prefix.count)
            XCTAssertEqual(added.first, 0x0A, "cut \(cut): the heal comes first")
            XCTAssertEqual(added.dropFirst().filter { $0 == 0x0A }.count, 1, "cut \(cut): one line after it")
            let ids = ObsReadQAOracle.records(after).map(\.id)
            XCTAssertTrue(ids.contains(next.id), "cut \(cut): the appended record reads back in the installed reader")
            XCTAssertEqual(SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.residentDailySpikeID, location: location,
                                                  applyRetention: false).map(\.id),
                           ObsReadQAOracle.collapse(ObsReadQAOracle.records(after)).map(\.id), "cut \(cut): both readers agree")
            XCTAssertTrue(ids.contains(first.id))
            // Control: the installed build's append glues the two.
            let glue = prefix + ObsReadQABytes.line(next)
            if !ObsReadQAOracle.records(glue).map(\.id).contains(next.id) { glued += 1 }
            try FileManager.default.removeItem(at: url)
        }
        XCTAssertGreaterThan(glued, tornLine.count / 2, "control: without the heal the next record is lost")

        // A file whose last line is whole gets no newline of the store's: the
        // append is exactly one line, no blank line before it.
        let whole = ObsReadQABytes.line(first)
        try whole.write(to: url)
        let next = TelemetryFixtures.run(id: UUID(), startedAt: TelemetryFixtures.t0.addingTimeInterval(180), revision: nil)
        XCTAssertTrue(SpikeRunStore.finishRun(next, owner: .explicit(TelemetryFixtures.uid), location: location))
        let after = try Data(contentsOf: url)
        XCTAssertNotEqual(after[whole.count], 0x0A, "no blank line after a whole last line")
        XCTAssertEqual(after.split(separator: 0x0A, omittingEmptySubsequences: false).count, 3, "two lines and the final newline")
    }

    /// The upload a heal makes possible, and nothing else: the same rows as a
    /// file that was never torn, plus nothing from the torn line.
    func testTheUploadAfterAHealIsTheUploadOfAFileThatWasNeverTorn() async throws {
        let first = TelemetryFixtures.run(id: UUID(), startedAt: TelemetryFixtures.t0, revision: nil)
        let torn = TelemetryFixtures.run(id: UUID(), startedAt: TelemetryFixtures.t0.addingTimeInterval(30), revision: 1)
        let next = TelemetryFixtures.run(id: UUID(), startedAt: TelemetryFixtures.t0.addingTimeInterval(60), revision: nil)
        let install = UUID()

        func rows(tear: Bool) async throws -> [String] {
            let here = SpikeRunStorageLocation.ephemeral(id: UUID())
            defer { try? FileManager.default.removeItem(at: here.directory) }
            try FileManager.default.createDirectory(at: here.directory, withIntermediateDirectories: true)
            try Data(install.uuidString.utf8).write(to: SpikeRunStore.installIDURL(location: here))
            XCTAssertTrue(SpikeRunStore.finishRun(first, owner: .explicit(TelemetryFixtures.uid), location: here))
            if tear {
                let fileURL = here.directory.appendingPathComponent("\(FixObservationRegistry.residentDailySpikeID).jsonl")
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: ObsReadQABytes.line(torn).prefix(200))
                try handle.close()
            }
            XCTAssertTrue(SpikeRunStore.finishRun(next, owner: .explicit(TelemetryFixtures.uid), location: here))
            let suite = "ObsReadQAHealingTests-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            var deps = TelemetryUploader.Dependencies()
            deps.defaults = defaults
            deps.location = here
            deps.now = { TelemetryFixtures.t0.addingTimeInterval(3_600) }
            deps.launchDelay = 0
            deps.makeKeepAlive = { nil }
            deps.bootstrapOwner = { nil }
            let uploader = TelemetryUploader(dependencies: deps)
            let server = SyncFakeServer(userId: TelemetryFixtures.uid)
            uploader.attach(TelemetryUploader.Attachment(gateway: server, isBlockedByBuild: { false },
                                                         currentUserID: { TelemetryFixtures.uid }, isSignedIn: { true }))
            defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
            TelemetryConsentStore.recordGrant(defaults, at: TelemetryFixtures.t0.addingTimeInterval(-3_600))
            _ = await uploader.uploadNow(trigger: .launch)
            return server.requests(.telemetryUpsert).flatMap { ($0.body as? [[String: Any]]) ?? [] }.map { row in
                String(decoding: try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self)
            }.sorted()
        }

        let clean = try await rows(tear: false)
        let healed = try await rows(tear: true)
        XCTAssertEqual(clean.count, 2, "liveness: both records upload from the clean file")
        XCTAssertEqual(healed, clean, "the healed file uploads exactly what the clean one does")
    }
}
