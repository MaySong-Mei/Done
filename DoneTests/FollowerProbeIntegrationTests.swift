//
//  FollowerProbeIntegrationTests.swift
//  DoneTests
//
//  perf batch 2a — the follower probe wired in: the resident center's window
//  and daily records, the instrumented followers themselves (sync flush,
//  occurrence cache, backup snapshot, colorDepth mirror, widget), and the
//  upload of the new keys against a server whose key registry lacks them.
//
//  The recorder is process-wide and the host app's own followers share the
//  main thread, so the assertions name the followers each test drives and
//  never "everything else is zero" across a test that yields.
//

import QuartzCore
import SwiftUI
import UIKit
import XCTest
@testable import Done

// MARK: - Resident center: window span, daily rollup, gating, trail

@MainActor
final class FollowerProbeCenterTests: XCTestCase {
    private final class ClockBox {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private var location: SpikeRunStorageLocation!
    private var coordinator: SpikeSessionCoordinator!
    private var centers: [ResidentObservationCenter] = []
    private var followerClock: FollowerManualClock!
    private var displaced: FollowerTimingRecorder?
    /// Every frame probe a window attached, so a test can tick it by hand.
    private var probes: [SpikeFrameProbe] = []

    override func setUp() {
        super.setUp()
        probes = []
        location = .ephemeral(id: UUID())
        coordinator = SpikeSessionCoordinator()
        followerClock = FollowerManualClock()
        displaced = FollowerTiming.recorder
        FollowerTiming.recorder = nil
    }

    override func tearDown() {
        for center in centers { center.deactivate() }
        centers = []
        FollowerTiming.recorder = displaced
        SpikeProbe.onSignal = nil
        try? FileManager.default.removeItem(at: location.directory)
        coordinator = nil
        location = nil
        super.tearDown()
    }

    private func makeCenter(clock: ClockBox, installs: Bool = true, media: Double = 500) -> ResidentObservationCenter {
        let followerClock = followerClock!
        let made = ResidentObservationCenter(
            coordinator: coordinator, store: nil, location: location, calendar: .current,
            now: { clock.now }, mediaNow: { media },
            makeFrameProbe: { [unowned self] in
                let probe = SpikeFrameProbe()
                self.probes.append(probe)
                return probe
            },
            followerClock: { followerClock.ns },
            installsFollowerProbe: installs,
            isAppActive: { true }
        )
        centers.append(made)
        return made
    }

