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
        let queued = inbox
        inbox = []
        for command in queued { handle(command) }
        pushSnapshot()
    }

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
    /// the full snapshot goes; past it, the step that keeps the most:
    /// today's stats instead of the week's, then no stats, then the
    /// occurrences narrowed to yesterday…tomorrow, then as many of those as
    /// fit, nearest to now first.
    static let byteBudget = 60_000

    static func fitting(
        _ full: WristSnapshot, latestStats: CategoryStatsPayload?, now: Date
    ) -> (WristSnapshot, Data)? {
        var todayStats = full
        todayStats.stats = latestStats.flatMap { WristSnapshotBuilder.weekOnly($0, now: now, todayOnly: true) }
        var noStats = full
        noStats.stats = nil
        let narrow = WristSnapshotBuilder.narrowed(noStats, now: now, calendar: .current)
        for candidate in [full, todayStats, noStats, narrow] {
            guard let data = try? WristWire.encode(candidate) else { continue }
            if data.count <= byteBudget { return (candidate, data) }
        }
        // Last step: the occurrences nearest to now, as many as fit.
        let byDistance = narrow.occurrences.sorted { distance($0, now) < distance($1, now) }
        var low = 0, high = byDistance.count
        var best: (WristSnapshot, Data)?
        while low <= high {
            let mid = (low + high) / 2
            var candidate = narrow
            candidate.occurrences = byDistance.prefix(mid).sorted { $0.start < $1.start }
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
            receipt = WristCommandApplier.apply(command, to: store)
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
