//
//  UsageDailyQATests.swift
//  DoneTests
//
//  Independent QA for gh#273 §6.3 `usage-daily`, slice 1. Written against
//  the design document, not the implementer's summary. Every expectation
//  here comes from the spec's wording (§6.3, §6.3.1, §11 items 13-18,
//  appendix D) or from an artifact other than the code under test (the
//  server's key registry JSON); nothing re-types a value the code computes.
//

import XCTest
import SwiftUI
import UIKit
@testable import Done

// MARK: - Shared rig

private final class QABox<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

@MainActor
private enum UsageQARig {
    static let uid = "11111111-2222-4333-8444-555555555555"

    static var la: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    /// A civil time in Los Angeles on 2026-09-21 (or the day after).
    static func at(_ hour: Int, _ minute: Int, _ second: Int = 0, nextDay: Bool = false) -> Date {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 9; parts.day = nextDay ? 22 : 21
        parts.hour = hour; parts.minute = minute; parts.second = second
        return la.date(from: parts)!
    }

    static func stamp() -> SpikeRunContext.Stamp {
        SpikeRunContext.Stamp(appVersion: "0.5.0", appBuild: "29", appCommit: nil, deviceModel: "iPhone17,2",
                              osVersion: "26.0", timeZoneIdentifier: "America/Los_Angeles",
                              localeIdentifier: "en_US", buildConfiguration: "release")
    }

    static func makeCenter(
        location: SpikeRunStorageLocation, clock: QABox<Date>, media: QABox<Double>,
        countsLaunchSession: Bool, gates: QABox<Set<UsageGate>> = QABox([]),
        owner: QABox<String?>? = nil
    ) -> ResidentObservationCenter {
        let ownerBox = owner ?? QABox<String?>(uid)
        let center = ResidentObservationCenter(
            coordinator: SpikeSessionCoordinator(), store: nil, location: location, calendar: la,
            now: { clock.value }, mediaNow: { media.value },
            makeFrameProbe: { SpikeFrameProbe() },
            ownerUID: { ownerBox.value }, stamp: { stamp() },
            installsFollowerProbe: false, isAppActive: { true }, verifiesSeed: false,
            seedTrail: { _ in }, countsLaunchSession: countsLaunchSession, isAppForeground: { true },
            availableGates: { gates.value }
        )
        center.activate()
        return center
    }

    static func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }

    static func records(_ location: SpikeRunStorageLocation) -> [SpikeRun] {
        SpikeRunStore.loadRuns(spikeID: UsageRecordIDs.spikeID, location: location)
            .sorted { $0.startedAt < $1.startedAt }
    }

    static func number(_ run: SpikeRun?, _ key: String) -> Int? {
        if case .number(let value)? = run?.metrics[key] { return Int(value) }
        return nil
    }

    static func histogram(_ run: SpikeRun?, _ key: String) -> [Int]? {
        if case .string(let text)? = run?.metrics[key] { return text.split(separator: " ").compactMap { Int($0) } }
        return nil
    }

    /// The spec's dwell buckets (§6.3: bounds 3 / 30 / 300 s, four buckets,
    /// appendix D: upper bounds exclusive) — written from the document, not
    /// read from `UsageDwell`.
    static func specBucket(_ seconds: Double) -> Int {
        [3.0, 30.0, 300.0].filter { seconds >= $0 }.count
    }

    static func oneVisit(in bucket: Int) -> [Int] {
        (0..<4).map { $0 == bucket ? 1 : 0 }
    }

    /// The server's registry rows for `usage-daily` (key → value_schema).
    static func registryUsageKeys(file: StaticString = #filePath) throws -> [String: String] {
        struct Entry: Decodable { let key: String; let value_schema: String; let spike_id: String }
        let url = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("done-mcp/supabase/telemetry/key_registry.json")
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
        return Dictionary(uniqueKeysWithValues: entries.filter { $0.spike_id == "usage-daily" }.map { ($0.key, $0.value_schema) })
    }

    static func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}

// MARK: - Settlement across midnight (§6.3 "访问在离开那天结算")

@MainActor
final class UsageQAMidnightTests: XCTestCase {
    private var location: SpikeRunStorageLocation!
    private var center: ResidentObservationCenter?
    private var displacedSink: UsageSink?
    private var displacedRecorder: FollowerTimingRecorder?

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
        displacedSink = UsageProbe.sink
        displacedRecorder = FollowerTiming.recorder
        FollowerTiming.recorder = nil
    }

    override func tearDown() {
        center?.deactivate()
        center = nil
        UsageProbe.sink = displacedSink
        FollowerTiming.recorder = displacedRecorder
        try? FileManager.default.removeItem(at: location.directory)
        super.tearDown()
    }

    /// The app stays in the foreground across midnight with a focus visit
    /// open (focus keeps the screen awake), and nothing else is counted in
    /// between. The user swipes focus away four minutes after midnight: that
    /// visit ended on the new day, so its dwell, its abandonment and its exit
    /// route belong to the new day's record. The enter stays on the old day.
    func testAForegroundVisitOpenAcrossMidnightSettlesOnTheDayItEnds() throws {
        let clock = QABox(UsageQARig.at(23, 58))
        let media = QABox(0.0)
        center = UsageQARig.makeCenter(location: location, clock: clock, media: media, countsLaunchSession: true)

        UsageProbe.enter(.focusTap)
        clock.value = UsageQARig.at(0, 2, nextDay: true)
        media.value = 240
        UsageProbe.leave(.focus, via: .focusSwipe)
        center?.performRolloverFlushIfDue()   // the hop the leave scheduled
        center?.flushDaily()

        let records = UsageQARig.records(location)
        XCTAssertEqual(records.count, 2, "one usage line per day")
        guard records.count == 2 else { return }
        let (old, new) = (records[0], records[1])
        XCTAssertNotEqual(old.dayKey, new.dayKey, "fixture: the two lines are two civil days")

        XCTAssertEqual(UsageQARig.number(old, "usage.focus.enter.tap"), 1, "entered on the old day")
        XCTAssertNil(old.metrics["usage.focus.dwell"], "the old day did not see this visit end")
        XCTAssertNil(old.metrics["usage.focus.abandon"])
        XCTAssertNil(old.metrics["usage.focus.exit.swipe"])

        XCTAssertEqual(UsageQARig.histogram(new, "usage.focus.dwell"), UsageQARig.oneVisit(in: UsageQARig.specBucket(240)),
                       "the visit ended on the new day, so it settles there")
        XCTAssertEqual(UsageQARig.number(new, "usage.focus.abandon"), 1)
        XCTAssertEqual(UsageQARig.number(new, "usage.focus.exit.swipe"), 1)
    }

    /// Same shape without a visit: the app has been in the foreground since
    /// before midnight and the first thing counted after midnight is a use.
    /// It happened on the new day.
    func testTheFirstSignalAfterMidnightInAForegroundSessionCountsOnTheNewDay() throws {
        let clock = QABox(UsageQARig.at(22, 0))
        let media = QABox(0.0)
        center = UsageQARig.makeCenter(location: location, clock: clock, media: media, countsLaunchSession: true)
        UsageProbe.use(.allDayToggle)
        center?.flushDaily()

        clock.value = UsageQARig.at(0, 30, nextDay: true)
        UsageProbe.use(.repeatForm)
        center?.performRolloverFlushIfDue()
        center?.flushDaily()

        let records = UsageQARig.records(location)
        XCTAssertEqual(records.count, 2)
        guard records.count == 2 else { return }
        XCTAssertEqual(UsageQARig.number(records[0], "usage.all_day.use"), 1, "positive control: the evening's use stays on its day")
        XCTAssertNil(records[0].metrics["usage.repeat.use.form"], "00:30 is not the old day")
        XCTAssertEqual(UsageQARig.number(records[1], "usage.repeat.use.form"), 1, "00:30 is the new day")
    }

    /// The common way a visit spans midnight: the app goes to the background
    /// with the detail open before midnight and comes back after it. The
    /// return rolls the day over first, so the settle lands on the new day.
    func testAVisitOpenAcrossMidnightThroughTheBackgroundSettlesOnTheNewDay() throws {
        let clock = QABox(UsageQARig.at(23, 50))
        let media = QABox(0.0)
        center = UsageQARig.makeCenter(location: location, clock: clock, media: media, countsLaunchSession: true)

        UsageProbe.enter(.eventDetailCanvas)
        clock.value = UsageQARig.at(23, 51)
        media.value = 60
        UsageQARig.post(UIApplication.willResignActiveNotification)
        UsageQARig.post(UIApplication.didEnterBackgroundNotification)

        clock.value = UsageQARig.at(0, 10, nextDay: true)
        media.value = 1260
        UsageQARig.post(UIApplication.willEnterForegroundNotification)
        UsageQARig.post(UIApplication.didBecomeActiveNotification)
        clock.value = UsageQARig.at(0, 10, 5, nextDay: true)
        media.value = 1265
        UsageProbe.leave(.eventDetail)
        center?.flushDaily()

        let records = UsageQARig.records(location)
        XCTAssertEqual(records.count, 2)
        guard records.count == 2 else { return }
        let (old, new) = (records[0], records[1])
        XCTAssertEqual(UsageQARig.number(old, "usage.event_detail.enter.canvas"), 1)
        XCTAssertNil(old.metrics["usage.event_detail.dwell"])
        XCTAssertNil(old.metrics["usage.event_detail.abandon"])
        XCTAssertEqual(UsageQARig.number(old, "sessions"), 1)

        // 60 s before the background, 5 s after the return; the 19 min away do not count.
        XCTAssertEqual(UsageQARig.histogram(new, "usage.event_detail.dwell"), UsageQARig.oneVisit(in: UsageQARig.specBucket(65)))
        XCTAssertEqual(UsageQARig.number(new, "usage.event_detail.abandon"), 1)
        XCTAssertEqual(UsageQARig.number(new, "sessions"), 1, "the return is the new day's session")
        XCTAssertNil(new.metrics["usage.event_detail.enter.canvas"], "coming back is not an enter")
    }
}