    private func emitTap() {
        SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .changed, eventTime: nil, locationX: 100))
        SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .ended, eventTime: nil, locationX: 100))
        SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .commitStart, eventTime: nil, locationX: 0))
        SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .commitEnd, eventTime: nil, locationX: 0))
    }

    private func run(_ id: FollowerID, ms: Double) {
        FollowerTiming.measure(id) { followerClock.advance(ms: ms) }
    }

    private func dailies() -> [SpikeRun] {
        SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.residentDailySpikeID, location: location)
    }

    private func windows() -> [SpikeRun] {
        SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.effortPathFixID, location: location)
    }

    // MARK: Gating

    func testTheProbeIsInstalledOnlyWhileActiveAndOnlyWhenAsked() {
        let clock = ClockBox(Date())
        let off = makeCenter(clock: clock, installs: false)
        off.activate()
        XCTAssertNil(FollowerTiming.recorder, "not asked: the probe stays off")
        off.deactivate()

        let on = makeCenter(clock: clock)
        on.activate()
        XCTAssertTrue(FollowerTiming.recorder === on.followers, "asked: installed on activate")
        on.deactivate()
        XCTAssertNil(FollowerTiming.recorder, "and removed on deactivate")

        let someoneElses = FollowerTimingRecorder()
        let again = makeCenter(clock: clock)
        again.activate()
        FollowerTiming.recorder = someoneElses
        again.deactivate()
        XCTAssertTrue(FollowerTiming.recorder === someoneElses, "deactivate removes only its own recorder")
        FollowerTiming.recorder = nil
    }

    /// Probe off: the day's line still carries every follower key (the
    /// registry contract), all zero, and a window claims no follower probe.
    func testAnUninstalledProbeWritesZeroDayKeysAndNoWindowKeys() throws {
        let clock = ClockBox(Date())
        let center = makeCenter(clock: clock, installs: false)
        center.activate()
        emitTap()
        run(.imageScan, ms: 5)
        center.closeWindow()
        center.flushDaily()

        let day = try XCTUnwrap(dailies().first)
        for key in FollowerStatTable.dailyKeys {
            XCTAssertEqual(day.metrics[key], .number(0), key)
        }
        let window = try XCTUnwrap(windows().first)
        XCTAssertTrue(window.metrics.keys.filter { $0.hasPrefix("wfl.") }.isEmpty, "\(window.metrics.keys.sorted())")
        XCTAssertNotNil(window.metrics["wTaps"], "the window record itself was written")
    }

    // MARK: Window attribution

    /// A window collects the runs between its opening (the tap's commit) and
    /// its close — extension included — and nothing before or after.
    func testAWindowCollectsExactlyTheRunsInsideItsSpan() throws {
        let clock = ClockBox(Date())
        let center = makeCenter(clock: clock)
        center.activate()

        run(.imageScan, ms: 5)                  // before: day only
        emitTap()                               // opens
        XCTAssertNotNil(center.window)
        run(.occurrenceSync, ms: 7)
        emitTap()                               // extends, same window
        XCTAssertEqual(center.window?.extensions, 1)
        run(.syncCalendarHash, ms: 3)
        center.closeWindow()
        run(.imageScan, ms: 11)                 // after: day only

        let records = windows()
        XCTAssertEqual(records.count, 1)
        let window = try XCTUnwrap(records.first)
        XCTAssertEqual(window.metrics["wfl.runs"], .number(2))
        XCTAssertEqual(window.metrics["wfl.occ.sync.n"], .number(1))
        XCTAssertEqual(window.metrics["wfl.occ.sync.ms"], .number(7))
        XCTAssertEqual(window.metrics["wfl.syncCal.hash.ms"], .number(3))
        XCTAssertNil(window.metrics["wfl.imgScan.n"], "the runs before the open and after the close are not the window's")

        center.flushDaily()
        let day = try XCTUnwrap(dailies().first)
        XCTAssertEqual(day.metrics["fl.imgScan.n"], .number(2), "the day saw them")
        XCTAssertEqual(day.metrics["fl.imgScan.ms"], .number(16))
        XCTAssertEqual(day.metrics["fl.imgScan.maxMs"], .number(11))
        XCTAssertEqual(day.metrics["fl.occ.sync.n"], .number(1))
    }

    /// The window probe's own metrics are the same with the follower probe
    /// on and off — the follower keys sit beside them and change none.
    func testTheWindowProbesOwnMetricsDoNotChangeWithTheFollowerProbe() throws {
        func scripted(installs: Bool) throws -> [String: SpikeMetricValue] {
            let clock = ClockBox(Date(timeIntervalSince1970: 1_790_000_000))
            let center = makeCenter(clock: clock, installs: installs)
            center.activate()
            emitTap()
            run(.occurrenceSync, ms: 7)
            emitTap()
            center.closeWindow()
            center.deactivate()
            let record = try XCTUnwrap(windows().last)
            try FileManager.default.removeItem(at: location.directory)
            return record.metrics
        }
        let off = try scripted(installs: false)
        let on = try scripted(installs: true)
        XCTAssertEqual(on.filter { !$0.key.hasPrefix("wfl.") }, off)
        XCTAssertFalse(on.keys.filter { $0.hasPrefix("wfl.") }.isEmpty, "positive control: the on run did add follower keys")
    }

    /// A resign closes the window with what it saw; until the app is active
    /// again a run is background work and not the day's.
    func testAResignClosesTheWindowAndBackgroundRunsAreNotTheDays() throws {
        let clock = ClockBox(Date())
        let center = makeCenter(clock: clock)
        center.activate()
        emitTap()
        run(.occurrenceBatch, ms: 4)
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertNil(center.window, "the resign closed the window")
        run(.occurrenceBatch, ms: 50)           // background
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        run(.occurrenceBatch, ms: 6)            // foreground again
        center.flushDaily()

        let window = try XCTUnwrap(windows().first)
        XCTAssertEqual(window.metrics["wClosedByResign"], .bool(true))
        XCTAssertEqual(window.metrics["wfl.occ.batch.ms"], .number(4))
        let day = try XCTUnwrap(dailies().max { ($0.revision ?? 0) < ($1.revision ?? 0) })
        XCTAssertEqual(day.metrics["fl.occ.batch.n"], .number(2), "the background run is left out")
        XCTAssertEqual(day.metrics["fl.occ.batch.ms"], .number(10))
        XCTAssertEqual(day.metrics["fl.occ.batch.maxMs"], .number(6))
    }

    /// The window's frame ticks are the followers' frame boundaries: a run
    /// inside the largest frame is charged to it on the record.
    func testTheProbesTicksAttributeRunsToTheWindowsLargestFrame() throws {
        let clock = ClockBox(Date())
        let center = makeCenter(clock: clock)
        center.activate()
        emitTap()
        // The frame probe the window attached, ticked by hand through its
        // own callback, in media seconds — the clock the spans run on.
        let probe = try XCTUnwrap(probes.last, "fixture: the window attached a probe")
        let tick = try XCTUnwrap(probe.onTick, "fixture: the center listens to the probe")
        followerClock.set(ms: 1_000)
        tick(1.000)
        run(.syncCalendarHash, ms: 120)          // 1000…1120
        tick(1.132)
        tick(1.140)
        center.closeWindow()

        let window = try XCTUnwrap(windows().first)
        XCTAssertEqual(window.metrics["wfl.maxFrameMs"], .number(132))
        XCTAssertEqual(window.metrics["wfl.inMaxFrameMs"], .number(120))
        XCTAssertEqual(window.metrics["wfl.syncCal.hash.inMaxFrameMs"], .number(120))
    }

    /// The window outlives the debounced sync flush the tap causes: the
    /// effort commit re-arms the 2 s debounce, the colorDepth mirror 250 ms
    /// later re-arms it again, and the flush's main-thread spans start
    /// there. The window stays open long past that, so no extension of the
    /// attribution span is needed. (The 5 s settings follow-on and the 30 s
    /// snapshot land outside it; the daily rollup is where those show.)
    func testTheWindowOutlivesTheDebouncedSyncFlushItAttributes() {
        let mirror = EventStore.colorDepthMirrorCoalesceWindow
        let mirrorSeconds = Double(mirror.components.seconds) + Double(mirror.components.attoseconds) / 1e18
        let flushStarts = mirrorSeconds + SupabaseSyncConfig.debounceSeconds
        let roomForTheFlush = 3.0
        XCTAssertGreaterThanOrEqual(ResidentWindowModel.durationSeconds, flushStarts + roomForTheFlush,
                                    "the flush starts at \(flushStarts)s after the commit")
        XCTAssertLessThan(ResidentWindowModel.durationSeconds, SupabaseSyncConfig.settingsDebounceSeconds + flushStarts,
                          "context: the settings follow-on is outside the window, so it is the day's to show")
    }

    // MARK: Trail

    func testEachWindowCloseWritesOneFollowersLineNamingItsRecord() throws {
        let clock = ClockBox(Date())
        let center = makeCenter(clock: clock)
        center.activate()
        emitTap()
        run(.colorDepthMirror, ms: 2)
        center.closeWindow()
        let window = try XCTUnwrap(windows().first)
        let tag = "followers: window=\(window.id.uuidString.prefix(8).lowercased())"
        let lines = DiagnosticTrail.combinedText().split(separator: "\n").filter { $0.contains(tag) }
        XCTAssertEqual(lines.count, 1, "one line for the one window")
        XCTAssertTrue(lines.first?.contains("mirror=2.00ms/1") == true, String(lines.first ?? ""))

        // Probe off: a window closes with no line.
        let quiet = makeCenter(clock: clock, installs: false)
        center.deactivate()
        quiet.activate()
        emitTap()
        quiet.closeWindow()
        let second = try XCTUnwrap(windows().first { $0.id != window.id })
        XCTAssertFalse(DiagnosticTrail.combinedText().contains("window=\(second.id.uuidString.prefix(8).lowercased())"))
    }

    // MARK: Daily rollup

    /// The relaunch seed carries the followers like the counters: the
    /// evening's flush re-appends the morning's id with the merged totals.
    func testTheDaysFollowersSurviveARelaunch() throws {
        let clock = ClockBox(Date())
        let morning = makeCenter(clock: clock)
        morning.activate()
        run(.imageScan, ms: 5)
        run(.imageScan, ms: 2)
        morning.flushDaily()
        morning.deactivate()

        let evening = makeCenter(clock: clock)
        evening.activate()
        run(.imageScan, ms: 3)
        evening.flushDaily()

        let records = dailies()
        XCTAssertEqual(records.count, 1, "same day, same id")
        let day = try XCTUnwrap(records.first)
        XCTAssertEqual(day.metrics["fl.imgScan.n"], .number(3))
        XCTAssertEqual(day.metrics["fl.imgScan.ms"], .number(10))
        XCTAssertEqual(day.metrics["fl.imgScan.maxMs"], .number(5))
    }

    /// Midnight closes yesterday's followers on yesterday's line and starts
    /// today's from zero.
    func testMidnightClosesYesterdaysFollowersAndTodayStartsFromZero() throws {
        let calendar = Calendar.current
        let elevenPM = try XCTUnwrap(calendar.date(bySettingHour: 23, minute: 0, second: 0, of: Date()))
        let clock = ClockBox(elevenPM)
        let center = makeCenter(clock: clock)
        center.activate()
        run(.syncLogsHash, ms: 5)
        center.flushDaily()

        clock.now = elevenPM.addingTimeInterval(2 * 3600)
        center.performRolloverFlushIfDue()
        run(.syncLogsHash, ms: 7)
        center.flushDaily()

        let records = dailies().sorted { $0.startedAt < $1.startedAt }
        guard records.count == 2 else { return XCTFail("two days, two records; got \(records.count)") }
        XCTAssertEqual(records[0].metrics["fl.syncLog.hash.n"], .number(1))
        XCTAssertEqual(records[0].metrics["fl.syncLog.hash.ms"], .number(5))
        XCTAssertEqual(records[0].endedAt, calendar.startOfDay(for: clock.now), "yesterday's line closes at its day end")
        XCTAssertEqual(records[1].metrics["fl.syncLog.hash.n"], .number(1), "today starts from zero")
        XCTAssertEqual(records[1].metrics["fl.syncLog.hash.ms"], .number(7))
        XCTAssertEqual(records[1].metrics["fl.syncLog.hash.maxMs"], .number(7))
    }

    /// A day whose record from another day exists is not adopted: the seed
    /// reads today's record only.
    func testARelaunchOnTheNextDayDoesNotAdoptYesterdaysFollowers() throws {
        let calendar = Calendar.current
        let noon = try XCTUnwrap(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date()))
        let clock = ClockBox(noon)
        let yesterday = makeCenter(clock: clock)
        yesterday.activate()
        run(.widgetSnapshot, ms: 9)
        yesterday.flushDaily()
        yesterday.deactivate()

        clock.now = noon.addingTimeInterval(24 * 3600)
        let today = makeCenter(clock: clock)
        today.activate()
        run(.widgetSnapshot, ms: 1)
        today.flushDaily()

        let records = dailies().sorted { $0.startedAt < $1.startedAt }
        guard records.count == 2 else { return XCTFail("got \(records.count)") }
        XCTAssertEqual(records[1].metrics["fl.widget.n"], .number(1))
        XCTAssertEqual(records[1].metrics["fl.widget.ms"], .number(1))
    }

    /// The dirty check covers the followers: a flush with no new run writes
    /// nothing, a new run makes the next flush write.
    func testAFlushWritesOnlyWhenTheFollowersMoved() throws {
        let clock = ClockBox(Date())
        let center = makeCenter(clock: clock)
        center.activate()
        run(.snapshotDigest, ms: 1)
        center.flushDaily()
        let first = try XCTUnwrap(dailies().first?.revision)
        center.flushDaily()
        XCTAssertEqual(dailies().first?.revision, first, "nothing moved: no line")
        run(.snapshotDigest, ms: 1)
        center.flushDaily()
        XCTAssertEqual(dailies().first?.revision, first + 1, "a follower run alone makes the day dirty")
        XCTAssertEqual(dailies().first?.metrics["fl.snap.digest.n"], .number(2))
    }

    /// Re-minting the day (consent) starts the followers over with the
    /// counters; the old id keeps what it had.
    func testTheConsentRemintStartsTheFollowersOver() throws {
        let clock = ClockBox(Date())
        let center = makeCenter(clock: clock)
        center.activate()
        run(.wristSnapshot, ms: 2)
        center.remintDailyForConsent()
        let records = dailies()
        guard records.count == 2 else { return XCTFail("got \(records.count)") }
        let withRun = records.filter { $0.metrics["fl.wrist.n"] == .number(1) }
        let fresh = records.filter { $0.metrics["fl.wrist.n"] == .number(0) }
        XCTAssertEqual(withRun.count, 1, "the closed id keeps the run")
        XCTAssertEqual(fresh.count, 1, "the new id starts from zero")
    }
}

