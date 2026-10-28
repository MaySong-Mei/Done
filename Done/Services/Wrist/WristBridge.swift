//
//  WristBridge.swift
//  Done
//
//  The phone end of the watch link. Owns the `WCSession`, pushes a
//  `WristSnapshot` whenever the calendar or the type catalog changes (and on
//  foreground / activation / watch pairing), and applies incoming
//  `WristCommand`s through `WristCommandApplier` with an idempotency ledger.
//
//  Receipts live in the ledger (UserDefaults), so the snapshot pushed by a
//  later process still carries the receipt for a command an earlier process
//  applied — the watch keeps a command pending until a snapshot reflects it.
//
//  Lifecycle: `activate()` runs from the app delegate at launch so a
//  background launch for an incoming message has a delegate in place;
//  `attach(store:templates:)` runs once the SwiftUI scene has built the
//  stores. A background launch may never connect a scene, so commands that
//  arrive in between are written to disk (`inbox`) and applied on the next
//  attach — the watch keeps showing its optimistic state until the snapshot
//  with the receipt follows. When the iOS app is not running at all the
//  system queues the transfer and delivers it on the next launch.
//

import Combine
import Foundation
import os
import WatchConnectivity

/// What the bridge needs from the session to push a snapshot. A seam so the
/// push policy is testable without WatchConnectivity.
protocol WristSessionTransport: AnyObject {
    /// Activated, paired, and the watch app is installed.
    var isReadyForSnapshot: Bool { get }
    func push(context: [String: Any]) throws
}

final class WCSessionTransport: WristSessionTransport {
    private let session: WCSession

    init(session: WCSession) {
        self.session = session
    }

    var isReadyForSnapshot: Bool {
        session.activationState == .activated && session.isPaired && session.isWatchAppInstalled
    }

    func push(context: [String: Any]) throws {
        try session.updateApplicationContext(context)
    }
}

@MainActor
final class WristBridge: NSObject {
    static let receiptLimit = 32
    static let inboxLimit = 64
    static let inboxDefaultsKey = "wrist.inbox"

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Done", category: "Wrist")
    private var session: WCSession?
    private var transport: WristSessionTransport?
    private weak var store: EventStore?
    private weak var templates: EventTypeTemplateStore?
    private var subscriptions: [AnyCancellable] = []
    private var ledger: WristAppliedLedger
    private let defaults: UserDefaults
    private(set) var lastSent: WristSnapshot?
    private(set) var pushCount = 0
    var now: () -> Date = Date.init

    init(
        ledger: WristAppliedLedger = WristAppliedLedger(),
        defaults: UserDefaults = .standard,
        transport: WristSessionTransport? = nil
    ) {
        self.ledger = ledger
        self.defaults = defaults
        self.transport = transport
        super.init()
    }

    /// Idempotent. No-op where WatchConnectivity is unsupported (iPad) and
    /// under XCTest (the host app must not talk to a paired simulator).
    func activate() {
        guard session == nil, WCSession.isSupported(), !EventStorageLocation.isRunningUnderXCTest else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
        transport = WCSessionTransport(session: session)
    }

    func attach(store: EventStore, templates: EventTypeTemplateStore) {
        self.store = store
        self.templates = templates
        subscriptions = []
        // `@Published` fires on willSet; the debounce reads the store after the
        // write has landed. 400ms coalesces a drag's burst into one push.
        store.$rawCalendarEvents
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.pushSnapshot() }
            .store(in: &subscriptions)
        templates.$templates
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.pushSnapshot() }
            .store(in: &subscriptions)
        // The stats are built off the main thread after a calendar change
        // and land later than the change itself: push again when they do.
        store.categoryStatsLanded
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.pushSnapshot() }
            .store(in: &subscriptions)
        // Settings → Apple Watch touches no calendar data, so nothing above
        // would carry a change of it to the wrist.
        defaults.publisher(for: \.watchStatsSettings)
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.pushSnapshot() }
            .store(in: &subscriptions)
        let queued = inbox
        inbox = []
        for command in queued { handle(command) }
#if DEBUG
        seedDebugTitlesIfAsked(store: store, templates: templates)
        seedDebugParallelDayIfAsked(store: store)
        seedDebugRepeatingIfAsked(store: store)
#endif
        pushSnapshot()
    }

