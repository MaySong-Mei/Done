//
//  UsageModel.swift
//  Done
//
//  gh#273 §6.3 — per-feature usage, counted by STAGE: a visit is entered
//  (and from where), used, completed, abandoned, and lasts a foreground
//  dwell. Pure data and arithmetic: no file I/O, no UserDefaults, no
//  Calendar, no UIKit, no publishing. The resident center
//  (ResidentObservationCenter.swift) owns the clocks, the lifecycle edges
//  and the daily `usage-daily` record; `UsageProbe` is the one door the
//  views knock on.
//
//  Shared with the Mac target: the create form and its sheet wrapper call
//  the probe and compile there too. On the Mac no sink is ever installed,
//  so every probe call is a nil check.
//
//  Cost contract (design §3 L0, §10): a signal is a static weak read, one
//  Date read and one Double compare in the center (the day bound), an
//  array subscript and an add. Opening a visit writes one small struct
//  into a fixed array; closing one is at most three compares and two adds.
//  No dictionary, no string, no allocation on any of those paths — every
//  table below is built once (the center touches `UsageLayout.shared` when
//  it activates) and only read afterwards.
//

import Foundation

// MARK: - Vocabulary (tags only; names and membership live in UsageFeature)

/// Where an entry comes from: the user opened it, or something that is not
/// a user action brought them there (rotation into landscape focus).
enum UsageEntrySource: String, CaseIterable {
    case user
    case auto
}

/// How one feature's leave routes are counted.
enum UsageRouteStage: Equatable {
    /// `exit.<route>` on every settled visit, used or not (focus: how the
    /// user left). The visit's abandonment is the bare `abandon` key.
    case exit
    /// `abandon.<route>` only when the visit is abandoned (create: how the
    /// user gave up). There is no bare `abandon` key for such a feature.
    case abandon
}

enum UsageEntry: UInt16, CaseIterable {
    case focusTap, focusAuto
    case focusPrecreatePill
    case eventDetailCanvas, eventDetailMenu, eventDetailList, eventDetailSearch
    case createDrag, createPlus, createResumeDraft, createReminderAI
    case repeatRuleEditor
}

enum UsageUse: UInt16, CaseIterable {
    case focusExtend, focusEndNow, focusNote, focusTrack
    case eventDetailPlan, eventDetailReflect, eventDetailTimelineNote, eventDetailTodo, eventDetailDelete
    case repeatForm, repeatDeleteSeries
    case allDayToggle
}

enum UsageDone: UInt16, CaseIterable {
    case focusPrecreate
    case create, createRepeat, createAllDay, createNote
    case repeatRule
}

enum UsageView: UInt16, CaseIterable {
    case eventDetailReflection
}

enum UsageRoute: UInt16, CaseIterable {
    case focusSwipe, focusRotate, focusSystem
    case createCancel, createSwipe
}

/// Counts that belong to a feature but to no visit.
enum UsageEvent: UInt16, CaseIterable {
    case createAbandonBanner, createAIFallback
}

// MARK: - Declaration

/// One feature's whole surface, as the registry and the record see it.
/// `UsageKey` is derived from these declarations; adding a feature is one
/// `UsageFeature` case plus its tags above.
struct UsageDeclaration {
    struct Entry { let tag: UsageEntry; let name: String; let source: UsageEntrySource; let what: String }
    /// `name == nil` is the bare `use` key (a feature with one kind of use).
    struct Use { let tag: UsageUse; let name: String?; let what: String }
    /// `name == nil` is the bare `done` key; a named done is an ATTRIBUTE of
    /// a done (a subset count, each ≤ the bare key), never a partition.
    struct Done { let tag: UsageDone; let name: String?; let what: String }
    struct View { let tag: UsageView; let name: String; let what: String }
    struct Route { let tag: UsageRoute; let name: String; let what: String }
    /// `suffix` is everything after `usage.<feature>.`.
    struct Tally { let tag: UsageEvent; let suffix: String; let what: String }

