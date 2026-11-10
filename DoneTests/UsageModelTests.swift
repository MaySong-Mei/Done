//
//  UsageModelTests.swift
//  DoneTests
//
//  gh#273 §6.3 — the pure half of usage counting: the key layout derived
//  from `UsageFeature`, the record's metrics (zeros omitted, unknown keys
//  dropped on seed), visit settlement in `UsageTracker` (design §11 item
//  16, model level), the registry JSON against the Swift declarations
//  (both directions, every column), and the source scan of design §11 item
//  18 (every declared entry has an enter site and a leave site in `Done/`,
//  and no enter sits inside an `onAppear` closure).
//

import XCTest
@testable import Done

@MainActor
final class UsageModelTests: XCTestCase {

    private func count(_ tracker: UsageTracker, _ name: String, file: StaticString = #filePath, line: UInt = #line) -> Int {
        guard let value = tracker.counts.count(name) else {
            XCTFail("\(name) is not a registered counter", file: file, line: line)
            return -1
        }
        return value
    }

    private func dwell(_ tracker: UsageTracker, _ feature: UsageFeature) -> [Int] {
        tracker.counts.dwellBuckets(feature) ?? []
    }

    // MARK: Layout

    func testEveryTagIsDeclaredByExactlyOneFeatureAndEveryNameIsUnique() {
        XCTAssertEqual(UsageLayout.shared.undeclaredTags, [])
        let names = UsageKey.all.map(\.name)
        XCTAssertEqual(names.count, Set(names).count, "duplicate key names")
        XCTAssertEqual(UsageKey.all.first?.name, UsageKey.sessionsName)
        XCTAssertEqual(UsageKey.all.first?.slot, UsageLayout.sessionsSlot)
        // Every key but the denominator is `usage.<feature>.<stage>[.<sub>]`
        // with a stage from the design's vocabulary.
        let stages: Set<String> = ["enter", "use", "done", "view", "exit", "abandon", "dwell", "available"]
        for key in UsageKey.all.dropFirst() {
            let parts = key.name.split(separator: ".").map(String.init)
            XCTAssertEqual(parts.first, "usage", key.name)
            XCTAssertTrue((3...4).contains(parts.count), key.name)
            let isTally = key.feature.map { f in f.declaration.events.contains { key.name == "usage.\(f.declaration.name).\($0.suffix)" } } ?? false
            XCTAssertTrue(stages.contains(parts[2]) || isTally, "\(key.name): stage \(parts[2])")
            XCTAssertTrue(key.name.allSatisfy { $0.isLowercase || $0 == "." || $0 == "_" }, key.name)
        }
        // Slots tile the storage with no overlap.
        var next = 0
        for key in UsageKey.all {
            XCTAssertEqual(key.slot, next, key.name)
            next += key.slotCount
        }
        XCTAssertEqual(next, UsageLayout.shared.slotCount)
    }

    func testTheDeclaredStagesProduceTheDesignsKeyNames() {
        let names = Set(UsageKey.all.map(\.name))
        for expected in [
            "sessions",
            "usage.focus.enter.tap", "usage.focus.enter.auto", "usage.focus.use.extend", "usage.focus.use.end_now",
            "usage.focus.use.note", "usage.focus.use.track", "usage.focus.abandon", "usage.focus.dwell",
            "usage.focus.exit.swipe", "usage.focus.exit.rotate", "usage.focus.exit.system",
            "usage.focus_precreate.enter.pill", "usage.focus_precreate.done", "usage.focus_precreate.abandon",
            "usage.event_detail.enter.canvas", "usage.event_detail.enter.menu", "usage.event_detail.enter.list",
            "usage.event_detail.enter.search", "usage.event_detail.use.plan", "usage.event_detail.use.reflect",
            "usage.event_detail.use.timeline_note", "usage.event_detail.use.todo", "usage.event_detail.use.delete",
            "usage.event_detail.view.reflection", "usage.event_detail.abandon", "usage.event_detail.dwell",
            "usage.create.enter.drag", "usage.create.enter.plus", "usage.create.enter.resume_draft",
            "usage.create.enter.reminder_ai", "usage.create.done", "usage.create.done.repeat",
            "usage.create.done.all_day", "usage.create.done.note", "usage.create.abandon.cancel",
            "usage.create.abandon.swipe", "usage.create.abandon.banner", "usage.create.ai_fallback", "usage.create.dwell",
            "usage.repeat.enter.rule_editor", "usage.repeat.use.form", "usage.repeat.done", "usage.repeat.abandon",
            "usage.all_day.use",
            "usage.focus.available", "usage.todo_stack.available", "usage.wanna.available", "usage.report.available",
            "usage.archived.use.focus_on", "usage.archived.use.focus_off", "usage.archived.use.todo_stack_on",
            "usage.archived.use.todo_stack_off", "usage.archived.use.wanna_on", "usage.archived.use.wanna_off",
            "usage.archived.use.report_on", "usage.archived.use.report_off",
        ] {
            XCTAssertTrue(names.contains(expected), "missing \(expected)")
        }
        // focus_precreate shares focus's switch: no second available key.
        XCTAssertFalse(names.contains("usage.focus_precreate.available"))
        // create's abandonment is routed: there is no bare key to double count.
        XCTAssertFalse(names.contains("usage.create.abandon"))
        // all_day has no entry, so no visit keys.
        XCTAssertFalse(names.contains("usage.all_day.abandon"))
        XCTAssertFalse(names.contains("usage.all_day.dwell"))
        // Every entry is marked; only focus's rotation is not the user's.
        let auto = UsageFeature.allCases.flatMap { f in f.declaration.entries.filter { $0.source == .auto }.map(\.tag) }
        XCTAssertEqual(auto, [.focusAuto])
    }