// MARK: - 观察站 readout over this device's records

@MainActor
final class FollowerObservatoryReadTests: XCTestCase {
    private func run(kind: TelemetryRecordKind, dayKey: String, endedAt: Date, metrics: [String: SpikeMetricValue]) -> SpikeRun {
        if kind == .window {
            return TelemetryFixtures.run(spikeID: FixObservationRegistry.effortPathFixID,
                                         scenarioID: FixObservationRegistry.windowScenarioID,
                                         endedAt: endedAt, metrics: metrics, kind: .window, dayKey: dayKey)
        }
        return TelemetryFixtures.run(endedAt: endedAt, metrics: metrics, kind: .dailyRollup, dayKey: dayKey)
    }

    /// The card reads windows inside the deck's window and TODAY's latest
    /// daily line — not yesterday's, not an older one of today's.
    func testTheCardReadsRecentWindowsAndTodaysLatestDailyLine() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 12)))
        func key(_ daysAgo: Int) -> String {
            TelemetryClaimKey.dayKey(forDayStart: calendar.startOfDay(for: now.addingTimeInterval(-Double(daysAgo) * 86_400)),
                                     calendar: calendar).dayKey
        }
        let recent = run(kind: .window, dayKey: key(3), endedAt: now, metrics: [
            "wfl.runs": .number(1), "wfl.mirror.n": .number(1), "wfl.mirror.ms": .number(4), "wfl.mirror.maxMs": .number(4)])
        let tooOld = run(kind: .window, dayKey: key(FixWatchAttention.observatoryWindowDays + 5), endedAt: now, metrics: [
            "wfl.runs": .number(1), "wfl.mirror.n": .number(1), "wfl.mirror.ms": .number(400), "wfl.mirror.maxMs": .number(400)])
        let yesterday = run(kind: .dailyRollup, dayKey: key(1), endedAt: now.addingTimeInterval(-86_400), metrics: [
            "fl.widget.n": .number(9), "fl.widget.ms": .number(9), "fl.widget.maxMs": .number(1)])
        let todayEarly = run(kind: .dailyRollup, dayKey: key(0), endedAt: now.addingTimeInterval(-3600), metrics: [
            "fl.widget.n": .number(1), "fl.widget.ms": .number(1), "fl.widget.maxMs": .number(1)])
        let todayLate = run(kind: .dailyRollup, dayKey: key(0), endedAt: now, metrics: [
            "fl.widget.n": .number(2), "fl.widget.ms": .number(3), "fl.widget.maxMs": .number(2)])

        let summary = FixWatchAttention.followerSummary(
            local: (dailies: [yesterday, todayLate, todayEarly], windows: [recent, tooOld]), now: now, calendar: calendar)
        XCTAssertEqual(summary.windowCount, 1, "the window older than the deck's reach is left out")
        XCTAssertEqual(summary.windowRows.map(\.totalMs), [4])
        XCTAssertEqual(summary.todayRows, [FollowerReport.Row(id: "widget", runs: 2, totalMs: 3, maxMs: 2, inMaxFrameMs: nil)])

        // Before today's first flush only yesterday's line exists: the card
        // shows nothing for today rather than yesterday's numbers.
        let morning = FixWatchAttention.followerSummary(local: (dailies: [yesterday], windows: []), now: now, calendar: calendar)
        XCTAssertEqual(morning.todayRows, [], "yesterday's line is not today's")
    }
}