    let name: String
    let summary: String
    /// First build that writes this feature's keys (`since_build`).
    let sinceBuild: Int
    let entries: [Entry]
    let uses: [Use]
    let dones: [Done]
    let views: [View]
    let routes: [Route]
    let routeStage: UsageRouteStage
    let events: [Tally]

    /// A feature with an entry has visits: they settle `abandon` and `dwell`.
    var hasVisits: Bool { !entries.isEmpty }

    init(name: String, summary: String, sinceBuild: Int, entries: [Entry] = [], uses: [Use] = [],
         dones: [Done] = [], views: [View] = [], routes: [Route] = [],
         routeStage: UsageRouteStage = .exit, events: [Tally] = []) {
        self.name = name
        self.summary = summary
        self.sinceBuild = sinceBuild
        self.entries = entries
        self.uses = uses
        self.dones = dones
        self.views = views
        self.routes = routes
        self.routeStage = routeStage
        self.events = events
    }
}

enum UsageFeature: UInt16, CaseIterable {
    case focus
    /// The confirm-before-tracking preview inside focus: its own small visit
    /// so that Begin is its `done` and Cancel its `abandon` without either
    /// being confused with leaving focus itself.
    case focusPrecreate
    case eventDetail
    case create
    case repeatRule
    case allDay

    /// The build this slice ships in; per feature so a later feature can
    /// carry its own.
    static let firstUsageBuild = 29

