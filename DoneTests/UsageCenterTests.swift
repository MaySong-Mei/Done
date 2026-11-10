//
//  UsageCenterTests.swift
//  DoneTests
//
//  gh#273 §6.3 through the real resident center: the `usage-daily` record
//  rides the resident's claim, day and flush edges; visits settle through
//  the real lifecycle notifications (design §11 item 16: background pauses,
//  a used visit is not abandoned, a visit killed in the background never
//  settles); sessions count returns from background and nothing else; the
//  launch seed drops unknown keys; the erase forgets the open visits; the
//  uploaded row carries only registry keys with whole numbers or fixed
//  buckets. And design §11 item 13 with the real detail view on screen: a
//  pop back from a pushed page does not count a second enter.
//

import XCTest
import SwiftUI
import UIKit
@testable import Done

@MainActor
final class UsageCenterTests: XCTestCase {
    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private var location: SpikeRunStorageLocation!
    private var coordinator: SpikeSessionCoordinator!
    private var centers: [ResidentObservationCenter] = []
    private var displacedSink: UsageSink?
    private var displacedRecorder: FollowerTimingRecorder?

    private let uid = TelemetryFixtures.uid
    private var la: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()
    /// 10:00 in Los Angeles on 2026-09-21.
    private let morning: Date = ISO8601DateFormatter().date(from: "2026-09-21T17:00:00Z")!

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
        coordinator = SpikeSessionCoordinator()
        displacedSink = UsageProbe.sink
        displacedRecorder = FollowerTiming.recorder
        FollowerTiming.recorder = nil
    }

    override func tearDown() {
        for center in centers { center.deactivate() }
        centers = []
        UsageProbe.sink = displacedSink
        FollowerTiming.recorder = displacedRecorder
        SpikeProbe.onSignal = nil
        try? FileManager.default.removeItem(at: location.directory)
        super.tearDown()
    }

    private func stamp(build: String = "29") -> SpikeRunContext.Stamp {
        SpikeRunContext.Stamp(appVersion: "0.5.0", appBuild: build, appCommit: nil, deviceModel: "iPhone17,2",
                              osVersion: "26.0", timeZoneIdentifier: "America/Los_Angeles",
                              localeIdentifier: "en_US", buildConfiguration: "release")
    }

    private func makeCenter(
        clock: Box<Date>, media: Box<Double>, owner: Box<String?>? = nil,
        countsLaunchSession: Bool = false, foreground: Bool = true, activate: Bool = true,
        gates: Box<Set<UsageGate>> = Box([])
    ) -> ResidentObservationCenter {
        let ownerBox = owner ?? Box<String?>(uid)
        let center = ResidentObservationCenter(
            coordinator: coordinator, store: nil, location: location, calendar: la,
            now: { clock.value }, mediaNow: { media.value },
            makeFrameProbe: { SpikeFrameProbe() },
            ownerUID: { ownerBox.value }, stamp: { [unowned self] in self.stamp() },
            installsFollowerProbe: false, isAppActive: { foreground }, verifiesSeed: false,
            seedTrail: { _ in }, countsLaunchSession: countsLaunchSession, isAppForeground: { foreground },
            availableGates: { gates.value }
        )
        centers.append(center)
        if activate { center.activate() }
        return center
    }

    private func usageRecords() -> [SpikeRun] {
        SpikeRunStore.loadRuns(spikeID: UsageRecordIDs.spikeID, location: location)
    }

    private func onlyUsageRecord(file: StaticString = #filePath, line: UInt = #line) throws -> SpikeRun {
        let records = usageRecords()
        XCTAssertEqual(records.count, 1, "one usage record", file: file, line: line)
        return try XCTUnwrap(records.first, file: file, line: line)
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }

    private func n(_ run: SpikeRun, _ key: String) -> Int? {
        if case .number(let value)? = run.metrics[key] { return Int(value) }
        return nil
    }

    // MARK: The record

    /// A center whose launch session was not counted (the test host's)
    /// carries nothing into a re-minted record: the consent re-mint writes no
    /// usage line of its own. Positive control: a counted launch is carried.
    func testOnlyACountedSessionIsCarriedIntoAReMintedRecord() throws {
        let uncounted = makeCenter(clock: Box(morning), media: Box(0))
        uncounted.remintDailyForConsent()
        XCTAssertEqual(usageRecords().count, 0, "no session was counted, so there is nothing to carry")
        uncounted.deactivate()

        let counted = makeCenter(clock: Box(morning.addingTimeInterval(60)), media: Box(0), countsLaunchSession: true)
        counted.remintDailyForConsent()
        let records = usageRecords()
        XCTAssertEqual(records.count, 2, "the launch's line, closed, and the consent line")
        XCTAssertTrue(records.allSatisfy { n($0, "sessions") == 1 }, "the running session is the re-minted line's denominator")
    }

    func testTheUsageRecordRidesTheResidentsClaimDayAndFlush() throws {
        let clock = Box(morning)
        let media = Box(100.0)
        let center = makeCenter(clock: clock, media: media)
        XCTAssertTrue(UsageProbe.sink === center, "activation installs the sink")

        UsageProbe.enter(.createPlus)
        UsageProbe.done(.create)
        UsageProbe.done(.createAllDay)
        media.value = 108
        UsageProbe.leave(.create, via: .createCancel)
        post(UIApplication.willResignActiveNotification)

        let usage = try onlyUsageRecord()
        let daily = try XCTUnwrap(SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.residentDailySpikeID, location: location).first)
        XCTAssertEqual(usage.spikeID, "usage-daily")
        XCTAssertEqual(usage.resolvedKind, .dailyRollup)
        XCTAssertEqual(usage.dayKey, daily.dayKey, "the resident's civil day")
        XCTAssertEqual(usage.dayTZOffsetMin, daily.dayTZOffsetMin)
        XCTAssertEqual(TelemetryClaimKey(run: usage), TelemetryClaimKey(run: daily), "the resident's claim")
        XCTAssertEqual(usage.ownerUID, uid)
        XCTAssertNotEqual(usage.id, daily.id, "its own id")
        XCTAssertEqual(usage.revision, 1)
        XCTAssertEqual(usage.metrics, [
            "usage.create.enter.plus": .number(1),
            "usage.create.done": .number(1),
            "usage.create.done.all_day": .number(1),
            "usage.create.dwell": .string("0 1 0 0"),
        ], "only what was counted: no zero key, no abandonment for a done visit")

        // Dirty check: a second edge with nothing new writes nothing.
        post(UIApplication.didBecomeActiveNotification)
        post(UIApplication.willResignActiveNotification)
        XCTAssertEqual(usageRecords().first?.revision, 1)
    }

    func testADayWithNoUsageWritesNoUsageLine() {
        let center = makeCenter(clock: Box(morning), media: Box(0))
        center.flushDaily()
        XCTAssertEqual(usageRecords().count, 0)
        XCTAssertEqual(SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.residentDailySpikeID, location: location).count, 1,
                       "positive control: the flush did run")
    }

    func testASameDayRelaunchAdoptsTheUsageLineAndSumsIntoIt() throws {
        let clock = Box(morning)
        let first = makeCenter(clock: clock, media: Box(0))
        UsageProbe.use(.allDayToggle)
        first.flushDaily()
        first.deactivate()
        let written = try onlyUsageRecord()

        clock.value = morning.addingTimeInterval(3600)
        let second = makeCenter(clock: clock, media: Box(0))
        if case .found(let adopted, _) = second.usageLaunchSeed {
            XCTAssertEqual(adopted.id, written.id)
        } else {
            XCTFail("the relaunch did not adopt today's usage line: \(second.usageLaunchSeed)")
        }
        UsageProbe.use(.allDayToggle)
        second.flushDaily()
        let summed = try onlyUsageRecord()
        XCTAssertEqual(summed.id, written.id)
        XCTAssertEqual(summed.revision, 2)
        XCTAssertEqual(n(summed, "usage.all_day.use"), 2)

        // A different build the same day is a different claim: a new line.
        second.deactivate()
        let user = uid
        let otherBuild = ResidentObservationCenter(
            coordinator: coordinator, store: nil, location: location, calendar: la,
            now: { clock.value }, mediaNow: { 0 }, ownerUID: { user }, stamp: { [unowned self] in self.stamp(build: "30") },
            installsFollowerProbe: false, verifiesSeed: false, seedTrail: { _ in },
            countsLaunchSession: false, isAppForeground: { true }
        )
        centers.append(otherBuild)
        otherBuild.activate()
        UsageProbe.use(.allDayToggle)
        otherBuild.flushDaily()
        XCTAssertEqual(usageRecords().count, 2)
    }

    func testAnUnknownKeyOnDiskIsDroppedAtSeedAndTheLineRewrittenWithoutIt() throws {
        var line = TelemetryFixtures.run(spikeID: UsageRecordIDs.spikeID, scenarioID: UsageRecordIDs.scenarioID,
                                         startedAt: morning, endedAt: morning.addingTimeInterval(60), appBuild: "29",
                                         metrics: ["usage.all_day.use": .number(3), "usage.retired.enter.tap": .number(7)])
        line.dayKey = "2026-09-21"
        XCTAssertTrue(SpikeRunStore.finishRun(line, owner: .explicit(uid), location: location))

        let center = makeCenter(clock: Box(morning.addingTimeInterval(600)), media: Box(0))
        XCTAssertEqual(center.usageUnknownKeyDrops, 1, "the key this build does not register")
        XCTAssertEqual(center.usage.counts.count("usage.all_day.use"), 3, "the known key is kept")
        center.flushDaily()
        let rewritten = try onlyUsageRecord()
        XCTAssertEqual(rewritten.id, line.id)
        XCTAssertEqual(rewritten.metrics, ["usage.all_day.use": .number(3)], "rewritten at once, without the unknown key")
    }

    // MARK: Visits through the lifecycle (design §11 item 16)

    func testBackgroundPausesTheVisitAndTheReturnIsOneSessionNotAnEnter() throws {
        let clock = Box(morning)
        let media = Box(0.0)
        let center = makeCenter(clock: clock, media: media)
        UsageProbe.enter(.eventDetailCanvas)
        media.value = 1
        post(UIApplication.willResignActiveNotification)
        post(UIApplication.didEnterBackgroundNotification)
        media.value = 601                       // ten minutes away
        post(UIApplication.willEnterForegroundNotification)
        post(UIApplication.didBecomeActiveNotification)
        media.value = 606                       // five seconds back
        UsageProbe.leave(.eventDetail)
        center.flushDaily()

        let usage = try onlyUsageRecord()
        XCTAssertEqual(usage.metrics["usage.event_detail.dwell"], .string("0 1 0 0"), "6 s of foreground, not 606 s")
        XCTAssertEqual(n(usage, "usage.event_detail.abandon"), 1)
        XCTAssertEqual(n(usage, "usage.event_detail.enter.canvas"), 1, "the return is not an enter")
        XCTAssertEqual(n(usage, "sessions"), 1, "two notifications, one return")
    }

    func testAUsedVisitIsNotAbandoned() throws {
        let center = makeCenter(clock: Box(morning), media: Box(0))
        UsageProbe.enter(.eventDetailSearch)
        UsageProbe.use(.eventDetailDelete)
        UsageProbe.leave(.eventDetail)
        center.flushDaily()
        let usage = try onlyUsageRecord()
        XCTAssertNil(usage.metrics["usage.event_detail.abandon"])
        XCTAssertEqual(n(usage, "usage.event_detail.use.delete"), 1)
        XCTAssertEqual(usage.metrics["usage.event_detail.dwell"], .string("1 0 0 0"))
    }

    /// The visit is open when the process goes to the background and dies
    /// there: its enter was flushed, its dwell and abandonment never are —
    /// not even by a write that happens while it sits in the background.
    /// Positive control: the same visit closed before backgrounding settles.
    func testAVisitKilledInTheBackgroundNeverSettles() throws {
        let clock = Box(morning)
        let media = Box(0.0)
        let doomed = makeCenter(clock: clock, media: media)
        UsageProbe.enter(.focusTap)
        media.value = 40
        post(UIApplication.willResignActiveNotification)
        post(UIApplication.didEnterBackgroundNotification)
        media.value = 900
        doomed.flushDaily()                     // any later write while backgrounded
        doomed.deactivate()                     // the process dies here

        clock.value = morning.addingTimeInterval(1800)
        let relaunched = makeCenter(clock: clock, media: Box(0), countsLaunchSession: true)
        XCTAssertFalse(relaunched.usage.isVisitOpen(.focus), "a visit never outlives its process")
        relaunched.flushDaily()
        let usage = try onlyUsageRecord()
        XCTAssertEqual(n(usage, "usage.focus.enter.tap"), 1, "the enter was on disk")
        XCTAssertNil(usage.metrics["usage.focus.abandon"], "never settled: no abandonment")
        XCTAssertNil(usage.metrics["usage.focus.dwell"], "never settled: no dwell")
        XCTAssertEqual(n(usage, "sessions"), 1, "the relaunch")

        UsageProbe.enter(.focusTap)
        UsageProbe.leave(.focus, via: .focusSwipe)
        relaunched.flushDaily()
        let control = try onlyUsageRecord()
        XCTAssertEqual(n(control, "usage.focus.abandon"), 1, "positive control: a closed visit settles")
        XCTAssertEqual(control.metrics["usage.focus.dwell"], .string("1 0 0 0"))
    }

    // MARK: Sessions

    func testControlCenterAndFaceIDAreNotSessions() throws {
        let center = makeCenter(clock: Box(morning), media: Box(0), countsLaunchSession: true)
        post(UIApplication.willResignActiveNotification)
        post(UIApplication.didBecomeActiveNotification)
        post(UIApplication.willResignActiveNotification)
        post(UIApplication.didBecomeActiveNotification)
        center.flushDaily()
        XCTAssertEqual(n(try onlyUsageRecord(), "sessions"), 1, "the launch only")

        post(UIApplication.didEnterBackgroundNotification)
        post(UIApplication.didBecomeActiveNotification)
        center.flushDaily()
        XCTAssertEqual(n(try onlyUsageRecord(), "sessions"), 2, "positive control: a real return counts")
    }

    // MARK: Availability (design §6.3: a switch-gated feature's denominator)

    /// Once per counted session, when the switch is on at the session's start
    /// or turned on during it — so `available` never exceeds `sessions`.
    func testAvailableIsCountedOncePerSessionWhileTheSwitchIsOnThroughTheLifecycle() throws {
        let gates = Box<Set<UsageGate>>([.focus])
        let center = makeCenter(clock: Box(morning), media: Box(0), countsLaunchSession: true, gates: gates)
        post(UIApplication.willResignActiveNotification)     // Control Center
        post(UIApplication.didBecomeActiveNotification)
        post(UIApplication.willResignActiveNotification)     // Face ID
        post(UIApplication.didBecomeActiveNotification)
        XCTAssertEqual(center.usage.counts.count("usage.focus.available"), 1, "the launch's session, once")

        post(UIApplication.didEnterBackgroundNotification)
        post(UIApplication.willEnterForegroundNotification)
        post(UIApplication.didBecomeActiveNotification)
        XCTAssertEqual(center.usage.counts.count("usage.focus.available"), 2, "a return is a new session")

        gates.value = []
        post(UIApplication.didEnterBackgroundNotification)
        post(UIApplication.willEnterForegroundNotification)
        XCTAssertEqual(center.usage.counts.count("usage.focus.available"), 2, "off at this session's start")
        XCTAssertEqual(center.usage.counts.count("usage.wanna.available"), 0)

        UsageProbe.switchToggled(.wanna, isOn: true)          // turned on mid-session
        UsageProbe.switchToggled(.wanna, isOn: false)
        UsageProbe.switchToggled(.wanna, isOn: true)
        center.flushDaily()
        let usage = try onlyUsageRecord()
        XCTAssertEqual(n(usage, "sessions"), 3)
        XCTAssertEqual(n(usage, "usage.focus.available"), 2)
        XCTAssertEqual(n(usage, "usage.wanna.available"), 1, "turned on during the session, counted once")
        XCTAssertEqual(n(usage, "usage.archived.use.wanna_on"), 2)
        XCTAssertEqual(n(usage, "usage.archived.use.wanna_off"), 1)
        for key in ["usage.focus.available", "usage.wanna.available", "usage.todo_stack.available", "usage.report.available"] {
            XCTAssertLessThanOrEqual(n(usage, key) ?? 0, n(usage, "sessions") ?? 0, "\(key) <= sessions")
        }
    }

    func testALaunchIntoTheBackgroundCountsItsSessionAtTheFirstForeground() throws {
        let foreground = Box(false)
        let start = morning
        let user = uid
        let center = ResidentObservationCenter(
            coordinator: coordinator, store: nil, location: location, calendar: la,
            now: { start }, mediaNow: { 0 }, ownerUID: { user }, stamp: { [unowned self] in self.stamp() },
            installsFollowerProbe: false, verifiesSeed: false, seedTrail: { _ in },
            countsLaunchSession: true, isAppForeground: { foreground.value }
        )
        centers.append(center)
        center.activate()
        XCTAssertEqual(center.usage.counts.count("sessions"), 0, "not in the foreground yet")
        foreground.value = true
        post(UIApplication.willEnterForegroundNotification)
        post(UIApplication.didBecomeActiveNotification)
        XCTAssertEqual(center.usage.counts.count("sessions"), 1)
    }

    // MARK: Re-mints

    func testRolloverClosesTheUsageLineAtTheDayEndAndTheNewDayStartsWithTheRunningSession() throws {
        let clock = Box(morning)
        let media = Box(0.0)
        let center = makeCenter(clock: clock, media: media, countsLaunchSession: true)
        UsageProbe.use(.allDayToggle)
        UsageProbe.enter(.focusAuto)
        center.flushDaily()
        let yesterday = try onlyUsageRecord()

        clock.value = la.date(byAdding: .day, value: 1, to: la.startOfDay(for: morning))!.addingTimeInterval(60)
        media.value = 30
        // After midnight, before the rollover hop has run: the visit ends and
        // a first signal of the new day arrives.
        UsageProbe.leave(.focus, via: .focusRotate)
        UsageProbe.use(.repeatForm)
        XCTAssertTrue(center.usage.isVisitOpen(.focus), "the leave waits for the hop")
        XCTAssertEqual(center.usage.counts.count("usage.focus.exit.rotate"), 0, "nothing went into yesterday's counts")
        center.performRolloverFlushIfDue()
        UsageProbe.use(.allDayToggle)
        center.flushDaily()

        let records = usageRecords().sorted { $0.startedAt < $1.startedAt }
        XCTAssertEqual(records.count, 2)
        let closed = try XCTUnwrap(records.first { $0.id == yesterday.id })
        XCTAssertEqual(closed.endedAt, la.date(byAdding: .day, value: 1, to: la.startOfDay(for: morning)), "closed at its day end")
        let today = try XCTUnwrap(records.first { $0.id != yesterday.id })
        XCTAssertNotEqual(today.dayKey, closed.dayKey)
        XCTAssertEqual(n(today, "sessions"), 1, "the session running across midnight is the new day's denominator")
        XCTAssertEqual(n(today, "usage.all_day.use"), 1)

        // A visit settles on the day it ends: entered on day N, its exit,
        // abandonment and dwell are day N+1's.
        XCTAssertEqual(n(closed, "usage.focus.enter.auto"), 1, "the enter stays on the day it entered")
        XCTAssertNil(closed.metrics["usage.focus.exit.rotate"], "not yesterday's: the visit ended after midnight")
        XCTAssertNil(closed.metrics["usage.focus.abandon"])
        XCTAssertNil(closed.metrics["usage.focus.dwell"])
        XCTAssertNil(closed.metrics["usage.repeat.use.form"], "the first signal after midnight is not yesterday's either")
        XCTAssertEqual(n(today, "usage.focus.exit.rotate"), 1)
        XCTAssertEqual(n(today, "usage.focus.abandon"), 1)
        XCTAssertEqual(today.metrics["usage.focus.dwell"], .string("0 0 1 0"), "30 s of foreground, timed at the signal")
        XCTAssertEqual(n(today, "usage.repeat.use.form"), 1)
        XCTAssertNil(today.metrics["usage.focus.enter.auto"], "and the new day has the exit without the enter")
    }

    // MARK: Disk paths kept off what the user is looking at

    private func usageLineCount() -> Int {
        let url = SpikeRunStore.fileURL(spikeID: UsageRecordIDs.spikeID, location: location)
        guard let data = try? Data(contentsOf: url) else { return 0 }
        return data.split(separator: 0x0A).count
    }

    private func usageFileBytes() -> Int {
        let url = SpikeRunStore.fileURL(spikeID: UsageRecordIDs.spikeID, location: location)
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// A return after midnight writes nothing inside the foreground
    /// notification: the session waits, parked, for the rollover hop, which
    /// then closes yesterday's line and counts the session on the new day.
    func testAReturnAfterMidnightWritesNothingInsideTheForegroundNotification() throws {
        let clock = Box(morning)
        let center = makeCenter(clock: clock, media: Box(0), countsLaunchSession: true)
        UsageProbe.use(.allDayToggle)
        post(UIApplication.willResignActiveNotification)
        post(UIApplication.didEnterBackgroundNotification)
        UsageProbe.use(.repeatForm)                                   // dirty again, unwritten
        let lines = usageLineCount()
        clock.value = la.date(byAdding: .day, value: 1, to: la.startOfDay(for: morning))!.addingTimeInterval(600)
        post(UIApplication.willEnterForegroundNotification)
        post(UIApplication.didBecomeActiveNotification)
        XCTAssertEqual(usageLineCount(), lines, "no rollover write inside the return to the foreground")

        center.performRolloverFlushIfDue()                            // the hop, a moment later
        center.flushDaily()
        let records = usageRecords().sorted { $0.startedAt < $1.startedAt }
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(n(records[0], "sessions"), 1, "yesterday: the launch")
        XCTAssertEqual(n(records[0], "usage.repeat.use.form"), 1, "yesterday's unwritten count went with yesterday's line")
        XCTAssertEqual(n(records[1], "sessions"), 1, "the return after midnight is the new day's session, once")
    }

    /// The usage file is rewritten (compacted) only at a lifecycle edge,
    /// never by a flush the user is looking at (deck open, rollover hop).
    func testTheUsageFileCompactsOnlyAtALifecycleEdge() throws {
        let clock = Box(morning)
        let center = makeCenter(clock: clock, media: Box(0))
        // Older lines up to just under the cap.
        let cap = SpikeRunStore.compactAtBytes
        var day = 1
        while usageFileBytes() < cap - 100 {
            let run = TelemetryFixtures.run(spikeID: UsageRecordIDs.spikeID, scenarioID: UsageRecordIDs.scenarioID,
                                            startedAt: morning.addingTimeInterval(Double(-day) * 86_400), appBuild: "31",
                                            metrics: ["sessions": .number(Double(day)), "usage.all_day.use": .number(1)])
            SpikeRunStore.finishRun(run, owner: .explicit(uid), location: location, compactsWhenFull: false)
            day += 1
        }
        XCTAssertLessThan(usageFileBytes(), cap + 1_024, "fixture: at the cap, not far past it")
        for gate in UsageGate.allCases { UsageProbe.switchToggled(gate, isOn: true); UsageProbe.switchToggled(gate, isOn: false) }
        center.flushDaily()                                           // the deck's flush
        XCTAssertGreaterThan(usageFileBytes(), cap, "past the cap and not rewritten in the foreground")

        UsageProbe.use(.allDayToggle)
        post(UIApplication.willResignActiveNotification)              // the app leaving
        XCTAssertLessThan(usageFileBytes(), cap, "positive control: the lifecycle edge's write compacts")
    }

    /// The upload batch reads the record files off the main actor: it never
    /// runs the main-actor whole-file read (`SpikeRunStore.loadRuns`).
    func testTheUploadBatchDoesNotRunTheMainActorWholeFileRead() async throws {
        let center = makeCenter(clock: Box(morning), media: Box(0), countsLaunchSession: true)
        UsageProbe.use(.allDayToggle)
        center.flushDaily()
        let suite = "UsageUploadReadTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = SyncFakeServer(userId: uid)
        let uploader = makeUploader(server: server, defaults: defaults)
        let reads = SpikeRunStore.wholeFileReads
        let outcome = await uploader.uploadNow(trigger: .deckOpen)
        XCTAssertEqual(outcome, .uploaded(rows: 2), "positive control: the day's two lines were read and sent")
        XCTAssertEqual(SpikeRunStore.wholeFileReads, reads, "no main-actor whole-file read in the batch")
    }

    /// The hop is what moves a parked signal into the new day; if the clock
    /// went back before it ran, the parked signal lands in the current day.
    func testAParkedSignalIsNeverLost() throws {
        let clock = Box(morning)
        let center = makeCenter(clock: clock, media: Box(0))
        let dayEnd = la.date(byAdding: .day, value: 1, to: la.startOfDay(for: morning))!
        clock.value = dayEnd.addingTimeInterval(5)
        UsageProbe.use(.allDayToggle)
        clock.value = dayEnd.addingTimeInterval(-5)
        center.performRolloverFlushIfDue()
        XCTAssertEqual(center.usage.counts.count("usage.all_day.use"), 1)
    }

    /// A sign-out or account switch is noticed at the next flush. The open
    /// visit is the previous account's: it must not settle into the next
    /// account's row, and a late write for it is stray. Positive control: a
    /// visit opened after the switch settles normally.
    func testAnOwnerChangeDropsTheOpenVisitsSoTheyNeverSettleIntoTheNextAccount() throws {
        let owner = Box<String?>(uid)
        let center = makeCenter(clock: Box(morning), media: Box(0), owner: owner)
        UsageProbe.enter(.eventDetailCanvas)
        owner.value = TelemetryFixtures.otherUID
        center.flushDaily()
        UsageProbe.use(.eventDetailPlan)
        UsageProbe.leave(.eventDetail)
        center.flushDaily()
        let byOwner = Dictionary(grouping: usageRecords(), by: { $0.ownerUID ?? "nil" })
        let a = try XCTUnwrap(byOwner[uid]?.first)
        let b = byOwner[TelemetryFixtures.otherUID]?.first
        XCTAssertEqual(n(a, "usage.event_detail.enter.canvas"), 1)
        XCTAssertNil(a.metrics["usage.event_detail.abandon"], "never settled")
        XCTAssertNil(b?.metrics["usage.event_detail.abandon"], "A's visit did not settle into B's row")
        XCTAssertNil(b?.metrics["usage.event_detail.dwell"])
        XCTAssertNil(b?.metrics["usage.event_detail.use.plan"], "nor did its late write")

        UsageProbe.enter(.eventDetailList)
        UsageProbe.leave(.eventDetail)
        center.flushDaily()
        let b2 = try XCTUnwrap(usageRecords().first { $0.ownerUID == TelemetryFixtures.otherUID })
        XCTAssertEqual(n(b2, "usage.event_detail.abandon"), 1, "B's own visit settles")
    }

    func testAnAccountSwitchClosesTheUsageLineUnderTheOldOwner() throws {
        let owner = Box<String?>(uid)
        let center = makeCenter(clock: Box(morning), media: Box(0), owner: owner)
        UsageProbe.use(.allDayToggle)
        owner.value = TelemetryFixtures.otherUID
        center.flushDaily()                       // notices the switch, closes the old id
        UsageProbe.use(.repeatForm)
        center.flushDaily()
        let byOwner = Dictionary(grouping: usageRecords(), by: { $0.ownerUID ?? "nil" })
        XCTAssertEqual(byOwner[uid]?.first.flatMap { n($0, "usage.all_day.use") }, 1)
        XCTAssertNil(byOwner[uid]?.first?.metrics["usage.repeat.use.form"])
        XCTAssertEqual(byOwner[TelemetryFixtures.otherUID]?.first.flatMap { n($0, "usage.repeat.use.form") }, 1)
    }

    /// The eraser's two calls for this, in its order (see `ResidentEraseTests`).
    func testTheEraseForgetsTheCountsAndTheOpenVisits() throws {
        let center = makeCenter(clock: Box(morning), media: Box(0), countsLaunchSession: true)
        UsageProbe.enter(.createDrag)
        UsageProbe.use(.repeatForm)
        center.flushDaily()
        XCTAssertEqual(usageRecords().count, 1, "fixture: the pre-erase day is on disk")

        SpikeRunStore.wipe(location: location)
        center.forgetAfterErase()
        UsageProbe.leave(.create, via: .createCancel)
        center.flushDaily()
        let after = try onlyUsageRecord()
        XCTAssertEqual(after.metrics, ["sessions": .number(1)],
                       "nothing from before the erase, and the open visit settled nothing; the session the erase ran in is the new record's denominator")
        XCTAssertFalse(center.usage.isVisitOpen(.create))
    }

    // MARK: The upload body

    private func makeUploader(server: SyncFakeServer, defaults: UserDefaults) -> TelemetryUploader {
        var deps = TelemetryUploader.Dependencies()
        deps.defaults = defaults
        deps.location = location
        let now = morning.addingTimeInterval(3600)
        deps.now = { now }
        deps.launchDelay = 0
        deps.makeKeepAlive = { nil }
        deps.bootstrapOwner = { nil }
        let uploader = TelemetryUploader(dependencies: deps)
        let user = uid
        uploader.attach(TelemetryUploader.Attachment(gateway: server, isBlockedByBuild: { false },
                                                     currentUserID: { user }, isSignedIn: { true }))
        defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        TelemetryConsentStore.recordGrant(defaults, at: morning.addingTimeInterval(-3600))
        return uploader
    }

    private func registryUsageKeys() throws -> [String: String] {
        struct Entry: Decodable { let key: String; let value_schema: String; let spike_id: String }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("done-mcp/supabase/telemetry/key_registry.json")
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
        return Dictionary(uniqueKeysWithValues: entries.filter { $0.spike_id == UsageRecordIDs.spikeID }.map { ($0.key, $0.value_schema) })
    }

    func testTheUploadedUsageRowCarriesOnlyRegistryKeysWithWholeNumbersOrFixedBuckets() async throws {
        let center = makeCenter(clock: Box(morning), media: Box(0), countsLaunchSession: true)
        UsageProbe.enter(.focusTap)
        UsageProbe.use(.focusNote)
        UsageProbe.leave(.focus, via: .focusSwipe)
        UsageProbe.enter(.createReminderAI)
        UsageProbe.count(.createAIFallback)
        UsageProbe.leave(.create, via: .createDismiss)
        center.flushDaily()
        let real = try onlyUsageRecord()

        // A line the client did not write the way it should: keys the
        // registry does not have, prose, a fraction, a malformed histogram.
        var forged = TelemetryFixtures.run(spikeID: UsageRecordIDs.spikeID, scenarioID: UsageRecordIDs.scenarioID,
                                           startedAt: morning, endedAt: morning.addingTimeInterval(60), appBuild: "29", metrics: [
            "sessions": .number(2),
            "usage.focus.enter.bogus": .number(3),
            "title": .string("dinner with Sam"),
            "usage.create.done": .number(1.5),
            "usage.focus.dwell": .string("1 2 3"),
            "usage.event_detail.dwell": .string("1 x 0 0"),
            "usage.create.dwell": .string("0 0 1 0"),
        ])
        forged.dayKey = "2026-09-21"
        XCTAssertTrue(SpikeRunStore.finishRun(forged, owner: .explicit(uid), location: location))

        let suite = "UsageUploadTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = SyncFakeServer(userId: uid)
        let uploader = makeUploader(server: server, defaults: defaults)
        _ = await uploader.uploadNow(trigger: .deckOpen)

        let registry = try registryUsageKeys()
        XCTAssertGreaterThan(registry.count, 40, "liveness: the registry holds the usage keys")
        var violations: [String] = []
        var sentMetrics: [[String: Any]] = []
        for record in [real, forged] {
            let row = try XCTUnwrap(server.telemetryRow(runID: record.id), "\(record.id) landed")
            let metrics = try XCTUnwrap(row.data["metrics"] as? [String: Any])
            sentMetrics.append(metrics)
            for (key, value) in metrics {
                switch registry[key] {
                case "number":
                    let number = value as? NSNumber
                    if number == nil || CFGetTypeID(number!) == CFBooleanGetTypeID() || number!.doubleValue.rounded() != number!.doubleValue {
                        violations.append("\(key) = \(value): not a whole number")
                    }
                case "fixed_string":
                    let text = value as? String ?? ""
                    let parts = text.split(separator: " ", omittingEmptySubsequences: false)
                    if parts.count != 4 || !parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
                        violations.append("\(key) = \(value): not four buckets")
                    }
                default:
                    violations.append("\(key): not a registered usage key")
                }
            }
            if record.id == real.id {
                XCTAssertEqual(Set(metrics.keys), Set(real.metrics.keys), "the client's own line goes up whole")
            } else {
                XCTAssertEqual(Set(metrics.keys), ["sessions", "usage.create.dwell"],
                               "only the registered, well-formed keys of the forged line")
            }
        }
        XCTAssertEqual(violations, [])
        let body = String(decoding: try JSONSerialization.data(withJSONObject: sentMetrics, options: []), as: UTF8.self)
        XCTAssertFalse(body.contains("dinner"), "no prose on the wire")
    }
}