    // MARK: Liveness (design §6.3: a switch-gated feature reads against its available)

    func testSwitchGatedKeysReadAgainstTheirAvailableEverythingElseAgainstSessions() {
        var violations: [String] = []
        for key in UsageKey.all {
            let expected: String?
            if key.name == UsageKey.sessionsName {
                expected = nil
            } else if key.name.hasSuffix(".available") {
                expected = UsageKey.sessionsName
            } else if key.name.hasPrefix("usage.focus.") || key.name.hasPrefix("usage.focus_precreate.") {
                expected = "usage.focus.available"
            } else {
                expected = UsageKey.sessionsName
            }
            if key.livenessKey != expected { violations.append("\(key.name): \(key.livenessKey ?? "nil"), want \(expected ?? "nil")") }
        }
        XCTAssertEqual(violations, [])
        XCTAssertEqual(UsageKey.all.filter { $0.livenessKey == "usage.focus.available" }.count, 15,
                       "liveness: focus's eleven keys and focus_precreate's four")
    }

    // MARK: Availability

    func testAvailableCountsOncePerCountedSessionWhenTheSwitchIsOnAtItsStart() {
        var tracker = UsageTracker()
        tracker.enterForeground(at: 0, available: [.focus, .wanna])
        XCTAssertFalse(tracker.enterForeground(at: 1, available: [.focus, .wanna]), "Control Center / Face ID")
        tracker.switchToggled(.focus, isOn: false)
        tracker.switchToggled(.focus, isOn: true)
        XCTAssertEqual(count(tracker, "usage.focus.available"), 1, "once per session, however often it is flipped")
        XCTAssertEqual(count(tracker, "usage.wanna.available"), 1)
        XCTAssertEqual(count(tracker, "usage.report.available"), 0, "off at the start, never turned on")
        tracker.enterBackground(at: 2)
        tracker.enterForeground(at: 3, available: [.focus])
        XCTAssertEqual(count(tracker, "usage.focus.available"), 2, "the next session counts again")
        XCTAssertEqual(count(tracker, "usage.wanna.available"), 1, "switched off since: not available this session")
        XCTAssertLessThanOrEqual(count(tracker, "usage.focus.available"), count(tracker, "sessions"))
    }

    func testTurningASwitchOnMidSessionMakesTheFeatureAvailableForThatSession() {
        var tracker = UsageTracker()
        tracker.enterForeground(at: 0, available: [])
        XCTAssertEqual(count(tracker, "usage.todo_stack.available"), 0)
        tracker.switchToggled(.todoStack, isOn: true)
        XCTAssertEqual(count(tracker, "usage.todo_stack.available"), 1)
        XCTAssertEqual(count(tracker, "usage.archived.use.todo_stack_on"), 1)
        tracker.switchToggled(.todoStack, isOn: false)
        XCTAssertEqual(count(tracker, "usage.archived.use.todo_stack_off"), 1, "off is its own key")
        XCTAssertEqual(count(tracker, "usage.todo_stack.available"), 1, "turning it off does not take the session back")
        tracker.switchToggled(.todoStack, isOn: true)
        XCTAssertEqual(count(tracker, "usage.archived.use.todo_stack_on"), 2, "every flip is counted")
        XCTAssertEqual(count(tracker, "usage.todo_stack.available"), 1, "but available once per session")
    }