    var declaration: UsageDeclaration {
        let build = Self.firstUsageBuild
        switch self {
        case .focus:
            return UsageDeclaration(
                name: "focus", summary: "Focus mode", sinceBuild: build,
                entries: [
                    .init(tag: .focusTap, name: "tap", source: .user, what: "the focus button in the calendar header"),
                    .init(tag: .focusAuto, name: "auto", source: .auto, what: "rotated into landscape with landscape focus on"),
                ],
                uses: [
                    .init(tag: .focusExtend, name: "extend", what: "a -15 / +15 pill on the current event"),
                    .init(tag: .focusEndNow, name: "end_now", what: "End on the current event"),
                    .init(tag: .focusNote, name: "note", what: "a note sent from the composer (not the auto-save on background or teardown)"),
                    .init(tag: .focusTrack, name: "track", what: "a type pill on the idle clock"),
                ],
                routes: [
                    .init(tag: .focusSwipe, name: "swipe", what: "swiped the surface away"),
                    .init(tag: .focusRotate, name: "rotate", what: "rotated back to portrait"),
                    .init(tag: .focusSystem, name: "system", what: "ended without a gesture (the setting went off, or a dismissal recovered on foreground)"),
                ],
                routeStage: .exit
            )
        case .focusPrecreate:
            return UsageDeclaration(
                name: "focus_precreate", summary: "Focus: the confirm-before-tracking preview", sinceBuild: build,
                entries: [
                    .init(tag: .focusPrecreatePill, name: "pill", source: .user, what: "a type pill with confirm-before-tracking on"),
                ],
                dones: [
                    .init(tag: .focusPrecreate, name: nil, what: "Begin"),
                ]
            )
        case .eventDetail:
            return UsageDeclaration(
                name: "event_detail", summary: "Event detail", sinceBuild: build,
                entries: [
                    .init(tag: .eventDetailCanvas, name: "canvas", source: .user, what: "a block or all-day bar on the calendar"),
                    .init(tag: .eventDetailMenu, name: "menu", source: .user, what: "View details / Log in the block's floating menu"),
                    .init(tag: .eventDetailList, name: "list", source: .user, what: "a row in the list view"),
                    .init(tag: .eventDetailSearch, name: "search", source: .user, what: "a search result or occurrence row"),
                ],
                uses: [
                    .init(tag: .eventDetailPlan, name: "plan", what: "type, duration, repeat, name or edit"),
                    .init(tag: .eventDetailReflect, name: "reflect", what: "completion, effort, tags, note or template"),
                    .init(tag: .eventDetailTimelineNote, name: "timeline_note", what: "a timeline note added, edited or deleted"),
                    .init(tag: .eventDetailTodo, name: "todo", what: "a todo done, released, deadline or returned to the stack"),
                    .init(tag: .eventDetailDelete, name: "delete", what: "delete confirmed"),
                ],
                views: [
                    .init(tag: .eventDetailReflection, name: "reflection", what: "the reflection page shown (not a use)"),
                ]
            )
        case .create:
            return UsageDeclaration(
                name: "create", summary: "New event", sinceBuild: build,
                entries: [
                    .init(tag: .createDrag, name: "drag", source: .user, what: "a drag on empty canvas"),
                    .init(tag: .createPlus, name: "plus", source: .user, what: "the + in the calendar header"),
                    .init(tag: .createResumeDraft, name: "resume_draft", source: .user, what: "the resume-draft banner"),
                    .init(tag: .createReminderAI, name: "reminder_ai", source: .user, what: "Add to schedule on a reminder (the form opens after the AI)"),
                ],
                dones: [
                    .init(tag: .create, name: nil, what: "Done in the new-event form"),
                    .init(tag: .createRepeat, name: "repeat", what: "a done whose event repeats (subset of done)"),
                    .init(tag: .createAllDay, name: "all_day", what: "a done whose event is all-day (subset of done)"),
                    .init(tag: .createNote, name: "note", what: "a done whose event has a note (subset of done)"),
                ],
                routes: [
                    .init(tag: .createCancel, name: "cancel", what: "Cancel without Done"),
                    .init(tag: .createSwipe, name: "swipe", what: "swiped down without Done"),
                ],
                routeStage: .abandon,
                events: [
                    .init(tag: .createAbandonBanner, suffix: "abandon.banner", what: "a kept draft discarded from the resume banner, after its visit settled (not a visit settle)"),
                    .init(tag: .createAIFallback, suffix: "ai_fallback", what: "a reminder opened without AI prefill (AI off or failed)"),
                ]
            )
        case .repeatRule:
            return UsageDeclaration(
                name: "repeat", summary: "Repeat rule", sinceBuild: build,
                entries: [
                    .init(tag: .repeatRuleEditor, name: "rule_editor", source: .user, what: "Manage repeat in event detail"),
                ],
                uses: [
                    .init(tag: .repeatForm, name: "form", what: "a repeat other than never picked in an event form (outside any rule-editor visit)"),
                    .init(tag: .repeatDeleteSeries, name: "delete_series", what: "Delete entire series in the rule editor"),
                ],
                dones: [
                    .init(tag: .repeatRule, name: nil, what: "Save in the rule editor"),
                ]
            )
        case .allDay:
            return UsageDeclaration(
                name: "all_day", summary: "All-day switch", sinceBuild: build,
                uses: [
                    .init(tag: .allDayToggle, name: nil, what: "the all-day switch in an event form flipped"),
                ]
            )
        }
    }
}

// MARK: - Keys (derived)

/// One registry key. Its name is the one the record, the registry JSON and
/// the server's views use; `slot` is where its count lives in
/// `UsageCounts.values` (a histogram takes `UsageDwell.bucketCount` slots).
struct UsageKey: Equatable {
    enum Kind: String { case counter, histogram }

    let name: String
    let kind: Kind
    /// nil for the denominator `sessions`.
    let feature: UsageFeature?
    let slot: Int
    let sinceBuild: Int
    let description: String

    var slotCount: Int { kind == .histogram ? UsageDwell.bucketCount : 1 }

    /// The denominator: background → foreground, plus the launch. Named as
    /// the 016 checks fixture and every usage key's `liveness_key` name it.
    static let sessionsName = "sessions"
    static let prefix = "usage."

    static var all: [UsageKey] { UsageLayout.shared.keys }
}

enum UsageRecordIDs {
    /// Read by `TelemetryRecordKind.inferred`, which is nonisolated.
    nonisolated static let spikeID = "usage-daily"
    nonisolated static let scenarioID = "daily-rollup"
}