#if DEBUG
    /// `-wristSeedTitles`: a fortnight of named blocks of the catalog's
    /// first type, so a paired-simulator check has names to be offered.
    /// Every day "Standup" 9:00–9:15, "Deep work" 9:30–12:00 and "Review"
    /// 14:00–15:00; evenings alternate between "Deep work" 17:00–19:00 then
    /// "Recap" 19:00–20:00, and "Reading" 19:00–20:00 on its own — the same
    /// slot, told apart only by what comes before it. Each set is added once
    /// per store. Debug builds only.
    /// `-wristSeedParallel`: today gets the watch's parallel fixture
    /// (`WristSessionClient.parallelFixture`) as real events, once — a
    /// parent with an embedded interrupt and a block beside it, a chain,
    /// identical twins, a quarter hour inside a long block, a pair and one
    /// running in from last night — so the phone's day and the watch's page
    /// can be compared side by side.
    private func seedDebugParallelDayIfAsked(store: EventStore) {
        guard ProcessInfo.processInfo.arguments.contains("-wristSeedParallel"),
              !store.canvasRenderableCalendarEvents.contains(where: { $0.title == "Deep work" && $0.type == "Work" }) else { return }
        let today = Calendar.current.startOfDay(for: now())
        func at(_ hours: Double) -> Date { today.addingTimeInterval(hours * 3600) }
        func add(_ title: String, _ type: String, _ from: Double, _ to: Double, parent: Event? = nil) -> Event {
            let event = Event(
                title: title, timeRanges: [.init(start: at(from), end: at(to))], type: type,
                displayKind: parent == nil ? .regular : .interrupt,
                interruptRelation: parent.map { EventInterruptRelation(parentEventID: $0.id, occurrenceDate: at(from)) }
            )
            store.addCalendarEvent(event)
            return event
        }
        _ = add("Sleep", "Sleep", -1, 7)
        _ = add("Wake up", "Read", 6.5, 8)
        let deep = add("Deep work", "Work", 9, 11)
        _ = add("Phone rang", "Call", 9.5, 9.75, parent: deep)
        _ = add("Review", "Meeting", 10, 10.5)
        _ = add("Gym", "Gym", 12, 13)
        _ = add("Lunch", "Lunch", 12.5, 13.5)
        _ = add("Read", "Read", 13, 14)
        _ = add("Plan A", "Plan", 15, 16)
        _ = add("Plan B", "Plan", 15, 16)
        _ = add("Writing", "Work", 16.5, 19)
        _ = add("Standup", "Meeting", 17, 17.25)
        _ = add("Pair X", "Gym", 20, 21)
        _ = add("Pair Y", "Lunch", 20.5, 21.5)
        logger.notice("debug: seeded the parallel day")
    }

    /// `-wristSeedRepeating`: a daily "Daily check" 8:00–8:30, once — a
    /// block the watch must refuse to move. Debug builds only.
    private func seedDebugRepeatingIfAsked(store: EventStore) {
        guard ProcessInfo.processInfo.arguments.contains("-wristSeedRepeating"),
              !store.canvasRenderableCalendarEvents.contains(where: { $0.title == "Daily check" }) else { return }
        let today = Calendar.current.startOfDay(for: now())
        var event = Event(
            title: "Daily check",
            timeRanges: [.init(start: today.addingTimeInterval(-86_400 + 8 * 3600), end: today.addingTimeInterval(-86_400 + 8.5 * 3600))],
            type: "Meeting"
        )
        event.repeatUnit = .day
        store.addCalendarEvent(event)
        logger.notice("debug: seeded a repeating block")
    }

    private func seedDebugTitlesIfAsked(store: EventStore, templates: EventTypeTemplateStore) {
        guard ProcessInfo.processInfo.arguments.contains("-wristSeedTitles"),
              let type = templates.templates.first?.title else { return }
        func seeded(_ title: String) -> Bool {
            store.canvasRenderableCalendarEvents.contains { $0.title == title && $0.type == type }
        }
        let morning = !seeded("Standup"), evening = !seeded("Recap")
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now())
        for offset in 1...14 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            var blocks: [(String, Double, Double)] = []
            if morning { blocks += [("Standup", 9, 9.25), ("Deep work", 9.5, 12), ("Review", 14, 15)] }
            if evening { blocks += offset.isMultiple(of: 2) ? [("Deep work", 17, 19), ("Recap", 19, 20)] : [("Reading", 19, 20)] }
            for (title, from, to) in blocks {
                store.addCalendarEvent(Event(
                    title: title,
                    timeRanges: [Event.TimeRange(start: day.addingTimeInterval(from * 3600), end: day.addingTimeInterval(to * 3600))],
                    type: type
                ))
            }
        }
        logger.notice("debug: seeded named \(type, privacy: .public) blocks")
    }