// MARK: - Design §11 item 13, with the real detail view on screen

/// The detail is pushed the way every presenter pushes it (enter at the
/// push, leave when the route goes away), then a page is pushed on top of
/// it and popped — the chat's path. SwiftUI re-runs the detail's
/// `onAppear` on that pop and runs its `onDisappear` on the push; neither
/// may count an enter or settle the visit.
@MainActor
final class UsageDetailNavigationTests: XCTestCase {
    final class Nav: ObservableObject {
        @Published var path: [Dest] = []
        var detailAppearances = 0
    }

    enum Dest: Hashable {
        case detail(CalendarEventDetailRoute)
        case cover
    }

    struct Host: View {
        @ObservedObject var nav: Nav
        let store: EventStore

        var body: some View {
            NavigationStack(path: $nav.path) {
                Color.clear
                    .navigationDestination(for: Dest.self) { dest in
                        switch dest {
                        case .detail(let route):
                            CalendarEventDetailView(route: route)
                                .environmentObject(store)
                                .onAppear { nav.detailAppearances += 1 }
                        case .cover:
                            Text("cover")
                        }
                    }
            }
            // The presenters' leave: the route going away.
            .onChange(of: nav.path.first) { old, new in
                if old != nil, new == nil { UsageProbe.leave(.eventDetail) }
            }
        }
    }

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var storage: EventStorageLocation!
    private var location: SpikeRunStorageLocation!
    private var center: ResidentObservationCenter?
    private var displacedSink: UsageSink?
    private let day = Date(timeIntervalSince1970: 1_770_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "UsageDetailNavigationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        storage = TestStorage.reset(suiteName)
        location = .ephemeral(id: UUID())
        displacedSink = UsageProbe.sink
    }