// MARK: - Dwell (pure)

/// Foreground time of one visit, in four fixed buckets. Upper bounds are
/// exclusive: under 3 s, under 30 s, under 300 s, 300 s and over.
enum UsageDwell {
    static let boundsSeconds: (Double, Double, Double) = (3, 30, 300)
    static let bucketCount = 4

    static func bucket(forSeconds seconds: Double) -> Int {
        if seconds < boundsSeconds.0 { return 0 }
        if seconds < boundsSeconds.1 { return 1 }
        if seconds < boundsSeconds.2 { return 2 }
        return 3
    }
}

// MARK: - Layout (built once)

/// Every key and every tag's slot, computed once from the declarations so
/// the signal path is a subscript. A class: the signal path holds one
/// reference to it, never a copy of its arrays.
final class UsageLayout {
    let keys: [UsageKey]
    let slotCount: Int
    let keysByName: [String: UsageKey]

    let entrySlot: [Int]
    let entryFeature: [UsageFeature]
    let useSlot: [Int]
    let useFeature: [UsageFeature]
    let doneSlot: [Int]
    let doneFeature: [UsageFeature]
    let viewSlot: [Int]
    let viewFeature: [UsageFeature]
    let routeSlot: [Int]
    let routeFeature: [UsageFeature]
    let eventSlot: [Int]
    /// Per feature (by raw value); -1 where the feature has none.
    let abandonSlot: [Int]
    let dwellSlot: [Int]
    let routeStage: [UsageRouteStage]
    let hasVisits: [Bool]

    static let shared = UsageLayout()
    /// `sessions` is the first key laid out.
    static let sessionsSlot = 0