#endif

    /// Build and send the snapshot unless the watch already holds this
    /// content. Safe to call often.
    func pushSnapshot() {
        guard let store, let templates else { return }
        guard let transport, transport.isReadyForSnapshot else { return }
        let now = self.now()
        let full = WristSnapshotBuilder.snapshot(
            events: store.canvasRenderableCalendarEvents,
            templates: templates.templates,
            now: now,
            calendar: .current,
            language: AppLanguage.current.rawValue,
            receipts: ledger.recent(Self.receiptLimit),
            stats: store.latestCategoryStats,
            statsSettings: WristStatsSettings.load(from: defaults),
            motions: WristSnapshotBuilder.motions(
                create: EventCreationMotionFlag.isEnabled ? EventCreationMotionFlag.variant : nil,
                delete: EventDeletionMotionFlag.isEnabled ? EventDeletionMotionFlag.variant : nil,
                resize: EventResizeTweenFlag.isEnabled ? EventResizeTweenFlag.variant : nil
            ),
            colorHex: { EventTypeTemplateStore.colorHex(for: $0) }
        )
        guard let (snapshot, data) = Self.fitting(full, latestStats: store.latestCategoryStats, now: now) else {
            logger.error("snapshot does not fit even narrowed")
            return
        }
        if let lastSent, lastSent.hasSameContent(as: snapshot) { return }
        do {
            try transport.push(context: [WristWire.snapshotKey: data])
            lastSent = snapshot
            pushCount += 1
        } catch {
            logger.error("snapshot push failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// WatchConnectivity refuses payloads past roughly 64 KB, and a refused
    /// push would leave the watch with nothing new at all. Below the budget
    /// the full snapshot goes; past it, the step that keeps the most. The
    /// title hints are never dropped outright — without them the watch skips
    /// naming a new block altogether, and on a busy calendar that was every
    /// push — they shrink instead, and cost little once shrunk: first to
    /// the names alone (`compactHints`, clock and length only), then to the
    /// few the picker shows. For each stats reach in turn (thirty days, the
    /// last seven, the last three) the hints go full, then names alone, then
    /// the few; then the occurrences narrowed to yesterday…tomorrow with the
    /// shorter stats and the few; then no stats with each form of hints;
    /// then narrowed occurrences without stats, with names alone or the
    /// few; then as many of those occurrences as fit, nearest to now first,
    /// with the few.
    static let byteBudget = 60_000

    static func fitting(
        _ full: WristSnapshot, latestStats: CategoryStatsPayload?, now: Date
    ) -> (WristSnapshot, Data)? {
        let names = compactHints(full.titleHints, perType: WristSnapshotBuilder.maxTitlesPerType)
        let few = compactHints(full.titleHints, perType: WristTitleRanking.shownCount)
        func each(_ snapshot: WristSnapshot) -> [WristSnapshot] {
            [full.titleHints, names, few].map { hints in
                var candidate = snapshot
                candidate.titleHints = hints
                return candidate
            }
        }
        let shorter = [WristSnapshotBuilder.StatsReach.sevenDays, .threeDays].map { reach -> WristSnapshot in
            var candidate = full
            candidate.stats = latestStats.flatMap { WristSnapshotBuilder.trimmed($0, now: now, reach: reach) }
            return candidate
        }
        var noStats = full
        noStats.stats = nil
        var candidates = each(full)
        for snapshot in shorter { candidates += each(snapshot) }
        for snapshot in shorter {
            var candidate = WristSnapshotBuilder.narrowed(snapshot, now: now, calendar: .current)
            candidate.titleHints = few
            candidates.append(candidate)
        }
        candidates += each(noStats)
        var narrow = WristSnapshotBuilder.narrowed(noStats, now: now, calendar: .current)
        narrow.titleHints = names
        candidates.append(narrow)
        narrow.titleHints = few
        candidates.append(narrow)
        for candidate in candidates {
            guard let data = try? WristWire.encode(candidate) else { continue }
            if data.count <= byteBudget { return (candidate, data) }
        }
        // Last step: the occurrences nearest to now, as many as fit.
        let order = Dictionary(narrow.occurrences.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let byDistance = narrow.occurrences.sorted { distance($0, now) < distance($1, now) }
        var low = 0, high = byDistance.count
        var best: (WristSnapshot, Data)?
        while low <= high {
            let mid = (low + high) / 2
            var candidate = narrow
            // Back in the snapshot's own order, the store's.
            candidate.occurrences = byDistance.prefix(mid).sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
            guard let data = try? WristWire.encode(candidate) else { return best }
            if data.count <= byteBudget {
                best = (candidate, data)
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }

    /// Up to `perType` of each type's names in the order sent, with only
    /// what ranks them by clock and length: what came before and after
    /// (indices into a table of every sent name), the weekdays and the time
    /// into the day are left out.
    static func compactHints(_ hints: [String: [WristTitleHint]], perType: Int) -> [String: [WristTitleHint]] {
        hints.mapValues { list in
            list.prefix(perType).map {
                WristTitleHint(title: $0.title, weight: $0.weight, startMinute: $0.startMinute,
                               concentration: $0.concentration, minutes: $0.minutes)
            }
        }
    }

    private static func distance(_ occurrence: WristOccurrence, _ now: Date) -> TimeInterval {
        if occurrence.start <= now && occurrence.end > now { return 0 }
        return min(abs(occurrence.start.timeIntervalSince(now)), abs(occurrence.end.timeIntervalSince(now)))
    }

    /// Exposed for tests; production traffic enters through the delegate.
    /// Returns nil while no store is attached (the command waits on disk).
    @discardableResult
    func handle(_ command: WristCommand) -> WristReceipt? {
        guard let store else {
            var queued = inbox
            queued.append(command)
            if queued.count > Self.inboxLimit { queued.removeFirst(queued.count - Self.inboxLimit) }
            inbox = queued
            return nil
        }
        let receipt: WristReceipt
        if ledger.contains(command.id) {
            receipt = WristReceipt(id: command.id, outcome: .duplicate, reason: nil)
        } else {
            receipt = WristCommandApplier.apply(command, to: store, defaults: defaults)
            // A finish or extend that outran its start is answered "not
            // found"; the watch gets the receipt, but the id is deliberately
            // not remembered: the durable copy that arrives after the start
            // must still be allowed to apply.
            let notFound = receipt.outcome == .rejected && receipt.reason == "not found"
            ledger.record(receipt, remember: !notFound)
        }
        logger.info("command \(command.id.uuidString, privacy: .public) → \(receipt.outcome.rawValue, privacy: .public) \(receipt.reason ?? "", privacy: .public)")
        pushSnapshot()
        return receipt
    }

    /// Commands received before a store was attached, kept on disk so a
    /// background launch that never connects a scene cannot lose them.
    private var inbox: [WristCommand] {
        get {
            (defaults.array(forKey: Self.inboxDefaultsKey) as? [Data] ?? [])
                .compactMap { try? WristWire.decode(WristCommand.self, from: $0) }
        }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Self.inboxDefaultsKey)
            } else {
                defaults.set(newValue.compactMap { try? WristWire.encode($0) }, forKey: Self.inboxDefaultsKey)
            }
        }
    }

    var receiptsForTesting: [WristReceipt] { ledger.recent(Self.receiptLimit) }
    var inboxCountForTesting: Int { inbox.count }
}

extension WristBridge: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?
    ) {
        if let error {
            logger.error("activation failed: \(error.localizedDescription, privacy: .public)")
        }
        Task { @MainActor in self.pushSnapshot() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Readiness (paired, app installed) can arrive after a command was
    /// applied; the content-equality check makes an extra push free.
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.pushSnapshot() }
    }

    /// The user switched to another watch: re-activate for the new one.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    /// Pairing / watch-app installation changed: a fresh install needs its
    /// first snapshot.
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.lastSent = nil
            self.pushSnapshot()
        }
    }

    /// The durable path (watch could not reach us, or the fast path failed).
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let command = decodeCommand(userInfo) else { return }
        Task { @MainActor in self.handle(command) }
    }

    /// The fast path: the watch is reachable and waits for the receipt. A
    /// command that arrives before the stores are attached is queued and the
    /// empty reply tells the watch to wait for the snapshot instead.
    nonisolated func session(
        _ session: WCSession, didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let command = decodeCommand(message) else {
            replyHandler([:])
            return
        }
        Task { @MainActor in
            // Stamped before applying: the snapshot pushed by `handle` and
            // every later one are generated at or after this instant.
            let repliedAt = self.now()
            if let receipt = self.handle(command), let data = try? WristWire.encode(receipt) {
                replyHandler([WristWire.receiptKey: data, WristWire.repliedAtKey: repliedAt])
            } else {
                replyHandler([:])
            }
        }
    }

    private nonisolated func decodeCommand(_ payload: [String: Any]) -> WristCommand? {
        guard let data = payload[WristWire.commandKey] as? Data else { return nil }
        guard let command = try? WristWire.decode(WristCommand.self, from: data) else {
            logger.error("undecodable command (\(data.count, privacy: .public) bytes)")
            return nil
        }
        return command
    }
}