    func testAvailableNeedsACountedSessionAndCarriesIntoANewRecordWithIt() {
        var host = UsageTracker()
        host.assumeForeground()
        host.switchToggled(.report, isOn: true)
        XCTAssertEqual(count(host, "usage.report.available"), 0, "a foreground this process never counted has no available")
        XCTAssertEqual(count(host, "usage.archived.use.report_on"), 1, "the flip itself still happened")

        var tracker = UsageTracker()
        tracker.enterForeground(at: 0, available: [.focus])
        tracker.resetCountsForNewRecord(available: [.focus])
        XCTAssertEqual(tracker.counts.metrics, ["sessions": .number(1), "usage.focus.available": .number(1)],
                       "midnight: the running session and the switch on now are the new day's denominators")
        tracker.switchToggled(.focus, isOn: true)
        XCTAssertEqual(count(tracker, "usage.focus.available"), 1, "already counted in this record")
        tracker.resetCountsForNewRecord(available: [])
        XCTAssertEqual(count(tracker, "usage.focus.available"), 0, "switched off by the next record: not carried")
    }

    // MARK: Dwell buckets

    func testDwellBucketsAreThreeThirtyThreeHundredWithExclusiveUpperBounds() {
        XCTAssertEqual(UsageDwell.bucket(forSeconds: 0), 0)
        XCTAssertEqual(UsageDwell.bucket(forSeconds: 2.999), 0)
        XCTAssertEqual(UsageDwell.bucket(forSeconds: 3), 1)
        XCTAssertEqual(UsageDwell.bucket(forSeconds: 29.999), 1)
        XCTAssertEqual(UsageDwell.bucket(forSeconds: 30), 2)
        XCTAssertEqual(UsageDwell.bucket(forSeconds: 299.999), 2)
        XCTAssertEqual(UsageDwell.bucket(forSeconds: 300), 3)
        XCTAssertEqual(UsageDwell.bucket(forSeconds: 86_400), 3)
    }

    // MARK: Record metrics (design §11 item 8 style)

    func testZerosAreNotWrittenAndTheHistogramIsFourFixedBuckets() {
        var tracker = UsageTracker()
        XCTAssertEqual(tracker.counts.metrics, [:], "an untouched day writes no key at all")
        tracker.enterForeground(at: 0)
        tracker.enter(.focusTap, at: 0)
        tracker.leave(.focus, via: .focusSwipe, at: 10)
        XCTAssertEqual(tracker.counts.metrics, [
            "sessions": .number(1),
            "usage.focus.enter.tap": .number(1),
            "usage.focus.abandon": .number(1),
            "usage.focus.exit.swipe": .number(1),
            "usage.focus.dwell": .string("0 1 0 0"),
        ])
    }

    func testASeedDropsAndCountsUnknownKeysAndWrongShapesAndKeepsTheRest() {
        var drops = 0
        let seeded = UsageCounts(metrics: [
            "sessions": .number(4),
            "usage.focus.enter.tap": .number(2),
            "usage.focus.dwell": .string("1 0 2 0"),
            "usage.bogus.enter.tap": .number(9),
            "usage.focus.use.extend": .string("3"),
            "usage.event_detail.dwell": .string("1 2"),
            "usage.create.done": .number(1.5),
        ], unknownKeyDrops: &drops)
        XCTAssertEqual(drops, 4, "the unknown key and the three wrong shapes")
        XCTAssertEqual(seeded.metrics, [
            "sessions": .number(4),
            "usage.focus.enter.tap": .number(2),
            "usage.focus.dwell": .string("1 0 2 0"),
        ])
        // Positive control: a clean seed drops nothing.
        var clean = 0
        _ = UsageCounts(metrics: seeded.metrics, unknownKeyDrops: &clean)
        XCTAssertEqual(clean, 0)
    }

    // MARK: Visit settlement (design §11 item 16, model level)

    func testBackgroundPausesTheDwellClockAndAReturnIsNotANewEnter() {
        var tracker = UsageTracker()
        tracker.enterForeground(at: 0)
        tracker.enter(.eventDetailCanvas, at: 0)
        tracker.enterBackground(at: 1)          // 1 s in the foreground
        tracker.enterForeground(at: 601)        // 10 minutes away
        tracker.leave(.eventDetail, via: nil, at: 606) // 5 s after coming back
        XCTAssertEqual(dwell(tracker, .eventDetail), [0, 1, 0, 0], "6 s of foreground: the 3–30 s bucket, not ≥300 s")
        XCTAssertEqual(count(tracker, "usage.event_detail.abandon"), 1, "entered and left with no use")
        XCTAssertEqual(count(tracker, "usage.event_detail.enter.canvas"), 1, "coming back is not an enter")
        XCTAssertEqual(count(tracker, "sessions"), 2, "the launch and the return")
    }