    private init() {
        var keys: [UsageKey] = []
        var next = 0
        func add(_ name: String, _ kind: UsageKey.Kind, _ feature: UsageFeature?, _ since: Int, _ description: String) -> Int {
            let key = UsageKey(name: name, kind: kind, feature: feature, slot: next, sinceBuild: since, description: description)
            keys.append(key)
            next += key.slotCount
            return key.slot
        }
        _ = add(UsageKey.sessionsName, .counter, nil, UsageFeature.firstUsageBuild,
                "Usage denominator: foreground sessions on the day (the launch, each return from background, and a session already running when the record was minted). Control Center / Face ID do not count.")

        var entrySlot = Array(repeating: -1, count: UsageEntry.allCases.count)
        var entryFeature = Array(repeating: UsageFeature.focus, count: UsageEntry.allCases.count)
        var useSlot = Array(repeating: -1, count: UsageUse.allCases.count)
        var useFeature = Array(repeating: UsageFeature.focus, count: UsageUse.allCases.count)
        var doneSlot = Array(repeating: -1, count: UsageDone.allCases.count)
        var doneFeature = Array(repeating: UsageFeature.focus, count: UsageDone.allCases.count)
        var viewSlot = Array(repeating: -1, count: UsageView.allCases.count)
        var viewFeature = Array(repeating: UsageFeature.focus, count: UsageView.allCases.count)
        var routeSlot = Array(repeating: -1, count: UsageRoute.allCases.count)
        var routeFeature = Array(repeating: UsageFeature.focus, count: UsageRoute.allCases.count)
        var eventSlot = Array(repeating: -1, count: UsageEvent.allCases.count)
        var abandonSlot = Array(repeating: -1, count: UsageFeature.allCases.count)
        var dwellSlot = Array(repeating: -1, count: UsageFeature.allCases.count)
        var routeStage = Array(repeating: UsageRouteStage.exit, count: UsageFeature.allCases.count)
        var hasVisits = Array(repeating: false, count: UsageFeature.allCases.count)

        for feature in UsageFeature.allCases {
            let d = feature.declaration
            let base = UsageKey.prefix + d.name + "."
            let f = Int(feature.rawValue)
            let label = "Usage - \(d.summary)"
            routeStage[f] = d.routeStage
            hasVisits[f] = d.hasVisits
            for e in d.entries {
                let i = Int(e.tag.rawValue)
                entrySlot[i] = add(base + "enter." + e.name, .counter, feature, d.sinceBuild,
                                   "\(label) - entered (\(e.source.rawValue)): \(e.what).")
                entryFeature[i] = feature
            }
            for u in d.uses {
                let i = Int(u.tag.rawValue)
                useSlot[i] = add(base + "use" + (u.name.map { "." + $0 } ?? ""), .counter, feature, d.sinceBuild,
                                 "\(label) - used: \(u.what).")
                useFeature[i] = feature
            }
            for done in d.dones {
                let i = Int(done.tag.rawValue)
                doneSlot[i] = add(base + "done" + (done.name.map { "." + $0 } ?? ""), .counter, feature, d.sinceBuild,
                                  "\(label) - done: \(done.what).")
                doneFeature[i] = feature
            }
            for v in d.views {
                let i = Int(v.tag.rawValue)
                viewSlot[i] = add(base + "view." + v.name, .counter, feature, d.sinceBuild,
                                  "\(label) - viewed: \(v.what).")
                viewFeature[i] = feature
            }
            if d.hasVisits {
                switch d.routeStage {
                case .exit:
                    abandonSlot[f] = add(base + "abandon", .counter, feature, d.sinceBuild,
                                         "\(label) - abandoned: a visit left with no use and no done.")
                    for r in d.routes {
                        let i = Int(r.tag.rawValue)
                        routeSlot[i] = add(base + "exit." + r.name, .counter, feature, d.sinceBuild,
                                           "\(label) - left (every settled visit): \(r.what).")
                        routeFeature[i] = feature
                    }
                case .abandon:
                    for r in d.routes {
                        let i = Int(r.tag.rawValue)
                        routeSlot[i] = add(base + "abandon." + r.name, .counter, feature, d.sinceBuild,
                                           "\(label) - abandoned (a visit with no done): \(r.what).")
                        routeFeature[i] = feature
                    }
                }
                dwellSlot[f] = add(base + "dwell", .histogram, feature, d.sinceBuild,
                                   "\(label) - foreground dwell per settled visit, buckets <3 s / <30 s / <300 s / >=300 s.")
            }
            for ev in d.events {
                eventSlot[Int(ev.tag.rawValue)] = add(base + ev.suffix, .counter, feature, d.sinceBuild,
                                                      "\(label) - \(ev.what).")
            }
        }

        self.keys = keys
        self.slotCount = next
        self.keysByName = Dictionary(uniqueKeysWithValues: keys.map { ($0.name, $0) })
        self.entrySlot = entrySlot
        self.entryFeature = entryFeature
        self.useSlot = useSlot
        self.useFeature = useFeature
        self.doneSlot = doneSlot
        self.doneFeature = doneFeature
        self.viewSlot = viewSlot
        self.viewFeature = viewFeature
        self.routeSlot = routeSlot
        self.routeFeature = routeFeature
        self.eventSlot = eventSlot
        self.abandonSlot = abandonSlot
        self.dwellSlot = dwellSlot
        self.routeStage = routeStage
        self.hasVisits = hasVisits
    }

    /// Tags no feature declares (a slot of -1). Empty by construction when
    /// every tag is listed in exactly one declaration; a test pins it.
    var undeclaredTags: [String] {
        var missing: [String] = []
        for t in UsageEntry.allCases where entrySlot[Int(t.rawValue)] < 0 { missing.append("\(t)") }
        for t in UsageUse.allCases where useSlot[Int(t.rawValue)] < 0 { missing.append("\(t)") }
        for t in UsageDone.allCases where doneSlot[Int(t.rawValue)] < 0 { missing.append("\(t)") }
        for t in UsageView.allCases where viewSlot[Int(t.rawValue)] < 0 { missing.append("\(t)") }
        for t in UsageRoute.allCases where routeSlot[Int(t.rawValue)] < 0 { missing.append("\(t)") }
        for t in UsageEvent.allCases where eventSlot[Int(t.rawValue)] < 0 { missing.append("\(t)") }
        return missing
    }
}