// MARK: - Dwell at the bucket bounds, through the real lifecycle notifications

@MainActor
final class UsageQADwellBoundsTests: XCTestCase {
    private var location: SpikeRunStorageLocation!
    private var center: ResidentObservationCenter?
    private var displacedSink: UsageSink?
    private var displacedRecorder: FollowerTimingRecorder?

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
        displacedSink = UsageProbe.sink
        displacedRecorder = FollowerTiming.recorder
        FollowerTiming.recorder = nil
    }

    override func tearDown() {
        center?.deactivate()
        center = nil
        UsageProbe.sink = displacedSink
        FollowerTiming.recorder = displacedRecorder
        try? FileManager.default.removeItem(at: location.directory)
        super.tearDown()
    }

    /// Each visit: 0.5 s, then Control Center for 0.5 s (still foreground
    /// time: the surface is on screen), 0.5 s more, ten minutes in the
    /// background (not counted), then the rest. The foreground total sits
    /// just under and exactly on each of the spec's bounds.
    func testDwellAtTheBoundsCountsControlCenterTimeAndSkipsBackgroundTime() throws {
        let clock = QABox(UsageQARig.at(10, 0))
        let media = QABox(1000.0)
        let made = UsageQARig.makeCenter(location: location, clock: clock, media: media, countsLaunchSession: true)
        center = made

        for total in [2.5, 3.0, 29.5, 30.0, 299.5, 300.0] {
            let before = made.usage.counts.dwellBuckets(.create) ?? []
            let sessionsBefore = made.usage.counts.count("sessions") ?? -1

            UsageProbe.enter(.createPlus)
            media.value += 0.5
            UsageQARig.post(UIApplication.willResignActiveNotification)   // Control Center down
            media.value += 0.5
            UsageQARig.post(UIApplication.didBecomeActiveNotification)    // and up again
            media.value += 0.5
            UsageQARig.post(UIApplication.willResignActiveNotification)
            UsageQARig.post(UIApplication.didEnterBackgroundNotification)
            media.value += 600
            UsageQARig.post(UIApplication.willEnterForegroundNotification)
            UsageQARig.post(UIApplication.didBecomeActiveNotification)
            media.value += total - 1.5
            UsageProbe.leave(.create, via: .createCancel)

            let after = made.usage.counts.dwellBuckets(.create) ?? []
            XCTAssertEqual(after.count, 4, "four buckets")
            let delta = zip(after, before + [0, 0, 0, 0]).map { $0 - $1 }
            XCTAssertEqual(delta, UsageQARig.oneVisit(in: UsageQARig.specBucket(total)), "foreground total \(total) s")
            XCTAssertEqual(made.usage.counts.count("sessions"), sessionsBefore + 1,
                           "the return from background is one session; Control Center is none (\(total) s)")
        }
    }
}

// MARK: - Invariants over random lifecycles (pure tracker)

@MainActor
final class UsageQAInvariantTests: XCTestCase {
    /// Deterministic generator (SplitMix64) so a failure replays.
    private struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
        mutating func bool() -> Bool { next() & 1 == 1 }
    }

    /// The spec's names: features with visits, and the gate-owning ones.
    private static let visited = ["focus", "focus_precreate", "event_detail", "create", "repeat"]
    private static let available = ["usage.focus.available", "usage.todo_stack.available",
                                    "usage.wanna.available", "usage.report.available",
                                    "usage.reminders.available"]

    private func sum(_ counts: UsageCounts, prefix: String, excluding: Set<String> = []) -> Int {
        UsageLayout.shared.keys
            .filter { $0.kind == .counter && $0.name.hasPrefix(prefix) && !excluding.contains($0.name) }
            .reduce(0) { $0 + (counts.count($1.name) ?? 0) }
    }

    private func dwellTotal(_ counts: UsageCounts, _ feature: String) -> Int {
        guard let key = UsageLayout.shared.keysByName["usage.\(feature).dwell"],
              let f = key.feature, let buckets = counts.dwellBuckets(f) else { return 0 }
        return buckets.reduce(0, +)
    }

    /// Settles of one feature in one record: the bare abandon, or the
    /// abandon routes; `create.abandon.banner` is not a settle (appendix D).
    private func abandons(_ counts: UsageCounts, _ feature: String) -> Int {
        (counts.count("usage.\(feature).abandon") ?? 0)
            + sum(counts, prefix: "usage.\(feature).abandon.", excluding: ["usage.create.abandon.banner"])
    }

    func testRandomLifecyclesKeepAvailableAtOrBelowSessionsAndSettlesAtOrBelowEnters() {
        var rng = Rng(state: 0x2730_6301)
        var violations: [String] = []
        var liveness = (available: 0, sessions: 0, abandons: 0, dwell: 0, records: 0)

        for run in 0..<400 {
            var tracker = UsageTracker()
            var on: Set<UsageGate> = []
            var media = 0.0
            var foreground = false
            var closed: [UsageCounts] = []

            func closeRecord(_ why: String) {
                let counts = tracker.counts
                let sessions = counts.count("sessions") ?? 0
                for name in Self.available where (counts.count(name) ?? 0) > sessions {
                    violations.append("run \(run) \(why): \(name)=\(counts.count(name) ?? 0) > sessions=\(sessions)")
                }
                for feature in Self.visited {
                    let dwell = dwellTotal(counts, feature)
                    if abandons(counts, feature) > dwell {
                        violations.append("run \(run) \(why): \(feature) abandons > settled visits")
                    }
                    if sum(counts, prefix: "usage.\(feature).exit.") > dwell {
                        violations.append("run \(run) \(why): \(feature) exit routes > settled visits")
                    }
                }
                liveness.records += 1
                liveness.sessions += sessions
                liveness.available += Self.available.reduce(0) { $0 + (counts.count($1) ?? 0) }
                closed.append(counts)
            }

            for _ in 0..<80 {
                media += Double(rng.int(400)) / 10
                switch rng.int(14) {
                case 0:
                    if !foreground { tracker.enterForeground(at: media, available: on); foreground = true }
                case 1:
                    if foreground { tracker.enterBackground(at: media); foreground = false }
                case 2:
                    // Control Center / Face ID: a didBecomeActive with no background.
                    tracker.enterForeground(at: media, available: on)
                    foreground = true
                case 3:
                    // The user flips a switch in Settings (foreground only; the
                    // setter fires only on a real change).
                    if foreground {
                        let gate = UsageGate.allCases[rng.int(UsageGate.allCases.count)]
                        let isOn = !on.contains(gate)
                        tracker.switchToggled(gate, isOn: isOn)
                        if isOn { on.insert(gate) } else { on.remove(gate) }
                    }
                case 4:
                    closeRecord("re-mint")
                    tracker.resetCountsForNewRecord(available: on)
                case 5:
                    closeRecord("erase")
                    tracker.forgetAll(available: on)
                case 6, 7:
                    tracker.enter(UsageEntry.allCases[rng.int(UsageEntry.allCases.count)], at: media)
                case 8:
                    tracker.use(UsageUse.allCases[rng.int(UsageUse.allCases.count)])
                case 9:
                    tracker.done(UsageDone.allCases[rng.int(UsageDone.allCases.count)])
                case 10:
                    tracker.noteExit(UsageRoute.allCases[rng.int(UsageRoute.allCases.count)])
                case 11:
                    tracker.count(UsageEvent.allCases[rng.int(UsageEvent.allCases.count)])
                case 12 where rng.int(4) == 0:
                    // A center activated in the foreground without counting
                    // the launch (the test host's path).
                    tracker.assumeForeground()
                    foreground = true
                default:
                    let feature = UsageFeature.allCases[rng.int(UsageFeature.allCases.count)]
                    let route: UsageRoute? = rng.bool() ? UsageRoute.allCases[rng.int(UsageRoute.allCases.count)] : nil
                    tracker.leave(feature, via: route, at: media)
                }
            }
            closeRecord("end")

            // Across the run's records (visits carry over re-mints): no
            // feature settles more visits than it was entered.
            for feature in Self.visited {
                let enters = closed.reduce(0) { $0 + sum($1, prefix: "usage.\(feature).enter.") }
                let settles = closed.reduce(0) { $0 + dwellTotal($1, feature) }
                let gaveUp = closed.reduce(0) { $0 + abandons($1, feature) }
                if settles > enters { violations.append("run \(run): \(feature) settled \(settles) > entered \(enters)") }
                if gaveUp > enters { violations.append("run \(run): \(feature) abandoned \(gaveUp) > entered \(enters)") }
                liveness.abandons += gaveUp
                liveness.dwell += settles
            }
        }

        XCTAssertEqual(Array(violations.prefix(10)), [], "\(violations.count) violations")
        XCTAssertGreaterThan(liveness.available, 100, "liveness: switches were counted")
        XCTAssertGreaterThan(liveness.sessions, liveness.available / 4, "liveness: sessions were counted")
        XCTAssertGreaterThan(liveness.abandons, 100, "liveness: visits were abandoned")
        XCTAssertGreaterThan(liveness.dwell, liveness.abandons, "liveness: used visits settled too")
        XCTAssertGreaterThan(liveness.records, 400, "liveness: re-mints and erases happened")
    }
}