    func testAUseOrADoneMeansTheVisitWasNotAbandoned() {
        var tracker = UsageTracker()
        tracker.enterForeground(at: 0)
        tracker.enter(.eventDetailSearch, at: 0)
        tracker.use(.eventDetailReflect)
        tracker.leave(.eventDetail, via: nil, at: 40)
        XCTAssertEqual(count(tracker, "usage.event_detail.abandon"), 0)
        XCTAssertEqual(dwell(tracker, .eventDetail), [0, 0, 1, 0])

        tracker.enter(.createPlus, at: 50)
        tracker.done(.create)
        tracker.leave(.create, via: .createCancel, at: 52)
        XCTAssertEqual(count(tracker, "usage.create.abandon.cancel"), 0, "Done ends explicitly too: not an abandonment")

        // Positive control: the same visits with nothing done abandon.
        tracker.enter(.eventDetailSearch, at: 60)
        tracker.leave(.eventDetail, via: nil, at: 61)
        tracker.enter(.createPlus, at: 70)
        tracker.leave(.create, via: .createCancel, at: 71)
        XCTAssertEqual(count(tracker, "usage.event_detail.abandon"), 1)
        XCTAssertEqual(count(tracker, "usage.create.abandon.cancel"), 1)
    }

    func testAViewIsNotAUse() {
        var tracker = UsageTracker()
        tracker.enterForeground(at: 0)
        tracker.enter(.eventDetailMenu, at: 0)
        tracker.view(.eventDetailReflection)
        tracker.leave(.eventDetail, via: nil, at: 2)
        XCTAssertEqual(count(tracker, "usage.event_detail.view.reflection"), 1)
        XCTAssertEqual(count(tracker, "usage.event_detail.abandon"), 1, "looking at the reflection page is not using the detail")
    }

    func testExitRoutesCountOnEveryVisitAbandonRoutesOnlyOnAbandonment() {
        var tracker = UsageTracker()
        tracker.enterForeground(at: 0)
        tracker.enter(.focusAuto, at: 0)
        tracker.use(.focusExtend)
        tracker.leave(.focus, via: .focusRotate, at: 5)
        XCTAssertEqual(count(tracker, "usage.focus.exit.rotate"), 1, "a used visit still says how it ended")
        XCTAssertEqual(count(tracker, "usage.focus.abandon"), 0)

        tracker.enter(.createDrag, at: 10)
        tracker.done(.create)
        tracker.leave(.create, via: .createSwipe, at: 11)
        XCTAssertEqual(count(tracker, "usage.create.abandon.swipe"), 0, "a done visit is not routed into abandonment")
        tracker.enter(.createDrag, at: 20)
        tracker.leave(.create, via: .createSwipe, at: 21)
        XCTAssertEqual(count(tracker, "usage.create.abandon.swipe"), 1)
    }

    func testANotedExitWinsAndAnotherFeaturesRouteIsIgnored() {
        var tracker = UsageTracker()
        tracker.enterForeground(at: 0)
        tracker.enter(.focusTap, at: 0)
        tracker.noteExit(.focusSwipe)
        tracker.leave(.focus, via: .focusRotate, at: 1)
        XCTAssertEqual(count(tracker, "usage.focus.exit.swipe"), 1)
        XCTAssertEqual(count(tracker, "usage.focus.exit.rotate"), 0)

        tracker.enter(.focusTap, at: 2)
        tracker.leave(.focus, via: .createCancel, at: 3)
        XCTAssertEqual(count(tracker, "usage.focus.abandon"), 2, "settled all the same")
        XCTAssertEqual(count(tracker, "usage.create.abandon.cancel"), 0, "never another feature's key")

        // A note with no visit open is dropped, so it cannot leak into the
        // next visit's exit.
        tracker.noteExit(.focusSwipe)
        tracker.enter(.focusAuto, at: 4)
        tracker.leave(.focus, via: .focusRotate, at: 5)
        XCTAssertEqual(count(tracker, "usage.focus.exit.swipe"), 1)
        XCTAssertEqual(count(tracker, "usage.focus.exit.rotate"), 1)
    }

    func testLeaveWithNoOpenVisitCountsNothingAndAReEnterDropsTheStaleVisitUnsettled() {
        var tracker = UsageTracker()
        tracker.enterForeground(at: 0)
        tracker.leave(.eventDetail, via: nil, at: 1)
        XCTAssertEqual(tracker.counts.metrics, ["sessions": .number(1)])

        tracker.enter(.eventDetailCanvas, at: 2)
        tracker.enter(.eventDetailList, at: 3)
        XCTAssertEqual(dwell(tracker, .eventDetail), [0, 0, 0, 0], "the first visit's leave was never seen: not settled")
        XCTAssertEqual(count(tracker, "usage.event_detail.abandon"), 0)
        tracker.leave(.eventDetail, via: nil, at: 4)
        XCTAssertEqual(dwell(tracker, .eventDetail), [1, 0, 0, 0])
        XCTAssertEqual(count(tracker, "usage.event_detail.abandon"), 1)
    }