// MARK: - (a) The sync flush: per table, network awaits excluded

@MainActor
final class FollowerSyncFlushTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var server: SyncFakeServer!
    private var service: SupabaseSyncService!
    private var recorder: FollowerTimingRecorder!
    private var displaced: FollowerTimingRecorder?
    private let uid = "44444444-4444-4444-8444-444444444444"

    override func setUp() {
        super.setUp()
        suiteName = "FollowerSyncFlushTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        server = SyncFakeServer(userId: uid)
        service = SupabaseSyncService(gateway: server, userId: uid, defaults: defaults)
        recorder = FollowerTimingRecorder(isForeground: true)
        displaced = FollowerTiming.recorder
        FollowerTiming.recorder = recorder
    }

    override func tearDown() {
        FollowerTiming.recorder = displaced
        server.releaseAll()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func events(_ count: Int) -> [Event] {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        return (0..<count).map {
            Event(title: "e\($0)", timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))])
        }
    }

    /// The flush's three spans each run once (the baseline span twice: before
    /// and after the sends), and none of them contains the network: the
    /// insert is held on the far side for a real interval, and the spans
    /// together stay a small fraction of it.
    func testTheCalendarFlushTimesItsMainThreadSpansAndNotTheNetwork() async throws {
        let batch = events(12)
        server.holdWhen = { verb, _ in verb == .insert }
        let started = FollowerClock.now()
        let flush = Task { await service.syncEvents(batch, kind: "calendar") }
        while server.heldCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let held = Duration.milliseconds(400)
        try await Task.sleep(for: held)
        server.releaseAll()
        await flush.value
        let wallMs = Double(FollowerClock.now() - started) / 1e6

        let day = recorder.dailySnapshot()
        XCTAssertEqual(day[.syncCalendarBuild].count, 1)
        XCTAssertEqual(day[.syncCalendarHash].count, 1)
        XCTAssertEqual(day[.syncCalendarBaseline].count, 2, "before the sends and after them")
        let spansMs = Double(day[.syncCalendarBuild].totalNs + day[.syncCalendarHash].totalNs
                             + day[.syncCalendarBaseline].totalNs) / 1e6
        XCTAssertGreaterThanOrEqual(wallMs, 400, "positive control: the network really took the held time")
        XCTAssertLessThan(spansMs, 100, "the spans are main-thread work only (wall \(wallMs)ms)")
        XCTAssertEqual(day[.syncLogsHash].count, 0, "another table's ids are untouched")
    }

    /// Each table group is charged under its own ids.
    func testLogsAndFeedbackAreChargedToTheirOwnTables() async throws {
        let event = events(1)[0]
        let occurrenceDate = Calendar.current.startOfDay(for: event.timeRanges[0].start)
        let key = CalendarOccurrenceKey.make(for: event, occurrenceDate: occurrenceDate)
        let log = CalendarEventLogRecord(id: key, eventID: event.id, baseSeriesEventID: nil,
                                         occurrenceDate: occurrenceDate, createdAt: Date(), updatedAt: Date())
        let feedback = CalendarEventFeedbackRecord(id: key, eventID: event.id, baseSeriesEventID: nil,
                                                   occurrenceDate: occurrenceDate, createdAt: Date(), updatedAt: Date())
        await service.syncLogs([log])
        await service.syncFeedback([feedback])
        let day = recorder.dailySnapshot()
        XCTAssertEqual(day[.syncLogsBuild].count, 1)
        XCTAssertEqual(day[.syncLogsHash].count, 1)
        XCTAssertEqual(day[.syncLogsBaseline].count, 2)
        XCTAssertEqual(day[.syncFeedbackBuild].count, 1)
        XCTAssertEqual(day[.syncFeedbackHash].count, 1)
        XCTAssertEqual(day[.syncFeedbackBaseline].count, 2)
        XCTAssertEqual(day[.syncCalendarHash].count, 0)
    }

    /// The settings row is one run per flush, before its network.
    func testTheSettingsFlushIsOneRun() async {
        defaults.set("dark", forKey: AppSettingsKeys.appearanceMode)
        await service.syncSettings()
        XCTAssertEqual(recorder.dailySnapshot()[.syncSettings].count, 1)
        XCTAssertGreaterThan(server.requests.count, 0, "positive control: the flush went on to the network")
    }

    func testTheBaselineTableNamesMapToTheirGroups() {
        XCTAssertEqual(FollowerSyncTable(baselineTable: SupabaseSyncService.eventsBaselineTable(kind: "calendar")), .calendar)
        XCTAssertEqual(FollowerSyncTable(baselineTable: SupabaseSyncService.eventsBaselineTable(kind: "todo")), .other)
        XCTAssertEqual(FollowerSyncTable(baselineTable: "event_logs"), .logs)
        XCTAssertEqual(FollowerSyncTable(baselineTable: "event_feedback"), .feedback)
        XCTAssertEqual(FollowerSyncTable(baselineTable: "todo_lists"), .other)
    }
}