// MARK: - What lands on disk

@MainActor
final class UsageQARecordTests: XCTestCase {
    private var location: SpikeRunStorageLocation!
    private var center: ResidentObservationCenter?
    private var displacedSink: UsageSink?
    private var displacedRecorder: FollowerTimingRecorder?

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
        displacedSink = UsageProbe.sink
        displacedRecorder = FollowerTiming.recorder
        FollowerTiming.recorder = nil
    }

    override func tearDown() {
        center?.deactivate()
        center = nil
        UsageProbe.sink = displacedSink
        FollowerTiming.recorder = displacedRecorder
        try? FileManager.default.removeItem(at: location.directory)
        super.tearDown()
    }

    private func feature(of entry: UsageEntry) -> (UsageFeature, UsageRoute?) {
        switch entry {
        case .focusTap, .focusAuto: return (.focus, .focusRotate)
        case .focusPrecreatePill: return (.focusPrecreate, nil)
        case .eventDetailCanvas, .eventDetailMenu, .eventDetailList, .eventDetailSearch: return (.eventDetail, nil)
        case .createDrag, .createPlus, .createResumeDraft, .createReminderAI: return (.create, .createCancel)
        case .repeatRuleEditor: return (.repeatRule, nil)
        }
    }

    /// The visit a use or done happens inside (round 2: one arriving after its
    /// visit ended is a late write and is dropped). nil: the stage belongs to
    /// no visit (the all-day switch, a repeat picked in an event form).
    private func visit(for use: UsageUse) -> (UsageEntry, UsageFeature, UsageRoute?)? {
        switch use {
        case .focusExtend, .focusEndNow, .focusNote, .focusTrack: return (.focusTap, .focus, .focusRotate)
        case .eventDetailPlan, .eventDetailReflect, .eventDetailTimelineNote, .eventDetailTodo, .eventDetailDelete:
            return (.eventDetailCanvas, .eventDetail, nil)
        case .repeatDeleteSeries: return (.repeatRuleEditor, .repeatRule, nil)
        case .repeatForm, .allDayToggle: return nil
        case .archivedFocusOn, .archivedFocusOff, .archivedTodoStackOn, .archivedTodoStackOff,
             .archivedWannaOn, .archivedWannaOff, .archivedReportOn, .archivedReportOff,
             .archivedRemindersOn, .archivedRemindersOff: return nil
        }
    }

    private func visit(for done: UsageDone) -> (UsageEntry, UsageFeature, UsageRoute?) {
        switch done {
        case .focusPrecreate: return (.focusPrecreatePill, .focusPrecreate, nil)
        case .create, .createRepeat, .createAllDay, .createNote: return (.createPlus, .create, .createCancel)
        case .repeatRule: return (.repeatRuleEditor, .repeatRule, nil)
        }
    }

    /// Every use and done of the slice, each inside a visit of its feature.
    private func useAndCompleteEverything(toggles: Set<UsageUse>) {
        for use in UsageUse.allCases where !toggles.contains(use) {
            if let (entry, feature, route) = visit(for: use) {
                UsageProbe.enter(entry)
                UsageProbe.use(use)
                UsageProbe.leave(feature, via: route)
            } else {
                UsageProbe.use(use)
            }
        }
        for done in UsageDone.allCases {
            let (entry, feature, route) = visit(for: done)
            UsageProbe.enter(entry)
            UsageProbe.done(done)
            UsageProbe.leave(feature, via: route)
        }
    }

    private func feature(of route: UsageRoute) -> (UsageFeature, UsageEntry) {
        switch route {
        case .focusSwipe, .focusRotate, .focusSystem: return (.focus, .focusTap)
        case .createCancel, .createDismiss: return (.create, .createPlus)
        }
    }

    /// A day on which every stage of this slice happened at least once. The
    /// line on disk must carry exactly the registry's usage keys — nothing
    /// the server does not know, nothing left out — each a whole count or
    /// four whole buckets, and no free text. Its size is measured.
    func testAFullDaysLineHoldsExactlyTheRegistryKeysAsBareNumbers() throws {
        let clock = QABox(UsageQARig.at(10, 0))
        let media = QABox(0.0)
        let gates = QABox(Set(UsageGate.allCases))
        center = UsageQARig.makeCenter(location: location, clock: clock, media: media,
                                       countsLaunchSession: true, gates: gates)

        for entry in UsageEntry.allCases {
            UsageProbe.enter(entry)
            media.value += 5
            let (f, route) = feature(of: entry)
            UsageProbe.leave(f, via: route)
        }
        for route in UsageRoute.allCases {
            let (f, entry) = feature(of: route)
            UsageProbe.enter(entry)
            media.value += 40
            UsageProbe.leave(f, via: route)
        }
        let toggles = Set(UsageGate.allCases.flatMap { [$0.toggleTags.on, $0.toggleTags.off] })
        useAndCompleteEverything(toggles: toggles)
        for gate in UsageGate.allCases {
            UsageProbe.switchToggled(gate, isOn: false)
            UsageProbe.switchToggled(gate, isOn: true)
        }
        for view in UsageView.allCases { UsageProbe.view(view) }
        for event in UsageEvent.allCases { UsageProbe.count(event) }
        center?.flushDaily()

        let url = SpikeRunStore.fileURL(spikeID: UsageRecordIDs.spikeID, location: location)
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n").filter { !$0.isEmpty }
        let line = try XCTUnwrap(lines.last, "the usage line was written")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let metrics = try XCTUnwrap(object["metrics"] as? [String: Any])

        let registry = try UsageQARig.registryUsageKeys()
        XCTAssertGreaterThan(registry.count, 40, "liveness: the registry was read")
        XCTAssertEqual(Set(metrics.keys).subtracting(registry.keys).sorted(), [], "keys the server does not register")
        XCTAssertEqual(Set(registry.keys).subtracting(metrics.keys).sorted(), [], "registered keys a full day never wrote")

        var shapes: [String] = []
        for (key, value) in metrics {
            switch registry[key] {
            case "number":
                let n = value as? NSNumber
                if n == nil || CFGetTypeID(n!) == CFBooleanGetTypeID() || n!.doubleValue < 1 || n!.doubleValue.rounded() != n!.doubleValue {
                    shapes.append("\(key): \(value)")
                }
            case "fixed_string":
                let parts = (value as? String ?? "").split(separator: " ", omittingEmptySubsequences: false)
                if parts.count != 4 || !parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) { shapes.append("\(key): \(value)") }
            default:
                shapes.append("\(key): unregistered")
            }
        }
        XCTAssertEqual(shapes, [], "counts are positive whole numbers, dwell is four whole buckets")
        for field in ["note", "abortReason", "variantID"] {
            XCTAssertTrue(object[field] == nil || object[field] is NSNull, "\(field) carries nothing on a usage line")
        }

        let bytes = line.utf8.count
        let attachment = XCTAttachment(string: "usage line with all \(metrics.count) keys: \(bytes) bytes")
        attachment.lifetime = .keepAlways
        add(attachment)
        print("QA-MEASURE usage line all-keys bytes=\(bytes) keys=\(metrics.count)")
        XCTAssertLessThan(bytes, 3 * 1024, "a full day stays near the spec's ~2 KB, not several times it")
    }

    /// The same full day, uploaded: the redactor must let every legitimate
    /// usage key through unchanged (a histogram or a key it does not know
    /// how to judge would silently vanish on the server), and nothing else.
    func testAFullDaysLineGoesUpWholeThroughTheRedactor() async throws {
        let clock = QABox(UsageQARig.at(10, 0))
        let media = QABox(0.0)
        center = UsageQARig.makeCenter(location: location, clock: clock, media: media,
                                       countsLaunchSession: true, gates: QABox(Set(UsageGate.allCases)))
        for entry in UsageEntry.allCases {
            UsageProbe.enter(entry)
            media.value += 400
            let (f, route) = feature(of: entry)
            UsageProbe.leave(f, via: route)
        }
        for route in UsageRoute.allCases {
            let (f, entry) = feature(of: route)
            UsageProbe.enter(entry)
            UsageProbe.leave(f, via: route)
        }
        let toggles = Set(UsageGate.allCases.flatMap { [$0.toggleTags.on, $0.toggleTags.off] })
        useAndCompleteEverything(toggles: toggles)
        for gate in UsageGate.allCases {
            UsageProbe.switchToggled(gate, isOn: false)
            UsageProbe.switchToggled(gate, isOn: true)
        }
        for view in UsageView.allCases { UsageProbe.view(view) }
        for event in UsageEvent.allCases { UsageProbe.count(event) }
        center?.flushDaily()
        let onDisk = try XCTUnwrap(UsageQARig.records(location).last)

        let suite = "UsageQAUpload-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var deps = TelemetryUploader.Dependencies()
        deps.defaults = defaults
        deps.location = location
        let later = UsageQARig.at(11, 0)
        deps.now = { later }
        deps.launchDelay = 0
        deps.makeKeepAlive = { nil }
        deps.bootstrapOwner = { nil }
        let uploader = TelemetryUploader(dependencies: deps)
        let server = SyncFakeServer(userId: UsageQARig.uid)
        let user = UsageQARig.uid
        uploader.attach(TelemetryUploader.Attachment(gateway: server, isBlockedByBuild: { false },
                                                     currentUserID: { user }, isSignedIn: { true }))
        defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        TelemetryConsentStore.recordGrant(defaults, at: UsageQARig.at(9, 0))
        _ = await uploader.uploadNow(trigger: .deckOpen)

        let row = try XCTUnwrap(server.telemetryRow(runID: onDisk.id), "the usage line was uploaded")
        let sent = try XCTUnwrap(row.data["metrics"] as? [String: Any])
        let registry = try UsageQARig.registryUsageKeys()
        XCTAssertEqual(Set(sent.keys), Set(registry.keys), "every registered key of a full day reaches the server, and nothing else")
        var changed: [String] = []
        for (key, value) in onDisk.metrics {
            switch value {
            case .number(let n):
                if (sent[key] as? NSNumber)?.doubleValue != n { changed.append(key) }
            case .string(let s):
                if sent[key] as? String != s { changed.append(key) }
            default:
                changed.append("\(key): unexpected kind on disk")
            }
        }
        XCTAssertEqual(changed.sorted(), [], "values reach the server as written")
        XCTAssertGreaterThan(server.telemetryRowCount(), 0)
    }
}