    func testAReturnIsOneSessionAndAnActivationWithoutBackgroundIsNone() {
        var tracker = UsageTracker()
        XCTAssertTrue(tracker.enterForeground(at: 0), "the launch")
        XCTAssertFalse(tracker.enterForeground(at: 1), "didBecomeActive after Control Center / Face ID: no background before it")
        tracker.enterBackground(at: 2)
        XCTAssertTrue(tracker.enterForeground(at: 3), "willEnterForeground")
        XCTAssertFalse(tracker.enterForeground(at: 3), "its didBecomeActive")
        XCTAssertEqual(count(tracker, "sessions"), 2)
    }

    func testANewRecordCarriesTheRunningSessionAndKeepsOpenVisits() {
        var tracker = UsageTracker()
        tracker.enterForeground(at: 0)
        tracker.enter(.focusTap, at: 0)
        tracker.resetCountsForNewRecord()
        XCTAssertEqual(tracker.counts.metrics, ["sessions": .number(1)], "the day after midnight still has its denominator")
        tracker.leave(.focus, via: .focusSwipe, at: 50)
        XCTAssertEqual(dwell(tracker, .focus), [0, 0, 1, 0], "the visit settles on the day it leaves")
        XCTAssertEqual(count(tracker, "usage.focus.enter.tap"), 0, "its enter stayed on the day it entered")

        tracker.enterBackground(at: 60)
        tracker.resetCountsForNewRecord()
        XCTAssertEqual(tracker.counts.metrics, [:], "nothing is running in the background")

        var host = UsageTracker()
        host.assumeForeground()
        host.resetCountsForNewRecord()
        XCTAssertEqual(host.counts.metrics, [:], "a foreground this process never counted is not carried")
    }

    func testForgetAllDropsTheOpenVisitsWithTheCounts() {
        var tracker = UsageTracker()
        tracker.enterForeground(at: 0)
        tracker.enter(.createPlus, at: 0)
        tracker.forgetAll()
        tracker.leave(.create, via: .createCancel, at: 5)
        XCTAssertEqual(tracker.counts.metrics, ["sessions": .number(1)], "the erased owner's visit settles nothing afterwards")
    }

    /// The detail's reflection editors are filled from the record in the same
    /// update that marks them loaded; only a change after that is the user's.
    func testTheReflectionNoteLoadIsNotAUserEdit() {
        let fresh = DetailReflectionEditUsageKey(loaded: false, note: "", templateID: nil, answerCount: 0)
        let loaded = DetailReflectionEditUsageKey(loaded: true, note: "stored note", templateID: nil, answerCount: 0)
        let typed = DetailReflectionEditUsageKey(loaded: true, note: "stored note!", templateID: nil, answerCount: 0)
        let emptyLoad = DetailReflectionEditUsageKey(loaded: true, note: "", templateID: nil, answerCount: 0)
        let firstKey = DetailReflectionEditUsageKey(loaded: true, note: "a", templateID: nil, answerCount: 0)
        XCTAssertFalse(DetailReflectionEditUsageKey.isUserEdit(from: fresh, to: loaded), "the load")
        XCTAssertFalse(DetailReflectionEditUsageKey.isUserEdit(from: fresh, to: emptyLoad), "the load of an empty note")
        XCTAssertTrue(DetailReflectionEditUsageKey.isUserEdit(from: loaded, to: typed), "a keystroke after the load")
        XCTAssertTrue(DetailReflectionEditUsageKey.isUserEdit(from: emptyLoad, to: firstKey), "the first keystroke into an empty note")
        XCTAssertFalse(DetailReflectionEditUsageKey.isUserEdit(from: loaded, to: loaded))
        let answered = DetailReflectionEditUsageKey(loaded: true, note: "stored note", templateID: nil, answerCount: 1)
        XCTAssertTrue(DetailReflectionEditUsageKey.isUserEdit(from: loaded, to: answered), "a template answer")
    }

    func testEveryChangeToTheCountsMovesTheChangeCount() {
        var tracker = UsageTracker()
        var last = tracker.changeCount
        func moved(_ what: String) {
            XCTAssertNotEqual(tracker.changeCount, last, what)
            last = tracker.changeCount
        }
        tracker.enterForeground(at: 0); moved("session")
        tracker.enter(.createPlus, at: 0); moved("enter")
        tracker.use(.allDayToggle); moved("use")
        tracker.done(.create); moved("done")
        tracker.view(.eventDetailReflection); moved("view")
        tracker.count(.createAIFallback); moved("event")
        tracker.leave(.create, via: .createCancel, at: 1); moved("leave")
        tracker.resetCountsForNewRecord(); moved("reset")
        tracker.forgetAll(); moved("forget")
        XCTAssertFalse(tracker.enterForeground(at: 2))
        XCTAssertEqual(tracker.changeCount, last, "a no-op changes nothing")
    }
}