// MARK: - (c) The backup snapshot, (d) the mirror, the widget

@MainActor
final class FollowerStoreFollowerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var location: EventStorageLocation!
    private var snapshotURL: URL!
    private var store: EventStore!
    private var types: EventTypeTemplateStore!
    private var skills: SkillInsightStore!
    private var prefs: AgentPreferenceStore!
    private var recorder: FollowerTimingRecorder!
    private var displaced: FollowerTimingRecorder?

    override func setUp() {
        super.setUp()
        suiteName = "FollowerStoreFollowerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        location = TestStorage.reset(suiteName)
        snapshotURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("follower-snapshot-\(UUID().uuidString).json")
        store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        types = EventTypeTemplateStore(defaults: defaults)
        skills = SkillInsightStore(defaults: defaults)
        prefs = AgentPreferenceStore(directoryURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FollowerPrefs-\(UUID().uuidString)", isDirectory: true))
        recorder = FollowerTimingRecorder(isForeground: true)
        displaced = FollowerTiming.recorder
        FollowerTiming.recorder = recorder
    }

    override func tearDown() {
        FollowerTiming.recorder = displaced
        try? FileManager.default.removeItem(at: snapshotURL)
        TestStorage.tearDown(suiteName)
        store = nil
        types = nil
        skills = nil
        prefs = nil
        super.tearDown()
    }

    private func event(_ title: String) -> Event {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return Event(title: title, timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))], kind: .event)
    }

    /// Every evaluation is one digest run; only a dirty one is followed by a
    /// write run — so a clean skip and a write are told apart on the record.
    func testTheSnapshotChargesTheDigestEveryTimeAndTheWriteOnlyWhenDirty() {
        store.addCalendarEvent(event("Dentist"))
        let service = BackupSnapshotService()
        service.settingsDefaults = defaults
        service.snapshotFileURLOverride = snapshotURL
        service.attach(eventStore: store, eventTypeStore: types, skillStore: skills, preferenceStore: prefs)

        service.writeSnapshotSync(reason: "test")       // dirty: writes
        service.writeSnapshotSync(reason: "test")       // clean: skips
        var day = recorder.dailySnapshot()
        XCTAssertEqual(day[.snapshotDigest].count, 2)
        XCTAssertEqual(day[.snapshotWrite].count, 1, "the clean evaluation wrote nothing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path), "positive control: the write landed")

        store.addCalendarEvent(event("Haircut"))
        service.writeSnapshotSync(reason: "test")       // dirty again
        day = recorder.dailySnapshot()
        XCTAssertEqual(day[.snapshotDigest].count, 3)
        XCTAssertEqual(day[.snapshotWrite].count, 2)
    }

    /// The mirror flush is one run when it has something to apply, none when
    /// its queue is empty.
    func testTheColorDepthMirrorFlushIsOneRunWhenItHasWork() throws {
        let target = event("Run")
        store.addCalendarEvent(target)
        store.flushCalendarEventColorDepthMirror()
        XCTAssertEqual(recorder.dailySnapshot()[.colorDepthMirror].count, 0, "nothing queued: no run")

        store.scheduleCalendarEventColorDepthMirror(eventID: target.id, effort: 5)
        store.flushCalendarEventColorDepthMirror()
        XCTAssertEqual(recorder.dailySnapshot()[.colorDepthMirror].count, 1)
        XCTAssertEqual(try XCTUnwrap(store.findCalendarEvent(id: target.id)).colorDepth,
                       Event.colorDepth(forEffort: 5), accuracy: 0.0001, "positive control: the mirror applied")
    }

    func testTheWidgetProjectionIsOneRunPerSync() {
        store.addCalendarEvent(event("Standup"))
        let before = recorder.dailySnapshot()[.widgetSnapshot].count
        store.flushWidgetSnapshotSync()
        XCTAssertEqual(recorder.dailySnapshot()[.widgetSnapshot].count, before + 1)
    }

    private final class WatchTransport: WristSessionTransport {
        var isReadyForSnapshot = true
        var pushes = 0
        func push(context: [String: Any]) throws { pushes += 1 }
    }

    /// One run per push while a watch can take one; none when it cannot.
    func testTheWatchPushIsOneRunWhenAWatchCanTakeIt() {
        store.addCalendarEvent(event("Gym"))
        let transport = WatchTransport()
        let bridge = WristBridge(ledger: WristAppliedLedger(defaults: defaults), defaults: defaults, transport: transport)
        bridge.attach(store: store, templates: types)
        XCTAssertEqual(recorder.dailySnapshot()[.wristSnapshot].count, 1, "the attach push")
        XCTAssertEqual(transport.pushes, 1, "positive control: it pushed")
        bridge.pushSnapshot()
        XCTAssertEqual(recorder.dailySnapshot()[.wristSnapshot].count, 2, "an unchanged push is still a run")
        transport.isReadyForSnapshot = false
        bridge.pushSnapshot()
        XCTAssertEqual(recorder.dailySnapshot()[.wristSnapshot].count, 2, "no watch to take it: no run")
    }

    /// Each scan's walk over the events and logs is one run.
    func testTheImageScanWalkIsOneRunPerScan() async throws {
        defaults.set(true, forKey: AppSettingsKeys.syncUploadsEnabled)
        let authName = suiteName + ".auth"
        let authSuite = try XCTUnwrap(UserDefaults(suiteName: authName))
        defer { authSuite.removePersistentDomain(forName: authName) }
        let session = AuthSession(accessToken: "t", refreshToken: "r", expiresAt: .distantFuture,
                                  user: AuthUser(id: "follower-user", email: nil, createdAt: nil))
        authSuite.set(try JSONEncoder().encode(session), forKey: "supabaseAuthSession")
        let auth = AuthService(defaults: authSuite, sessionStore: InMemorySessionStore())
        let assets = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FollowerAssets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: assets) }
        let coordinator = ImageBackupCoordinator(defaults: defaults,
                                                 assetStore: AgenticIntakeAssetStore(baseDirectoryURL: assets),
                                                 storageServiceFactory: { _ in ImageBackupCoordinatorTests.MockStorage() })
        store.addCalendarEvent(event("Photo walk"))
        coordinator.attach(eventStore: store, authService: auth)
        let deadline = Date().addingTimeInterval(5)
        while coordinator.completedScanCount < 1, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(coordinator.completedScanCount, 1, "fixture: the attach scan ran")
        XCTAssertEqual(recorder.dailySnapshot()[.imageScan].count, 1)
        await coordinator.scanAndUpload(reason: "follower-test")
        XCTAssertEqual(recorder.dailySnapshot()[.imageScan].count, 2)
        withExtendedLifetime(auth) {}
    }
}