// MARK: - The real detail view: writes that are not the user

@MainActor
final class UsageQADetailRealViewTests: XCTestCase {
    final class Model: ObservableObject {
        @Published var route: CalendarEventDetailRoute?
    }

    /// Presents the detail the way the three presenters do: a push from a
    /// route binding, the visit's leave when that binding goes nil.
    struct Host: View {
        @ObservedObject var model: Model
        let store: EventStore

        var body: some View {
            NavigationStack {
                Color.clear
                    .navigationDestination(item: $model.route) { route in
                        CalendarEventDetailView(route: route)
                            .environmentObject(store)
                    }
                    .onChange(of: model.route) { old, new in
                        if old != nil, new == nil { UsageProbe.leave(.eventDetail) }
                    }
            }
        }
    }

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var storage: EventStorageLocation!
    private var location: SpikeRunStorageLocation!
    private var center: ResidentObservationCenter?
    private var displacedSink: UsageSink?
    private var displacedRecorder: FollowerTimingRecorder?
    private var window: UIWindow?
    private var displacedWindow: UIWindow?
    private let day = Date(timeIntervalSince1970: 1_770_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "UsageQADetailRealViewTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        storage = TestStorage.reset(suiteName)
        location = .ephemeral(id: UUID())
        displacedSink = UsageProbe.sink
        displacedRecorder = FollowerTiming.recorder
        FollowerTiming.recorder = nil
    }

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        UsageQARig.pump(0.05)
        displacedWindow?.makeKeyAndVisible()
        center?.deactivate()
        center = nil
        UsageProbe.sink = displacedSink
        FollowerTiming.recorder = displacedRecorder
        try? FileManager.default.removeItem(at: location.directory)
        TestStorage.tearDown(suiteName)
        super.tearDown()
    }

    private func occurrence(_ id: UUID) -> CalendarEventOccurrenceContext {
        CalendarEventOccurrenceContext(eventID: id, occurrenceDate: day, occurrenceID: nil, isAllDay: false, source: .timelineTap)
    }

    private func show(_ host: Host) {
        let controller = UIHostingController(rootView: host)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        displacedWindow = scene?.windows.first(where: \.isKeyWindow)
        let made = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        made.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        made.rootViewController = controller
        made.makeKeyAndVisible()
        window = made
        UsageQARig.pump(0.6)
    }

    private func onScreen<T: UIView>(_ type: T.Type) -> [T] {
        guard let window else { return [] }
        var found: [T] = []
        func walk(_ view: UIView) {
            if let match = view as? T, !match.isHidden, match.window != nil,
               match.convert(match.bounds, to: window).intersects(window.bounds) {
                found.append(match)
            }
            view.subviews.forEach(walk)
        }
        walk(window)
        return found
    }

    /// Editable text views on the pager page the window shows, wherever they
    /// sit vertically: how much of the page fits above the fold depends on
    /// the device's top safe area and on how full the record is (a set
    /// completion and effort push the Note down). The pager's other page is
    /// off to the side and is excluded.
    private func editorsOnShownPage(text: String) -> [UITextView] {
        guard let window else { return [] }
        var found: [UITextView] = []
        func walk(_ view: UIView) {
            if let editor = view as? UITextView, editor.isEditable, !editor.isHidden, editor.window != nil {
                let frame = editor.convert(editor.bounds, to: window)
                if frame.maxX > window.bounds.minX, frame.minX < window.bounds.maxX, editor.text == text {
                    found.append(editor)
                }
            }
            view.subviews.forEach(walk)
        }
        walk(window)
        return found
    }

    /// The one Note editor showing `text`, scrolled into view the way a user
    /// reaches a Note below the fold (the page's own vertical scroll view,
    /// never the pager), then required fully on screen.
    private func noteEditor(showing text: String, _ what: String,
                            file: StaticString = #filePath, line: UInt = #line) throws -> UITextView {
        let window = try XCTUnwrap(window, file: file, line: line)
        let candidates = editorsOnShownPage(text: text)
        XCTAssertEqual(candidates.count, 1, "\(what): exactly one Note editor showing it on the shown page", file: file, line: line)
        let editor = try XCTUnwrap(candidates.first, what, file: file, line: line)
        var ancestor = editor.superview
        while let view = ancestor {
            if let scrollView = view as? UIScrollView, !scrollView.isPagingEnabled {
                scrollView.scrollRectToVisible(editor.convert(editor.bounds, to: scrollView), animated: false)
                break
            }
            ancestor = view.superview
        }
        window.layoutIfNeeded()
        UsageQARig.pump(0.1)
        XCTAssertTrue(window.bounds.contains(editor.convert(editor.bounds, to: window)),
                      "\(what): the Note editor is fully on screen once scrolled to (frame \(editor.convert(editor.bounds, to: window)), window \(window.bounds))",
                      file: file, line: line)
        return editor
    }

    private func makeCenter() -> ResidentObservationCenter {
        let made = ResidentObservationCenter(
            coordinator: SpikeSessionCoordinator(), store: nil, location: location,
            installsFollowerProbe: false, verifiesSeed: false, seedTrail: { _ in },
            countsLaunchSession: false, isAppForeground: { true }, availableGates: { [] }
        )
        made.activate()
        center = made
        return made
    }

    private func count(_ name: String) -> Int { center?.usage.counts.count(name) ?? -1 }

    /// The detail is open on an event's reflection page with its note loaded.
    /// Then the event and its record change underneath it the ways sync and
    /// the agent change them: a remote row adopted (title, type, length), a
    /// completion and an effort set through the store, the note rewritten
    /// through the store. None of that is the user acting in the detail, so
    /// no usage count may move — and leaving afterwards is still an
    /// abandonment. Positive controls: the detail re-rendered for the writes,
    /// and typing into its note in the same rig does count.
    func testSyncedAndAgentWritesWhileTheDetailIsOpenCountNothing() throws {
        let made = makeCenter()
        let store = EventStore(defaults: defaults, storage: storage, seedsSampleDataIfEmpty: false)
        let event = Event(title: "Deep Work", timeRanges: [.init(start: day, end: day.addingTimeInterval(3600))], type: "Study")
        store.addCalendarEvent(event)
        let occ = occurrence(event.id)
        store.upsertLogRecord(for: occ) { $0.note = "first draft" }
        var bodyPasses = 0
        store.onDetailBodyPass = { _ in bodyPasses += 1 }

        let model = Model()
        show(Host(model: model, store: store))
        UsageProbe.enter(.eventDetailCanvas)
        model.route = CalendarEventDetailRoute(occurrence: occ, initialJumpTarget: .log)
        UsageQARig.pump(1.2)

        _ = try noteEditor(showing: "first draft", "readiness: the reflection page's Note editor shows the loaded note")
        let opened = made.usage.counts.metrics
        let passesBefore = bodyPasses
        XCTAssertGreaterThan(passesBefore, 0, "readiness: the detail body ran")

        // Sync adopts a remote version of the event.
        var remote = try XCTUnwrap(store.findCalendarEvent(id: event.id))
        remote.title = "Deep Work (edited elsewhere)"
        remote.type = "Work"
        remote.timeRanges = [.init(start: day, end: day.addingTimeInterval(5400))]
        store.applyRemoteCalendarRows(adopts: [remote], deletions: [])
        UsageQARig.pump(0.4)
        // The agent / MCP writes through the store.
        store.applyQuickCompletion(.completed, for: occ)
        store.applyQuickEffort(4, for: occ)
        store.upsertLogRecord(for: occ) { $0.note = "rewritten by the agent" }
        UsageQARig.pump(0.8)

        XCTAssertGreaterThan(bodyPasses, passesBefore, "positive control: the detail re-rendered for the writes")
        XCTAssertEqual(store.findCalendarEvent(id: event.id)?.title, "Deep Work (edited elsewhere)", "fixture: the remote row landed")
        XCTAssertEqual(made.usage.counts.metrics, opened, "a write that is not the user's moves no usage count")

        model.route = nil
        UsageQARig.pump(1.0)
        XCTAssertEqual(count("usage.event_detail.abandon"), 1, "the user did nothing in it: still abandoned")

        // Positive control for the rig: the user's own edit does count.
        UsageProbe.enter(.eventDetailCanvas)
        model.route = CalendarEventDetailRoute(occurrence: occ, initialJumpTarget: .log)
        UsageQARig.pump(1.2)
        let editor = try noteEditor(showing: "rewritten by the agent", "the reopened detail loaded the agent's note")
        _ = editor.becomeFirstResponder()
        editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
        editor.insertText("!")
        UsageQARig.pump(0.3)
        XCTAssertEqual(count("usage.event_detail.use.reflect"), 1, "positive control: typing is a use")
        model.route = nil
        UsageQARig.pump(1.0)
        XCTAssertEqual(count("usage.event_detail.abandon"), 1, "the used visit is not abandoned")
    }

    /// A todo's deadline changed in the detail, and the user goes straight
    /// back. The change is the user's and it is saved (the coalesced write
    /// lands on the way out), so the visit was used, not abandoned.
    /// Positive control: the same scrub with a pause before going back.
    func testADeadlineChangedJustBeforeGoingBackMakesTheVisitUsed() throws {
        let made = makeCenter()
        let store = EventStore(defaults: defaults, storage: storage, seedsSampleDataIfEmpty: false)
        let todo = Event(title: "File taxes", timeRanges: [.init(start: day, end: day.addingTimeInterval(1800))],
                         deadline: day.addingTimeInterval(86_400), type: "Work", kind: .todo)
        store.addCalendarEvent(todo)
        let occ = occurrence(todo.id)
        let model = Model()
        show(Host(model: model, store: store))

        func visit(pauseBeforeBack: TimeInterval) throws -> Date? {
            UsageProbe.enter(.eventDetailList)
            model.route = CalendarEventDetailRoute(occurrence: occ)
            UsageQARig.pump(1.2)
            let picker = try XCTUnwrap(onScreen(UIDatePicker.self).first, "readiness: the todo's deadline picker is on screen")
            picker.date = picker.date.addingTimeInterval(3600)
            picker.sendActions(for: .valueChanged)
            if pauseBeforeBack > 0 { UsageQARig.pump(pauseBeforeBack) }
            model.route = nil
            UsageQARig.pump(1.5)
            return store.findCalendarEvent(id: todo.id)?.deadline
        }

        let original = try XCTUnwrap(store.findCalendarEvent(id: todo.id)?.deadline)
        let afterPause = try visit(pauseBeforeBack: 1.0)
        XCTAssertEqual(afterPause, original.addingTimeInterval(3600), "positive control: the scrub reached the store")
        XCTAssertEqual(count("usage.event_detail.use.todo"), 1)
        XCTAssertEqual(count("usage.event_detail.abandon"), 0, "positive control: a used visit with a pause is not abandoned")

        let afterQuick = try visit(pauseBeforeBack: 0)
        XCTAssertEqual(afterQuick, original.addingTimeInterval(7200), "fixture: the quick scrub was saved too")
        XCTAssertEqual(count("usage.event_detail.use.todo"), 2, "the user changed the deadline")
        XCTAssertEqual(count("usage.event_detail.abandon"), 0,
                       "a visit whose deadline change was saved on the way out was used, not abandoned")
    }
}