// MARK: - Registry JSON vs the Swift declarations (wire contract §4)

@MainActor
final class UsageRegistryTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The nine contract columns, as the Swift side declares them for a key.
    static func expectedRow(_ key: UsageKey) -> [String: Any] {
        [
            "key": key.name,
            "kind": key.kind.rawValue,
            "family": "usage",
            "value_schema": key.kind == .histogram ? "fixed_string" : "number",
            "since_build": key.sinceBuild,
            "retired_build": NSNull(),
            "liveness_key": key.livenessKey.map { $0 as Any } ?? NSNull(),
            "spike_id": UsageRecordIDs.spikeID,
            "description": key.description,
        ]
    }

    func testTheRegistryHoldsExactlyTheDeclaredUsageKeysColumnForColumn() throws {
        let url = repoRoot.appendingPathComponent("done-mcp/supabase/telemetry/key_registry.json")
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        let usageRows = rows.filter { ($0["family"] as? String) == "usage" || ($0["spike_id"] as? String) == UsageRecordIDs.spikeID }
        let expected = UsageKey.all.map(Self.expectedRow)

        func canonical(_ row: [String: Any]) -> String {
            String(decoding: (try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        }
        let onDisk = Set(usageRows.map(canonical))
        let declared = Set(expected.map(canonical))
        let missing = declared.subtracting(onDisk).sorted()
        let stray = onDisk.subtracting(declared).sorted()
        if !missing.isEmpty || !stray.isEmpty {
            // The rows the registry should hold, for regenerating it.
            let dump = (try? JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])) ?? Data()
            print("USAGE_REGISTRY_ROWS_BEGIN\n\(String(decoding: dump, as: UTF8.self))\nUSAGE_REGISTRY_ROWS_END")
        }
        XCTAssertEqual(missing, [], "declared in Swift, absent or different in key_registry.json")
        XCTAssertEqual(stray, [], "in key_registry.json, not declared in Swift")
        XCTAssertEqual(usageRows.count, UsageKey.all.count, "no duplicate rows")
        XCTAssertGreaterThan(UsageKey.all.count, 40, "liveness: the declarations produced the slice's keys")
    }
}

// MARK: - Source scan (design §11 item 18, §5 dead-key rule)

/// Comment- and string-blind scan of `Done/` (non-test) sources. Comments
/// are stripped first: a key named only in a comment is a dead wire that
/// reads as alive.
enum UsageSourceScan {
    struct Call: Equatable {
        let file: String
        let verb: String
        let tokens: Set<String>
        /// The first `.token` of the arguments (leave's feature).
        let first: String?
        let offset: Int
    }

