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
        countsLaunchSession: Bool, gates: QABox<Set<UsageGate>> = QABox([])
    ) -> ResidentObservationCenter {
        let center = ResidentObservationCenter(
            coordinator: SpikeSessionCoordinator(), store: nil, location: location, calendar: la,
            now: { clock.value }, mediaNow: { media.value },
            makeFrameProbe: { SpikeFrameProbe() },
            ownerUID: { uid }, stamp: { stamp() },
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
                                    "usage.wanna.available", "usage.report.available"]

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

    private func feature(of route: UsageRoute) -> (UsageFeature, UsageEntry) {
        switch route {
        case .focusSwipe, .focusRotate, .focusSystem: return (.focus, .focusTap)
        case .createCancel, .createSwipe: return (.create, .createPlus)
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
        for use in UsageUse.allCases where !toggles.contains(use) { UsageProbe.use(use) }
        for gate in UsageGate.allCases {
            UsageProbe.switchToggled(gate, isOn: false)
            UsageProbe.switchToggled(gate, isOn: true)
        }
        for done in UsageDone.allCases { UsageProbe.done(done) }
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

        let editors = onScreen(UITextView.self).filter { $0.isEditable && $0.text == "first draft" }
        XCTAssertEqual(editors.count, 1, "readiness: the reflection page's Note editor shows the loaded note")
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
        let editor = try XCTUnwrap(onScreen(UITextView.self).first { $0.isEditable && $0.text == "rewritten by the agent" },
                                   "the reopened detail loaded the agent's note")
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