// MARK: - Where the probe may be called (§6.3 rule 5)

@MainActor
final class UsageQAProbePlacementTests: XCTestCase {
    private var doneRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Done")
    }

    /// Removes `//` and `/* */` comments and string literals (including
    /// triple-quoted ones), keeping line structure.
    static func codeOnly(_ source: String) -> String {
        let chars = Array(source)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if c == "/", next == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", next == "*" {
                var depth = 1
                i += 2
                while i < chars.count, depth > 0 {
                    if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" { depth += 1; i += 2; continue }
                    if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "/" { depth -= 1; i += 2; continue }
                    if chars[i] == "\n" { out.append("\n") }
                    i += 1
                }
                continue
            }
            if c == "\"" {
                let triple = i + 2 < chars.count && chars[i + 1] == "\"" && chars[i + 2] == "\""
                i += triple ? 3 : 1
                while i < chars.count {
                    if chars[i] == "\\" { i += 2; continue }
                    if triple {
                        if chars[i] == "\"", i + 2 < chars.count, chars[i + 1] == "\"", chars[i + 2] == "\"" { i += 3; break }
                    } else if chars[i] == "\"" || chars[i] == "\n" {
                        i += 1; break
                    }
                    if chars[i] == "\n" { out.append("\n") }
                    i += 1
                }
                out.append("\"\"")
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    static func probeCalls(in code: String) -> Int {
        code.components(separatedBy: "UsageProbe.").dropFirst().filter { part in
            let verb = part.prefix { $0.isLetter }
            return !verb.isEmpty && part.dropFirst(verb.count).first == "("
        }.count
    }

    /// `done` (and every other stage) is counted in the user's action, never
    /// in a store, a sync path, a service or the agent's tools — those run
    /// for remote and agent writes too. Only views and the app struct (whose
    /// focus hook and focus surface closures are the user's) may call it.
    func testTheProbeIsCalledOnlyFromViewsAndTheAppStruct() throws {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: doneRoot, includingPropertiesForKeys: nil))
        var inViews = 0
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: doneRoot.path + "/", with: "")
            let calls = Self.probeCalls(in: Self.codeOnly(try String(contentsOf: url, encoding: .utf8)))
            guard calls > 0 else { continue }
            if relative.hasPrefix("Views/") || relative == "DoneApp.swift" {
                inViews += calls
            } else {
                offenders.append("\(relative): \(calls)")
            }
        }
        XCTAssertGreaterThan(inViews, 30, "liveness: the scan found the views' probe calls")
        XCTAssertEqual(offenders, [], "probe calls outside the views")
    }

    func testTheScanSeesCodeAndIgnoresCommentsAndStrings() {
        let sample = """
        func a() { UsageProbe.done(.create) }
        // UsageProbe.done(.create)
        /* UsageProbe.use(.allDayToggle) /* nested */ UsageProbe.use(.allDayToggle) */
        let s = "UsageProbe.enter(.createPlus)"
        let t = \"""
        UsageProbe.enter(.createPlus)
        \"""
        let sink = UsageProbe.sink
        UsageProbe.leave(.create, via: .createCancel)
        """
        XCTAssertEqual(Self.probeCalls(in: Self.codeOnly(sample)), 2, "the two real calls; the property read is not a call")
    }
}