    override func tearDown() {
        center?.deactivate()
        center = nil
        UsageProbe.sink = displacedSink
        try? FileManager.default.removeItem(at: location.directory)
        TestStorage.tearDown(suiteName)
        super.tearDown()
    }

    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
    }

    private func count(_ name: String) -> Int {
        center?.usage.counts.count(name) ?? -1
    }

    func testAPopBackToTheDetailDoesNotCountASecondEnterOrSettleTheVisit() throws {
        let made = ResidentObservationCenter(
            coordinator: SpikeSessionCoordinator(), store: nil, location: location,
            installsFollowerProbe: false, verifiesSeed: false, seedTrail: { _ in },
            countsLaunchSession: false, isAppForeground: { true }
        )
        made.activate()
        center = made

        let store = EventStore(defaults: defaults, storage: storage, seedsSampleDataIfEmpty: false)
        let event = Event(title: "a", timeRanges: [.init(start: day, end: day.addingTimeInterval(3600))], type: "Study")
        store.rawCalendarEvents = [event]
        let route = CalendarEventDetailRoute(
            occurrence: CalendarEventOccurrenceContext(eventID: event.id, occurrenceDate: day, occurrenceID: nil,
                                                       isAllDay: false, source: .timelineTap),
            initialJumpTarget: .meta
        )

        let nav = Nav()
        let controller = UIHostingController(rootView: Host(nav: nav, store: store))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let displaced = scene?.windows.first(where: \.isKeyWindow)
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            displaced?.makeKeyAndVisible()
        }
        settle()

        // Open: the push site's enter, then the push.
        UsageProbe.enter(.eventDetailCanvas)
        nav.path = [.detail(route)]
        settle()
        XCTAssertEqual(nav.detailAppearances, 1, "the detail is on screen")

        // The chat's path: a page over the detail, then back.
        nav.path.append(.cover)
        settle()
        nav.path.removeLast()
        settle()
        XCTAssertEqual(nav.detailAppearances, 2, "positive control for the rig: the pop re-ran the detail's onAppear")
        XCTAssertEqual(count("usage.event_detail.enter.canvas"), 1, "the pop back is not an enter")
        XCTAssertTrue(made.usage.isVisitOpen(.eventDetail), "pushing a page over the detail is not leaving it")
        XCTAssertEqual(count("usage.event_detail.abandon"), 0)

        // Back to the calendar: now the visit settles.
        nav.path = []
        settle()
        XCTAssertFalse(made.usage.isVisitOpen(.eventDetail))
        XCTAssertEqual(count("usage.event_detail.abandon"), 1)
        XCTAssertEqual(made.usage.counts.dwellBuckets(.eventDetail)?.reduce(0, +), 1, "one visit, one dwell")

        // Positive control: a second real open counts.
        UsageProbe.enter(.eventDetailCanvas)
        nav.path = [.detail(route)]
        settle()
        XCTAssertEqual(count("usage.event_detail.enter.canvas"), 2)
        nav.path = []
        settle()
    }
}