// MARK: - Counts (pure)

/// The day's usage counts: one fixed array, every key at its slot. Equatable
/// for the center's dirty check.
struct UsageCounts: Equatable {
    private(set) var values: [Int]

    init() {
        values = Array(repeating: 0, count: UsageLayout.shared.slotCount)
    }

    mutating func bump(slot: Int) {
        values[slot] += 1
    }

    func count(_ name: String) -> Int? {
        guard let key = UsageLayout.shared.keysByName[name], key.kind == .counter else { return nil }
        return values[key.slot]
    }

    func dwellBuckets(_ feature: UsageFeature) -> [Int]? {
        let slot = UsageLayout.shared.dwellSlot[Int(feature.rawValue)]
        guard slot >= 0 else { return nil }
        return Array(values[slot..<(slot + UsageDwell.bucketCount)])
    }

    var isEmpty: Bool { values.allSatisfy { $0 == 0 } }

    /// The record's metrics. A key whose value is 0 (a histogram whose
    /// buckets are all 0) is not written: the server reads a registered key
    /// that is missing as 0 (wire contract §4), and a day's line stays small.
    var metrics: [String: SpikeMetricValue] {
        var out: [String: SpikeMetricValue] = [:]
        for key in UsageLayout.shared.keys {
            switch key.kind {
            case .counter:
                let n = values[key.slot]
                if n != 0 { out[key.name] = .number(Double(n)) }
            case .histogram:
                let buckets = values[key.slot..<(key.slot + UsageDwell.bucketCount)]
                if buckets.contains(where: { $0 != 0 }) {
                    out[key.name] = .string(buckets.map(String.init).joined(separator: " "))
                }
            }
        }
        return out
    }

    /// Relaunch seed from the day's record. Keys this build does not know
    /// are dropped and counted — a renamed or retired key must not ride back
    /// out on the next line — and so is a value of the wrong shape.
    init(metrics: [String: SpikeMetricValue], unknownKeyDrops: inout Int) {
        self.init()
        let layout = UsageLayout.shared
        for (name, value) in metrics {
            guard let key = layout.keysByName[name] else {
                unknownKeyDrops += 1
                continue
            }
            switch (key.kind, value) {
            case (.counter, .number(let n)) where n >= 0 && n == n.rounded() && n < 1e12:
                values[key.slot] = Int(n)
            case (.histogram, .string(let raw)):
                let parts = raw.split(separator: " ").compactMap { Int($0) }
                guard parts.count == UsageDwell.bucketCount, parts.allSatisfy({ $0 >= 0 }) else {
                    unknownKeyDrops += 1
                    continue
                }
                for (offset, n) in parts.enumerated() { values[key.slot + offset] = n }
            default:
                unknownKeyDrops += 1
            }
        }
    }
}

// MARK: - Visits and the tracker (pure)

/// One open visit: foreground time so far, whether the clock is running,
/// and whether anything was used or completed.
struct UsageVisit: Equatable {
    var foregroundSeconds: Double = 0
    /// Media time the clock last resumed; nil while paused (background).
    var runningSince: Double?
    var touched = false

    func foregroundSeconds(at now: Double) -> Double {
        foregroundSeconds + (runningSince.map { max(0, now - $0) } ?? 0)
    }
}