// MARK: - Round 2: held signals across midnight, the stray guard, owner change

@MainActor
final class UsageQARound2CenterTests: XCTestCase {
    private var location: SpikeRunStorageLocation!
    private var center: ResidentObservationCenter?
    private var displacedSink: UsageSink?
    private var displacedRecorder: FollowerTimingRecorder?

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
        displacedSink = UsageProbe.sink
        displacedRecorder = FollowerTiming.recorder
        FollowerTiming.recorder = nil
    }

    override func tearDown() {
        center?.deactivate()
        center = nil
        UsageProbe.sink = displacedSink
        FollowerTiming.recorder = displacedRecorder
        try? FileManager.default.removeItem(at: location.directory)
        super.tearDown()
    }

    /// Lets the center's own delayed rollover hop run on the real clock.
    private func waitOutTheForegroundHop() {
        UsageQARig.pump(2.6)
    }

    /// Back from the background after midnight; inside the hop's delay the
    /// user leaves the detail that was open, opens another and edits it. All
    /// of it is the new day's, in the order it happened: the first visit
    /// settles there, the second stays open and is used, not stray.
    func testSignalsHeldAcrossAMidnightReturnReplayInOrderOnTheNewDay() throws {
        let clock = QABox(UsageQARig.at(23, 50))
        let media = QABox(0.0)
        let made = UsageQARig.makeCenter(location: location, clock: clock, media: media, countsLaunchSession: true)
        center = made

        UsageProbe.enter(.eventDetailCanvas)
        clock.value = UsageQARig.at(23, 51); media.value = 60
        UsageQARig.post(UIApplication.willResignActiveNotification)
        UsageQARig.post(UIApplication.didEnterBackgroundNotification)

        clock.value = UsageQARig.at(0, 10, nextDay: true); media.value = 1260
        UsageQARig.post(UIApplication.willEnterForegroundNotification)
        UsageQARig.post(UIApplication.didBecomeActiveNotification)
        clock.value = UsageQARig.at(0, 10, 5, nextDay: true); media.value = 1265
        UsageProbe.leave(.eventDetail)
        media.value = 1266
        UsageProbe.enter(.eventDetailList)
        UsageProbe.use(.eventDetailPlan)
        waitOutTheForegroundHop()
        made.flushDaily()

        let records = UsageQARig.records(location)
        XCTAssertEqual(records.count, 2)
        guard records.count == 2 else { return }
        let (old, new) = (records[0], records[1])
        XCTAssertEqual(UsageQARig.number(old, "usage.event_detail.enter.canvas"), 1)
        XCTAssertNil(old.metrics["usage.event_detail.enter.list"], "nothing of 00:10 on the old day")
        XCTAssertNil(old.metrics["usage.event_detail.dwell"])
        XCTAssertEqual(UsageQARig.histogram(new, "usage.event_detail.dwell"), UsageQARig.oneVisit(in: UsageQARig.specBucket(65)),
                       "one settled visit: 60 s before the background, 5 s after the return")
        XCTAssertEqual(UsageQARig.number(new, "usage.event_detail.abandon"), 1)
        XCTAssertEqual(UsageQARig.number(new, "usage.event_detail.enter.list"), 1)
        XCTAssertEqual(UsageQARig.number(new, "usage.event_detail.use.plan"), 1, "the edit in the new visit is a use, not a stray")
        XCTAssertEqual(UsageQARig.number(new, "sessions"), 1)
        XCTAssertTrue(made.usage.isVisitOpen(.eventDetail), "the leave replayed before the enter, not after")
    }

    /// The app is brought back after midnight and goes back to the
    /// background before it ever becomes active; the user really returns in
    /// the morning. Background time is not dwell, and the morning return is
    /// a session of its own.
    func testAMidnightReturnThatNeverBecameActiveLeavesNoClockRunningInTheBackground() throws {
        let clock = QABox(UsageQARig.at(23, 50))
        let media = QABox(0.0)
        let made = UsageQARig.makeCenter(location: location, clock: clock, media: media, countsLaunchSession: true)
        center = made

        UsageProbe.enter(.eventDetailCanvas)
        clock.value = UsageQARig.at(23, 51); media.value = 60
        UsageQARig.post(UIApplication.willResignActiveNotification)
        UsageQARig.post(UIApplication.didEnterBackgroundNotification)

        clock.value = UsageQARig.at(0, 10, nextDay: true); media.value = 1260
        UsageQARig.post(UIApplication.willEnterForegroundNotification)
        media.value = 1261
        UsageQARig.post(UIApplication.didEnterBackgroundNotification)
        waitOutTheForegroundHop()

        clock.value = UsageQARig.at(8, 0, nextDay: true); media.value = 1261 + 28_140
        UsageQARig.post(UIApplication.willEnterForegroundNotification)
        UsageQARig.post(UIApplication.didBecomeActiveNotification)
        media.value += 5
        UsageProbe.leave(.eventDetail)
        made.flushDaily()

        let new = try XCTUnwrap(UsageQARig.records(location).last)
        XCTAssertEqual(UsageQARig.number(new, "sessions"), 2, "00:10 and 08:00 are two returns from the background")
        XCTAssertEqual(UsageQARig.histogram(new, "usage.event_detail.dwell"), UsageQARig.oneVisit(in: UsageQARig.specBucket(66)),
                       "60 s + 1 s + 5 s in the foreground; the night in the background is not dwell")
    }

    /// Uses of features that have no visits, and the repeat picked in an
    /// event form, are never late writes: a sibling visit having ended must
    /// not swallow them. A done is never a late write (round 3: it is the
    /// user's action on a form still on screen, which can outlive the visit
    /// it opened under). Positive control: a use after its own visit ended is
    /// dropped (the guard is live in this rig).
    func testTheStrayGuardKeepsUsesThatBelongToNoVisit() throws {
        let made = UsageQARig.makeCenter(location: location, clock: QABox(UsageQARig.at(10, 0)), media: QABox(0),
                                         countsLaunchSession: true)
        center = made

        UsageProbe.enter(.createPlus)
        UsageProbe.leave(.create, via: .createCancel)
        UsageProbe.enter(.repeatRuleEditor)
        UsageProbe.leave(.repeatRule)
        UsageProbe.enter(.eventDetailCanvas)
        UsageProbe.leave(.eventDetail)

        UsageProbe.use(.allDayToggle)
        UsageProbe.use(.repeatForm)
        UsageProbe.switchToggled(.focus, isOn: true)
        UsageProbe.done(.create)
        UsageProbe.use(.eventDetailPlan)

        XCTAssertEqual(made.usage.counts.count("usage.all_day.use"), 1, "the all-day switch belongs to no visit")
        XCTAssertEqual(made.usage.counts.count("usage.repeat.use.form"), 1, "a repeat picked in a form is not the rule editor's")
        XCTAssertEqual(made.usage.counts.count("usage.archived.use.focus_on"), 1)
        XCTAssertEqual(made.usage.counts.count("usage.create.done"), 1, "a done is the user's action on a form still on screen")
        XCTAssertEqual(made.usage.counts.count("usage.event_detail.use.plan"), 0, "positive control: a use after its visit ended is dropped")
    }

    /// The account changes while a detail is open; the change is noticed at
    /// the next flush (the background edge); the user comes back and leaves
    /// the detail. The visit was the first owner's: it settles nowhere —
    /// neither its abandonment nor its dwell lands in the second owner's
    /// record — and a fresh visit afterwards counts normally.
    func testAnOwnerChangeMidVisitSettlesTheOldVisitNowhere() throws {
        let owner = QABox<String?>(UsageQARig.uid)
        let clock = QABox(UsageQARig.at(10, 0))
        let media = QABox(0.0)
        let made = UsageQARig.makeCenter(location: location, clock: clock, media: media, countsLaunchSession: true, owner: owner)
        center = made

        UsageProbe.enter(.eventDetailCanvas)
        media.value = 30
        owner.value = "99999999-2222-4333-8444-555555555555"
        UsageQARig.post(UIApplication.willResignActiveNotification)
        UsageQARig.post(UIApplication.didEnterBackgroundNotification)
        clock.value = UsageQARig.at(10, 5); media.value = 330
        UsageQARig.post(UIApplication.willEnterForegroundNotification)
        UsageQARig.post(UIApplication.didBecomeActiveNotification)
        media.value = 340
        UsageProbe.leave(.eventDetail)

        UsageProbe.enter(.eventDetailSearch)
        media.value = 345
        UsageProbe.leave(.eventDetail)
        made.flushDaily()

        let byOwner = Dictionary(grouping: UsageQARig.records(location), by: { $0.ownerUID ?? "nil" })
        let first = try XCTUnwrap(byOwner[UsageQARig.uid]?.last)
        let second = try XCTUnwrap(byOwner["99999999-2222-4333-8444-555555555555"]?.last)
        XCTAssertEqual(UsageQARig.number(first, "usage.event_detail.enter.canvas"), 1, "the first owner's line has the enter")
        XCTAssertNil(first.metrics["usage.event_detail.abandon"])
        XCTAssertNil(second.metrics["usage.event_detail.enter.canvas"])
        XCTAssertEqual(UsageQARig.number(second, "usage.event_detail.enter.search"), 1)
        XCTAssertEqual(UsageQARig.number(second, "usage.event_detail.abandon"), 1, "only the fresh visit is the second owner's")
        XCTAssertEqual(UsageQARig.histogram(second, "usage.event_detail.dwell"), UsageQARig.oneVisit(in: UsageQARig.specBucket(5)))
    }
}