// MARK: - (b) The occurrence cache, on the real calendar page

@MainActor
final class FollowerOccurrenceCacheTests: XCTestCase {
    private var suiteName: String!
    private var store: EventStore!
    private var recorder: FollowerTimingRecorder!
    private var displaced: FollowerTimingRecorder?
    private var window: UIWindow?
    private var displacedKey: UIWindow?

    override func setUp() {
        super.setUp()
        suiteName = "FollowerOccurrenceCacheTests-\(UUID().uuidString)"
        let location = TestStorage.reset(suiteName)
        store = EventStore(defaults: UserDefaults(suiteName: suiteName)!, storage: location, seedsSampleDataIfEmpty: false)
        recorder = FollowerTimingRecorder(isForeground: true)
        displaced = FollowerTiming.recorder
        FollowerTiming.recorder = recorder
    }

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        displacedKey?.makeKeyAndVisible()
        window = nil
        FollowerTiming.recorder = displaced
        TestStorage.tearDown(suiteName)
        store = nil
        super.tearDown()
    }

    private func host() {
        let page = CalendarPageView()
            .environmentObject(store)
            .environmentObject(CalendarViewState())
            .environmentObject(CalendarFocusState())
            .environmentObject(OrientationManager(landscapeFocusEnabled: false))
        // Inside a NavigationStack, as the app hosts it: without one the page's
        // navigation destinations leave it deaf to store changes.
        let controller = UIHostingController(rootView: NavigationStack { page })
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        displacedKey = scene?.windows.first(where: \.isKeyWindow)
        let made = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        made.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        made.rootViewController = controller
        made.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        window = made
    }

    /// Synchronous run-loop pumping, as the other hosted-view tests do: an
    /// async wait does not run the default-mode run loop SwiftUI commits its
    /// updates in, so a store change would never reach the page.
    private func pump(until condition: () -> Bool, seconds: Double = 8) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// Pumps until the batch count has not moved for a while: the progressive
    /// fill has finished.
    private func pumpUntilBatchesSettle() {
        var last = -1
        var stableSince = Date()
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            let now = recorder.dailySnapshot()[.occurrenceBatch].count
            if now != last {
                last = now
                stableSince = Date()
            } else if Date().timeIntervalSince(stableSince) > 0.5 {
                return
            }
        }
    }

    /// A store change rebuilds the cache: one synchronous run, then every
    /// progressive batch of the day range as its own run.
    func testAStoreChangeIsOneSynchronousRunAndOneRunPerBatch() throws {
        host()
        pump(until: { self.recorder.dailySnapshot()[.occurrenceSync].count >= 1 })
        pumpUntilBatchesSettle()
        let base = recorder.dailySnapshot()
        XCTAssertGreaterThanOrEqual(base[.occurrenceSync].count, 1, "fixture: the page rebuilt on appear")
        XCTAssertGreaterThan(base[.occurrenceBatch].count, 0, "fixture: the appear rebuild filled progressively")

        let start = Date().addingTimeInterval(3600)
        store.addCalendarEvent(Event(title: "New", timeRanges: [.init(start: start, end: start.addingTimeInterval(1800))]))
        pump(until: { self.recorder.dailySnapshot()[.occurrenceSync].count > base[.occurrenceSync].count })
        pumpUntilBatchesSettle()
        let after = recorder.dailySnapshot()
        XCTAssertEqual(after[.occurrenceSync].count, base[.occurrenceSync].count + 1, "one synchronous run per change")
        // Nothing scrolled, so the range is the default one: the selected day
        // ± 7 synchronously, the rest in five-day batches.
        let range = CalendarLayout.defaultDayRange
        let urgent = max(range.lowerBound, -7)...min(range.upperBound, 7)
        let expectedBatches = (range.count - urgent.count + 4) / 5
        XCTAssertEqual(after[.occurrenceBatch].count - base[.occurrenceBatch].count, expectedBatches,
                       "one run per batch")
        XCTAssertGreaterThan(after[.occurrenceBatch].maxNs, 0)
        XCTAssertLessThan(after[.occurrenceBatch].maxNs, after[.occurrenceBatch].totalNs,
                          "each batch is its own run: the longest is less than the sum")
    }
}