    static func stripCommentsAndStrings(_ source: String) -> String {
        let chars = Array(source.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        func peek(_ k: Int) -> Unicode.Scalar? { i + k < chars.count ? chars[i + k] : nil }
        while i < chars.count {
            let c = chars[i]
            if c == "/", peek(1) == "/" {
                while i < chars.count, chars[i] != "\n" { out.append(" "); i += 1 }
                continue
            }
            if c == "/", peek(1) == "*" {
                var depth = 0
                repeat {
                    if chars[i] == "/", peek(1) == "*" { depth += 1; out.append(" "); out.append(" "); i += 2; continue }
                    if chars[i] == "*", peek(1) == "/" { depth -= 1; out.append(" "); out.append(" "); i += 2; continue }
                    out.append(chars[i] == "\n" ? "\n" : " ")
                    i += 1
                } while i < chars.count && depth > 0
                continue
            }
            if c == "\"" {
                let triple = peek(1) == "\"" && peek(2) == "\""
                let quoteLength = triple ? 3 : 1
                out.append("\"")
                for _ in 0..<quoteLength { i += 1 }
                while i < chars.count {
                    if chars[i] == "\\" { out.append(" "); out.append(" "); i += 2; continue }
                    if triple ? (chars[i] == "\"" && peek(1) == "\"" && peek(2) == "\"") : chars[i] == "\"" {
                        out.append("\"")
                        i += quoteLength
                        break
                    }
                    if !triple && chars[i] == "\n" { break }
                    out.append(chars[i] == "\n" ? "\n" : " ")
                    i += 1
                }
                continue
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    /// The balanced `(...)` or `{...}` starting at `open` (exclusive).
    static func balanced(_ text: [Character], from open: Int, _ l: Character, _ r: Character) -> Range<Int>? {
        var depth = 0
        var j = open
        while j < text.count {
            if text[j] == l { depth += 1 }
            if text[j] == r {
                depth -= 1
                if depth == 0 { return (open + 1)..<j }
            }
            j += 1
        }
        return nil
    }

    static func dotTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == ".", i + 1 < chars.count, chars[i + 1].isLetter {
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                tokens.append(String(chars[(i + 1)..<j]))
                i = j
                continue
            }
            i += 1
        }
        return tokens
    }

    static func calls(in stripped: String, file: String, prefix: String = "UsageProbe.") -> [Call] {
        let chars = Array(stripped)
        let needle = Array(prefix)
        var found: [Call] = []
        var i = 0
        while i + needle.count < chars.count {
            if Array(chars[i..<(i + needle.count)]) == needle {
                var j = i + needle.count
                var verb = ""
                while j < chars.count, chars[j].isLetter { verb.append(chars[j]); j += 1 }
                if j < chars.count, chars[j] == "(", let args = balanced(chars, from: j, "(", ")") {
                    let tokens = dotTokens(String(chars[args]))
                    found.append(Call(file: file, verb: verb, tokens: Set(tokens), first: tokens.first, offset: i))
                }
                i = j
                continue
            }
            i += 1
        }
        return found
    }

    /// Every `UsageProbe.enter(` inside the closure of an `.onAppear`.
    static func entersInsideOnAppear(_ stripped: String, file: String) -> [String] {
        let chars = Array(stripped)
        let needle = Array(".onAppear")
        var offenders: [String] = []
        var i = 0
        while i + needle.count < chars.count {
            guard Array(chars[i..<(i + needle.count)]) == needle else { i += 1; continue }
            var j = i + needle.count
            while j < chars.count, chars[j] == " " || chars[j] == "\n" || chars[j] == "\t" { j += 1 }
            if j < chars.count, chars[j] == "(" {
                // `.onAppear(perform: { … })`
                if let args = balanced(chars, from: j, "(", ")") {
                    let inner = String(chars[args])
                    if inner.contains("UsageProbe.enter(") { offenders.append("\(file): .onAppear(perform:) holds UsageProbe.enter") }
                    j = args.upperBound
                }
            } else if j < chars.count, chars[j] == "{", let body = balanced(chars, from: j, "{", "}") {
                if String(chars[body]).contains("UsageProbe.enter(") {
                    let line = chars[..<i].filter { $0 == "\n" }.count + 1
                    offenders.append("\(file):\(line): .onAppear { … UsageProbe.enter … }")
                }
                j = body.upperBound
            }
            i = j
        }
        return offenders
    }
}

@MainActor
final class UsageSourceScanTests: XCTestCase {
    private var doneRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Done")
    }

    private func sources() throws -> [(file: String, stripped: String)] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: doneRoot, includingPropertiesForKeys: nil))
        var out: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            out.append((url.path.replacingOccurrences(of: doneRoot.path + "/", with: ""), UsageSourceScan.stripCommentsAndStrings(text)))
        }
        return out
    }

    private func allCalls() throws -> [UsageSourceScan.Call] {
        try sources().flatMap { UsageSourceScan.calls(in: $0.stripped, file: $0.file) }
            .filter { $0.file != "Models/UsageModel.swift" }
    }

    func testEveryDeclaredEntryHasAnEnterSiteAndEveryVisitedFeatureALeaveSite() throws {
        let calls = try allCalls()
        XCTAssertGreaterThan(calls.count, 30, "liveness: the scan found the probe's call sites")
        let enterTokens = calls.filter { $0.verb == "enter" }.reduce(into: Set<String>()) { $0.formUnion($1.tokens) }
        let leaveFirsts = Set(calls.filter { $0.verb == "leave" }.compactMap(\.first))
        var violations: [String] = []
        for feature in UsageFeature.allCases where feature.declaration.hasVisits {
            for entry in feature.declaration.entries where !enterTokens.contains("\(entry.tag)") {
                violations.append("\(entry.tag): no UsageProbe.enter site")
            }
            if !leaveFirsts.contains("\(feature)") {
                violations.append("\(feature): entered but never settled — no UsageProbe.leave(.\(feature)…) site")
            }
        }
        XCTAssertEqual(violations, [])
    }

    /// §5's dead-wire rule for the other stages: a declared key with no
    /// emit site reads as "nobody used it" on the server. The archive
    /// toggles and every `available` are emitted through `switchToggled`,
    /// so each gate needs a toggle site.
    func testEveryDeclaredUseDoneViewRouteAndTallyHasASite() throws {
        let calls = try allCalls()
        func tokens(_ verbs: Set<String>) -> Set<String> {
            calls.filter { verbs.contains($0.verb) }.reduce(into: Set<String>()) { $0.formUnion($1.tokens) }
        }
        var violations: [String] = []
        let toggleTags = Set(UsageGate.allCases.flatMap { [$0.toggleTags.on, $0.toggleTags.off] })
        // `switchToggled` is reached only through the Settings toggles'
        // `userToggle(_:_:)` setter; each gate needs its own toggle there.
        XCTAssertFalse(calls.filter { $0.verb == "switchToggled" }.isEmpty, "liveness: the toggle setter calls the probe")
        let toggleSites = try sources().flatMap { UsageSourceScan.calls(in: $0.stripped, file: $0.file, prefix: "Self.") }
            .filter { $0.verb == "userToggle" }
        let gatesWithToggle = toggleSites.reduce(into: Set<String>()) { $0.formUnion($1.tokens) }
        for gate in UsageGate.allCases where !gatesWithToggle.contains("\(gate)") { violations.append("gate \(gate): no Settings toggle site") }
        for tag in UsageUse.allCases where !toggleTags.contains(tag) && !tokens(["use"]).contains("\(tag)") { violations.append("use \(tag)") }
        for tag in UsageDone.allCases where !tokens(["done"]).contains("\(tag)") { violations.append("done \(tag)") }
        for tag in UsageView.allCases where !tokens(["view"]).contains("\(tag)") { violations.append("view \(tag)") }
        for tag in UsageRoute.allCases where !tokens(["leave", "noteExit"]).contains("\(tag)") { violations.append("route \(tag)") }
        for tag in UsageEvent.allCases where !tokens(["count"]).contains("\(tag)") { violations.append("tally \(tag)") }
        XCTAssertEqual(violations, [])
    }

    func testNoEnterSitsInsideAnOnAppearClosure() throws {
        let offenders = try sources().flatMap { UsageSourceScan.entersInsideOnAppear($0.stripped, file: $0.file) }
        XCTAssertEqual(offenders, [])
    }

    /// Design §3 L0: the usage model is arithmetic over values the caller
    /// holds. Comments are stripped first, so a doc line naming a banned API
    /// cannot satisfy or trip the scan.
    func testTheUsageModelStaysPure() throws {
        let url = doneRoot.appendingPathComponent("Models/UsageModel.swift")
        let code = UsageSourceScan.stripCommentsAndStrings(try String(contentsOf: url, encoding: .utf8))
        XCTAssertTrue(code.contains("struct UsageTracker"), "liveness: the scan read the model")
        for banned in ["UserDefaults", "Calendar", "FileManager", "URLSession", "UIKit", "SwiftUI", "@Published",
                       "DispatchQueue", "NotificationCenter", "Date()", "DiagnosticTrail", "SpikeRunStore"] {
            XCTAssertFalse(code.contains(banned), "UsageModel.swift must not use \(banned)")
        }
    }

    /// Positive controls for the scanner itself: it finds an enter inside an
    /// `onAppear` (both spellings), ignores one that is only in a comment or
    /// a string, and does not mistake a neighbouring closure for onAppear's.
    func testTheScannerSeesWhatItClaimsToSee() {
        let bad = """
        .onAppear {
            prepare()
            if ready { UsageProbe.enter(.eventDetailCanvas) }
        }
        .onAppear(perform: { UsageProbe.enter(.createPlus) })
        """
        XCTAssertEqual(UsageSourceScan.entersInsideOnAppear(UsageSourceScan.stripCommentsAndStrings(bad), file: "x").count, 2)

        let fine = """
        .onAppear { prepare() } // UsageProbe.enter(.eventDetailCanvas)
        .onTapGesture { UsageProbe.enter(.eventDetailCanvas) }
        /* .onAppear { UsageProbe.enter(.createPlus) } */
        let s = ".onAppear { UsageProbe.enter(.createPlus) }"
        """
        let stripped = UsageSourceScan.stripCommentsAndStrings(fine)
        XCTAssertEqual(UsageSourceScan.entersInsideOnAppear(stripped, file: "x"), [])
        let calls = UsageSourceScan.calls(in: stripped, file: "x")
        XCTAssertEqual(calls.map(\.verb), ["enter"], "only the tap's enter is code")
        XCTAssertEqual(calls.first?.tokens, ["eventDetailCanvas"])

        let ternary = "UsageProbe.leave(.focus, via: enabled ? .focusRotate : .focusSystem)"
        let call = UsageSourceScan.calls(in: ternary, file: "x").first
        XCTAssertEqual(call?.first, "focus")
        XCTAssertEqual(call?.tokens, ["focus", "focusRotate", "focusSystem"])
    }
}