// MARK: - Round 2: an erase while an upload batch is reading the files

@MainActor
final class UsageQAEraseRaceTests: XCTestCase {
    private var location: SpikeRunStorageLocation!
    private var center: ResidentObservationCenter?
    private var displacedSink: UsageSink?
    private var displacedRecorder: FollowerTimingRecorder?

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
        displacedSink = UsageProbe.sink
        displacedRecorder = FollowerTiming.recorder
        FollowerTiming.recorder = nil
    }

    override func tearDown() {
        center?.deactivate()
        center = nil
        UsageProbe.sink = displacedSink
        FollowerTiming.recorder = displacedRecorder
        try? FileManager.default.removeItem(at: location.directory)
        super.tearDown()
    }

    /// A batch starts and is still reading the record files (one file is
    /// large, so the read takes a while off the main thread) when the erase
    /// begins. Nothing read before the erase may go up. Positive control: the
    /// same batch with no erase uploads.
    private func runBatch(erasingDuringTheRead: Bool) async throws -> (outcome: TelemetryUploadOutcome, rows: Int, seconds: Double) {
        let made = UsageQARig.makeCenter(location: location, clock: QABox(UsageQARig.at(10, 0)), media: QABox(0),
                                         countsLaunchSession: true)
        center = made
        UsageProbe.enter(.createPlus)
        UsageProbe.leave(.create, via: .createCancel)
        made.flushDaily()
        let usageURL = SpikeRunStore.fileURL(spikeID: UsageRecordIDs.spikeID, location: location)
        let template = try XCTUnwrap(try String(contentsOf: usageURL, encoding: .utf8)
            .split(separator: "\n").last.map(String.init), "fixture: a usage line on disk")
        let templateID = try XCTUnwrap(UsageQARig.records(location).last?.id).uuidString
        XCTAssertTrue(template.contains(templateID), "fixture: the line carries its id as written")
        var bulk = ""
        bulk.reserveCapacity(template.utf8.count * 40_001)
        for _ in 0..<40_000 {
            bulk += template.replacingOccurrences(of: templateID, with: UUID().uuidString)
            bulk += "\n"
        }
        try bulk.write(to: location.directory.appendingPathComponent("aaa-bulk.jsonl"), atomically: true, encoding: .utf8)

        let suite = "UsageQAEraseRace-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var deps = TelemetryUploader.Dependencies()
        deps.defaults = defaults
        deps.location = location
        let later = UsageQARig.at(11, 0)
        deps.now = { later }
        deps.launchDelay = 0
        deps.makeKeepAlive = { nil }
        deps.bootstrapOwner = { nil }
        let uploader = TelemetryUploader(dependencies: deps)
        let server = SyncFakeServer(userId: UsageQARig.uid)
        let user = UsageQARig.uid
        uploader.attach(TelemetryUploader.Attachment(gateway: server, isBlockedByBuild: { false },
                                                     currentUserID: { user }, isSignedIn: { true }))
        defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        TelemetryConsentStore.recordGrant(defaults, at: UsageQARig.at(9, 0))

        let started = Date()
        let batch = Task { await uploader.uploadNow(trigger: .deckOpen) }
        try await Task.sleep(nanoseconds: 300_000_000)
        if erasingDuringTheRead { LocalDataEraseEpoch.bump() }
        let outcome = await batch.value
        return (outcome, server.telemetryRowCount(), Date().timeIntervalSince(started))
    }

    func testAnEraseDuringTheBatchesFileReadUploadsNothingFromBeforeIt() async throws {
        try await LocalDataEraseEpoch.withIsolatedEpoch {
            let result = try await runBatch(erasingDuringTheRead: true)
            XCTAssertGreaterThan(result.seconds, 0.6, "readiness: the read outlasted the moment of the erase")
            XCTAssertEqual(result.rows, 0, "nothing read before the erase reached the server (outcome \(result.outcome))")
        }
    }

    func testPositiveControlTheSameBatchWithoutAnEraseUploads() async throws {
        try await LocalDataEraseEpoch.withIsolatedEpoch {
            let result = try await runBatch(erasingDuringTheRead: false)
            XCTAssertGreaterThan(result.rows, 0, "the rig's batch does upload (outcome \(result.outcome))")
        }
    }
}

// MARK: - Round 3: rollover in the notification, the background edge, owner + consent, the gate after the read