/// Everything usage does with a signal, minus the clock and the disk. The
/// center reads the media clock, calls in, and writes `counts` at its
/// flushes. Visits live only here, in memory: a process that dies with a
/// visit open (killed in the background) never settles it — its `enter`
/// was counted, its dwell and abandonment never are.
struct UsageTracker: Equatable {
    private(set) var counts = UsageCounts()
    /// Bumped by every change to `counts`. The center's dirty check compares
    /// it with the value it last wrote, instead of holding a copy of the
    /// counts — a held copy shares the array, and the first bump after each
    /// flush would then copy it on the signal path.
    private(set) var changeCount = 0
    private(set) var visits: [UsageVisit?] = Array(repeating: nil, count: UsageFeature.allCases.count)
    /// A leave route noted by the surface just before it asks to be closed
    /// (focus: the swipe that ends it), consumed by the leave that follows.
    private(set) var exitHints: [UsageRoute?] = Array(repeating: nil, count: UsageFeature.allCases.count)
    /// Between a launch or a return from background and the next
    /// `didEnterBackground`. Starts false: the center decides at activation.
    private(set) var inForeground = false

    init() {}

    func isVisitOpen(_ feature: UsageFeature) -> Bool { visits[Int(feature.rawValue)] != nil }

    private mutating func bump(_ slot: Int) {
        counts.bump(slot: slot)
        changeCount &+= 1
    }

    mutating func enter(_ entry: UsageEntry, at now: Double) {
        let layout = UsageLayout.shared
        let i = Int(entry.rawValue)
        bump(layout.entrySlot[i])
        let f = Int(layout.entryFeature[i].rawValue)
        // A visit still open here never saw its leave: it is dropped, not
        // settled — the same as a visit whose process died — so a missing
        // leave can only make dwell and abandon UNDER-count, never invent
        // an abandonment.
        visits[f] = UsageVisit(foregroundSeconds: 0, runningSince: inForeground ? now : nil, touched: false)
        exitHints[f] = nil
    }

    mutating func use(_ use: UsageUse) {
        let layout = UsageLayout.shared
        let i = Int(use.rawValue)
        bump(layout.useSlot[i])
        touch(layout.useFeature[i])
    }

    mutating func done(_ done: UsageDone) {
        let layout = UsageLayout.shared
        let i = Int(done.rawValue)
        bump(layout.doneSlot[i])
        touch(layout.doneFeature[i])
    }

    /// A sub-page was shown. Not a use: abandonment is untouched.
    mutating func view(_ view: UsageView) {
        bump(UsageLayout.shared.viewSlot[Int(view.rawValue)])
    }

    mutating func count(_ event: UsageEvent) {
        bump(UsageLayout.shared.eventSlot[Int(event.rawValue)])
    }

    private mutating func touch(_ feature: UsageFeature) {
        let f = Int(feature.rawValue)
        if visits[f] != nil { visits[f]!.touched = true }
    }

    mutating func noteExit(_ route: UsageRoute) {
        let f = Int(UsageLayout.shared.routeFeature[Int(route.rawValue)].rawValue)
        guard visits[f] != nil else { return }
        exitHints[f] = route
    }

    /// Settles the feature's open visit, if any: the dwell bucket, then the
    /// abandonment (bare, or under the route for an abandon-routed feature),
    /// then the exit route for an exit-routed one. A route noted by the
    /// surface wins over `route`; a route of another feature is ignored.
    /// No open visit: nothing at all.
    mutating func leave(_ feature: UsageFeature, via route: UsageRoute?, at now: Double) {
        let layout = UsageLayout.shared
        let f = Int(feature.rawValue)
        guard let visit = visits[f] else { return }
        visits[f] = nil
        let hinted = exitHints[f]
        exitHints[f] = nil
        var resolved = hinted ?? route
        if let candidate = resolved, layout.routeFeature[Int(candidate.rawValue)] != feature {
            resolved = nil
        }
        bump(layout.dwellSlot[f] + UsageDwell.bucket(forSeconds: visit.foregroundSeconds(at: now)))
        switch layout.routeStage[f] {
        case .exit:
            if !visit.touched { bump(layout.abandonSlot[f]) }
            if let resolved { bump(layout.routeSlot[Int(resolved.rawValue)]) }
        case .abandon:
            if !visit.touched, let resolved { bump(layout.routeSlot[Int(resolved.rawValue)]) }
        }
    }