// MARK: - Upload against a registry that lacks the new keys

/// Production's `public.spike_runs` stores `metrics` as jsonb with no check
/// against `public.key_registry` (migration 016): the registry is read only by
/// the views. A TestFlight build that writes the follower keys therefore
/// uploads against a production registry that has never heard of them, and
/// the rows land whole; the keys stay out of the registry-driven views until
/// the registry rows are loaded. `SyncFakeServer` validates exactly what 016
/// enforces (NOT NULL, the check constraints, RLS) and nothing about metric
/// keys. The positive control turns on a registry check the real server does
/// not have, to show the harness would see a refusal.
@MainActor
final class FollowerUploadTests: XCTestCase {
    private let uid = TelemetryFixtures.uid
    private var location: SpikeRunStorageLocation!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var server: SyncFakeServer!
    private var coordinator: SpikeSessionCoordinator!
    private var centers: [ResidentObservationCenter] = []
    private var displaced: FollowerTimingRecorder?
    private let clockNow = TelemetryFixtures.t0

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
        suiteName = "FollowerUploadTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        server = SyncFakeServer(userId: uid)
        coordinator = SpikeSessionCoordinator()
        displaced = FollowerTiming.recorder
        FollowerTiming.recorder = nil
    }

    override func tearDown() {
        for center in centers { center.deactivate() }
        centers = []
        FollowerTiming.recorder = displaced
        SpikeProbe.onSignal = nil
        try? FileManager.default.removeItem(at: location.directory)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// The registry as production has it today: every key that is not a
    /// follower key (the follower keys are what this change adds).
    private func productionRegistry() throws -> Set<String> {
        struct Entry: Decodable { let key: String }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("done-mcp/supabase/telemetry/key_registry.json")
        let all = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url)).map(\.key)
        return Set(all.filter { !$0.hasPrefix("fl.") && !$0.hasPrefix("wfl.") })
    }

    /// A day and a window written by the real center with the probe on.
    private func writeRecords() {
        let followerClock = FollowerManualClock()
        let now = clockNow
        let center = ResidentObservationCenter(
            coordinator: coordinator, store: nil, location: location, calendar: .current,
            now: { now }, mediaNow: { 500 }, makeFrameProbe: { SpikeFrameProbe() },
            ownerUID: { TelemetryFixtures.uid },
            followerClock: { followerClock.ns }, installsFollowerProbe: true, isAppActive: { true }
        )
        centers.append(center)
        center.activate()
        SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .changed, eventTime: nil, locationX: 100))
        SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .ended, eventTime: nil, locationX: 100))
        SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .commitStart, eventTime: nil, locationX: 0))
        SpikeProbe.emit(.gesture(Spike201SignalID.effortScrubber, .commitEnd, eventTime: nil, locationX: 0))
        FollowerTiming.measure(.syncCalendarHash) { followerClock.advance(ms: 95) }
        center.closeWindow()
        center.flushDaily()
        center.deactivate()
    }

    private func makeUploader() -> TelemetryUploader {
        var deps = TelemetryUploader.Dependencies()
        deps.defaults = defaults
        deps.location = location
        let now = clockNow.addingTimeInterval(60)
        deps.now = { now }
        deps.launchDelay = 0
        deps.makeKeepAlive = { nil }
        deps.bootstrapOwner = { nil }
        let uploader = TelemetryUploader(dependencies: deps)
        let user = uid
        uploader.attach(TelemetryUploader.Attachment(gateway: server, isBlockedByBuild: { false },
                                                     currentUserID: { user }, isSignedIn: { true }))
        defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        TelemetryConsentStore.recordGrant(defaults, at: clockNow.addingTimeInterval(-3600))
        return uploader
    }

    private func onDisk() -> [SpikeRun] {
        SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.residentDailySpikeID, location: location)
            + SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.effortPathFixID, location: location)
    }

    func testRowsCarryingKeysTheProductionRegistryLacksLandWhole() async throws {
        writeRecords()
        let registry = try productionRegistry()
        let records = onDisk()
        XCTAssertEqual(records.count, 2, "fixture: a day and a window")
        let uploader = makeUploader()

        let outcome = await uploader.uploadNow(trigger: .deckOpen)

        XCTAssertEqual(outcome, .uploaded(rows: 2))
        XCTAssertEqual(uploader.quarantinedCount, 0)
        for record in records {
            let row = try XCTUnwrap(server.telemetryRow(runID: record.id), "\(record.spikeID) landed")
            let metrics = try XCTUnwrap(row.data["metrics"] as? [String: Any])
            let unknown = Set(metrics.keys).subtracting(registry)
            XCTAssertFalse(unknown.isEmpty, "\(record.spikeID): the row does carry keys production has not registered")
            XCTAssertTrue(unknown.allSatisfy { $0.hasPrefix("fl.") || $0.hasPrefix("wfl.") }, "\(unknown.sorted())")
            XCTAssertEqual(Set(metrics.keys), Set(record.metrics.keys), "\(record.spikeID): every key went up — none redacted")
        }
        let window = try XCTUnwrap(records.first { $0.spikeID == FixObservationRegistry.effortPathFixID })
        let windowRow = try XCTUnwrap(server.telemetryRow(runID: window.id)?.data["metrics"] as? [String: Any])
        XCTAssertEqual((windowRow["wfl.syncCal.hash.ms"] as? NSNumber)?.doubleValue, 95)
        let again = await uploader.uploadNow(trigger: .deckOpen)
        XCTAssertEqual(again, .nothingPending, "the cursor took both")
    }

    /// Positive control: a server that DID refuse unregistered keys would
    /// refuse these rows, and the uploader would park them — the outcome the
    /// test above rules out for the real server.
    func testPositiveControlARegistryEnforcingServerWouldRefuseTheseRows() async throws {
        writeRecords()
        let registry = try productionRegistry()
        server.failWhen = { [weak server] verb, table in
            guard verb == .telemetryUpsert,
                  let rows = server?.requests.last?.body as? [[String: Any]] else { return nil }
            let refused = rows.contains { row in
                Set((row["metrics"] as? [String: Any] ?? [:]).keys).subtracting(registry).isEmpty == false
            }
            return refused ? SupabaseREST.SyncError.requestFailed(table: table, method: "POST", status: 400, code: "23514") : nil
        }
        let uploader = makeUploader()

        let outcome = await uploader.uploadNow(trigger: .deckOpen)

        XCTAssertEqual(outcome, .partial(uploaded: 0, quarantined: 2))
        XCTAssertEqual(server.telemetryRowCount(), 0)
    }
}