@MainActor
final class UsageQARound3Tests: XCTestCase {
    private var location: SpikeRunStorageLocation!
    private var centers: [ResidentObservationCenter] = []
    private var displacedSink: UsageSink?
    private var displacedRecorder: FollowerTimingRecorder?

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
        displacedSink = UsageProbe.sink
        displacedRecorder = FollowerTiming.recorder
        FollowerTiming.recorder = nil
    }

    override func tearDown() {
        for center in centers { center.deactivate() }
        centers = []
        UsageProbe.sink = displacedSink
        FollowerTiming.recorder = displacedRecorder
        try? FileManager.default.removeItem(at: location.directory)
        super.tearDown()
    }

    private func center(clock: QABox<Date>, media: QABox<Double>, owner: QABox<String?>? = nil,
                        countsLaunchSession: Bool = true) -> ResidentObservationCenter {
        let made = UsageQARig.makeCenter(location: location, clock: clock, media: media,
                                         countsLaunchSession: countsLaunchSession, owner: owner)
        centers.append(made)
        return made
    }

    /// Back after midnight, Control Center comes down before the app ever
    /// became active, then it becomes active and the user leaves the detail.
    /// One return, on the new day; Control Center time is foreground time.
    func testAMidnightReturnThatResignsBeforeBecomingActiveIsOneSessionOnTheNewDay() throws {
        let clock = QABox(UsageQARig.at(23, 50))
        let media = QABox(0.0)
        let made = center(clock: clock, media: media)
        UsageProbe.enter(.eventDetailCanvas)
        clock.value = UsageQARig.at(23, 51); media.value = 60
        UsageQARig.post(UIApplication.willResignActiveNotification)
        UsageQARig.post(UIApplication.didEnterBackgroundNotification)

        clock.value = UsageQARig.at(0, 10, nextDay: true); media.value = 1260
        UsageQARig.post(UIApplication.willEnterForegroundNotification)
        media.value = 1262
        UsageQARig.post(UIApplication.willResignActiveNotification)
        media.value = 1264
        UsageQARig.post(UIApplication.didBecomeActiveNotification)
        media.value = 1270
        UsageProbe.leave(.eventDetail)
        made.flushDaily()

        let records = UsageQARig.records(location)
        XCTAssertEqual(records.count, 2)
        guard records.count == 2 else { return }
        let (old, new) = (records[0], records[1])
        XCTAssertEqual(UsageQARig.number(old, "sessions"), 1)
        XCTAssertNil(old.metrics["usage.event_detail.dwell"])
        XCTAssertEqual(UsageQARig.number(new, "sessions"), 1, "one return, counted once, on the new day")
        XCTAssertEqual(UsageQARig.histogram(new, "usage.event_detail.dwell"), UsageQARig.oneVisit(in: UsageQARig.specBucket(70)),
                       "60 s before, 10 s after the return; Control Center is foreground time")
        XCTAssertEqual(UsageQARig.number(new, "usage.event_detail.abandon"), 1)
    }

    /// The foreground session runs across midnight. Control Center at
    /// 23:59:59 flushes (the resign edge); at 00:00:01 the detail is left
    /// (held for the hop) and the app goes straight to the background, in
    /// the same turn, before the hop runs. The new day still gets the
    /// session that crossed midnight and the visit's settle.
    func testTheBackgroundEdgeAfterAResignFlushRollsOverBeforeTheClockStops() throws {
        let clock = QABox(UsageQARig.at(23, 59, 0))
        let media = QABox(0.0)
        let made = center(clock: clock, media: media)
        UsageProbe.enter(.eventDetailCanvas)
        clock.value = UsageQARig.at(23, 59, 59); media.value = 59
        UsageQARig.post(UIApplication.willResignActiveNotification)
        clock.value = UsageQARig.at(0, 0, 1, nextDay: true); media.value = 61
        UsageProbe.leave(.eventDetail)
        UsageQARig.post(UIApplication.didEnterBackgroundNotification)
        UsageQARig.pump(0.2)
        made.flushDaily()

        let records = UsageQARig.records(location)
        XCTAssertEqual(records.count, 2)
        guard records.count == 2 else { return }
        let new = records[1]
        XCTAssertEqual(UsageQARig.number(new, "sessions"), 1, "the session that crossed midnight is the new day's denominator")
        XCTAssertEqual(UsageQARig.number(new, "usage.event_detail.abandon"), 1)
        XCTAssertEqual(UsageQARig.histogram(new, "usage.event_detail.dwell"), UsageQARig.oneVisit(in: UsageQARig.specBucket(61)))
    }

    /// Both daily files compact at the background edge and not at a resign
    /// (Control Center keeps the app on screen). Nothing counted is lost by
    /// the rewrite: a relaunch adopts exactly today's counts.
    func testTheUsageFileCompactsAtTheBackgroundEdgeOnlyAndKeepsTodaysCounts() throws {
        for i in 0..<520 {
            let start = UsageQARig.at(10, 0).addingTimeInterval(-Double(30 + i) * 86_400)
            var old = TelemetryFixtures.run(spikeID: UsageRecordIDs.spikeID, scenarioID: UsageRecordIDs.scenarioID,
                                            startedAt: start, endedAt: start.addingTimeInterval(60), appBuild: "29",
                                            metrics: ["sessions": .number(3), "usage.all_day.use": .number(1),
                                                      "usage.create.dwell": .string("1 2 3 4")])
            old.dayKey = "old-\(i)"
            XCTAssertTrue(SpikeRunStore.finishRun(old, owner: .explicit(UsageQARig.uid), location: location, compactsWhenFull: false))
        }
        let url = SpikeRunStore.fileURL(spikeID: UsageRecordIDs.spikeID, location: location)
        func size() -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0 }
        XCTAssertGreaterThanOrEqual(size(), SpikeRunStore.compactAtBytes, "fixture: the file is past the compaction size")

        let clock = QABox(UsageQARig.at(10, 0))
        let media = QABox(0.0)
        let made = center(clock: clock, media: media)
        UsageProbe.enter(.createPlus)
        media.value = 12
        UsageProbe.leave(.create, via: .createDismiss)
        UsageProbe.use(.allDayToggle)
        UsageQARig.post(UIApplication.willResignActiveNotification)
        XCTAssertGreaterThanOrEqual(size(), SpikeRunStore.compactAtBytes, "a resign (Control Center) does not rewrite the file")
        let written = made.usage.counts.metrics
        UsageQARig.post(UIApplication.didEnterBackgroundNotification)
        XCTAssertLessThan(size(), SpikeRunStore.compactAtBytes, "the background edge compacts it")

        made.deactivate()
        let relaunched = center(clock: QABox(UsageQARig.at(10, 30)), media: QABox(0), countsLaunchSession: false)
        XCTAssertEqual(relaunched.usage.counts.metrics, written, "the relaunch adopts today's line as written before the rewrite")
    }

    /// A visit is open, the account changes, and before any flush notices
    /// it the user turns sharing on (the consent re-mint). The visit was the
    /// first owner's: it settles in neither owner's record.
    func testAnOwnerChangeThenConsentWithAVisitOpenSettlesItNowhere() throws {
        let owner = QABox<String?>(UsageQARig.uid)
        let clock = QABox(UsageQARig.at(10, 0))
        let media = QABox(0.0)
        let made = center(clock: clock, media: media, owner: owner)
        UsageProbe.enter(.eventDetailCanvas)
        media.value = 30
        owner.value = "99999999-2222-4333-8444-555555555555"
        clock.value = UsageQARig.at(10, 1)
        made.remintDailyForConsent()
        media.value = 40
        UsageProbe.leave(.eventDetail)
        made.flushDaily()

        let records = UsageQARig.records(location)
        let first = records.filter { $0.ownerUID == UsageQARig.uid }
        let second = records.filter { $0.ownerUID == "99999999-2222-4333-8444-555555555555" }
        XCTAssertEqual(first.compactMap { UsageQARig.number($0, "usage.event_detail.enter.canvas") }.reduce(0, +), 1,
                       "the enter is the first owner's")
        XCTAssertFalse(second.isEmpty, "fixture: the second owner has a line")
        for record in first + second {
            XCTAssertNil(record.metrics["usage.event_detail.abandon"], "the old visit settles nowhere (\(record.ownerUID ?? "nil"))")
            XCTAssertNil(record.metrics["usage.event_detail.dwell"])
        }
        XCTAssertFalse(made.usage.isVisitOpen(.eventDetail))
    }

    /// The upload switch is turned off while a batch is reading the files:
    /// zero requests. Positive control: the same batch with the switch left on.
    private func batch(turningTheSwitchOffDuringTheRead: Bool) async throws -> (outcome: TelemetryUploadOutcome, rows: Int) {
        let made = center(clock: QABox(UsageQARig.at(10, 0)), media: QABox(0))
        UsageProbe.enter(.createPlus)
        UsageProbe.leave(.create, via: .createCancel)
        made.flushDaily()

        let suite = "UsageQASwitchRace-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var deps = TelemetryUploader.Dependencies()
        deps.defaults = defaults
        deps.location = location
        let later = UsageQARig.at(11, 0)
        deps.now = { later }
        deps.launchDelay = 0
        deps.makeKeepAlive = { nil }
        deps.bootstrapOwner = { nil }
        let flip = turningTheSwitchOffDuringTheRead
        let reads = QABox(0)
        deps.readRecords = { urls, retention in
            await MainActor.run {
                reads.value += 1
                if flip { defaults.set(false, forKey: AppSettingsKeys.telemetryUploadsEnabled) }
            }
            return urls.flatMap { SpikeRunStore.readRuns(at: $0, retention: retention) }
        }
        let uploader = TelemetryUploader(dependencies: deps)
        let server = SyncFakeServer(userId: UsageQARig.uid)
        let user = UsageQARig.uid
        uploader.attach(TelemetryUploader.Attachment(gateway: server, isBlockedByBuild: { false },
                                                     currentUserID: { user }, isSignedIn: { true }))
        defaults.set(true, forKey: AppSettingsKeys.telemetryUploadsEnabled)
        TelemetryConsentStore.recordGrant(defaults, at: UsageQARig.at(9, 0))
        let outcome = await uploader.uploadNow(trigger: .deckOpen)
        XCTAssertGreaterThanOrEqual(reads.value, 1, "readiness: the batch read the files through the seam")
        return (outcome, server.telemetryRowCount())
    }

    func testTheSwitchTurnedOffDuringTheBatchReadSendsNothing() async throws {
        let result = try await batch(turningTheSwitchOffDuringTheRead: true)
        XCTAssertEqual(result.rows, 0, "switched off mid-read: zero requests (outcome \(result.outcome))")
    }

    func testPositiveControlTheSwitchLeftOnSends() async throws {
        let result = try await batch(turningTheSwitchOffDuringTheRead: false)
        XCTAssertGreaterThan(result.rows, 0, "outcome \(result.outcome)")
    }
}