    /// `didEnterBackground`: every open visit's clock stops.
    mutating func enterBackground(at now: Double) {
        inForeground = false
        for f in visits.indices {
            guard var visit = visits[f], let since = visit.runningSince else { continue }
            visit.foregroundSeconds += max(0, now - since)
            visit.runningSince = nil
            visits[f] = visit
        }
    }

    /// The launch or a return from background: one session, and every open
    /// visit's clock resumes. Coming back is not a new enter. Idempotent
    /// while in the foreground, so the two notifications that announce one
    /// return (`willEnterForeground`, `didBecomeActive`) count it once, and
    /// a `didBecomeActive` with no background before it (Control Center,
    /// Face ID, a system alert) counts nothing.
    @discardableResult
    mutating func enterForeground(at now: Double) -> Bool {
        guard !inForeground else { return false }
        inForeground = true
        bump(UsageLayout.sessionsSlot)
        for f in visits.indices where visits[f] != nil && visits[f]!.runningSince == nil {
            visits[f]!.runningSince = now
        }
        return true
    }

    /// The process is in the foreground but nothing announced it (the
    /// center activating during a launch it does not count, e.g. under a
    /// test host): the clock runs, no session is counted.
    mutating func assumeForeground() {
        inForeground = true
    }

    /// A new record (day, owner, consent): the counts start over; open
    /// visits stay open and settle into the new record. A session already
    /// in progress is counted once in the new record too, so a day reached
    /// without a return from background still has a denominator.
    mutating func resetCountsForNewRecord() {
        counts = UsageCounts()
        changeCount &+= 1
        if inForeground { bump(UsageLayout.sessionsSlot) }
    }

    /// Relaunch seed: today's record as it was last written.
    mutating func seed(_ seeded: UsageCounts) {
        counts = seeded
        changeCount &+= 1
    }

    /// Erase: the counts AND the open visits are the erased owner's.
    mutating func forgetAll() {
        counts = UsageCounts()
        visits = Array(repeating: nil, count: UsageFeature.allCases.count)
        exitHints = Array(repeating: nil, count: UsageFeature.allCases.count)
        changeCount &+= 1
        if inForeground { bump(UsageLayout.sessionsSlot) }
    }
}

// MARK: - Probe (the views' door)

/// Who receives usage signals: the resident center in the app, a test's
/// center under XCTest, nobody on the Mac.
protocol UsageSink: AnyObject {
    func usageEnter(_ entry: UsageEntry)
    func usageUse(_ use: UsageUse)
    func usageDone(_ done: UsageDone)
    func usageView(_ view: UsageView)
    func usageCount(_ event: UsageEvent)
    func usageNoteExit(_ route: UsageRoute)
    func usageLeave(_ feature: UsageFeature, via route: UsageRoute?)
}

/// Placement rules (design §6.3): `enter` only inside the user action that
/// opens the surface (a button action, a tap callback) or at the trigger of
/// a non-user entry — never in `body`, never in `onAppear` (a pop back from
/// a pushed page, a rebuild and a launch all re-run it); `use` / `done` in
/// the action that leads to the write, never inside a store; `leave` where
/// the surface's presentation actually ends (the presenter's binding going
/// nil, a sheet's dismissal), never in `onDisappear` of a view that pushes
/// pages. A source scan pins every declared entry to an enter site and a
/// leave site, and keeps `enter` out of `onAppear`.
enum UsageProbe {
    static weak var sink: UsageSink?

    static func enter(_ entry: UsageEntry) { sink?.usageEnter(entry) }
    static func use(_ use: UsageUse) { sink?.usageUse(use) }
    static func done(_ done: UsageDone) { sink?.usageDone(done) }
    static func view(_ view: UsageView) { sink?.usageView(view) }
    static func count(_ event: UsageEvent) { sink?.usageCount(event) }
    /// The surface is about to ask to be closed, and says how.
    static func noteExit(_ route: UsageRoute) { sink?.usageNoteExit(route) }
    static func leave(_ feature: UsageFeature, via route: UsageRoute? = nil) { sink?.usageLeave(feature, via: route) }
}
