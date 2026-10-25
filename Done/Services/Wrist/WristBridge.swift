//
//  WristBridge.swift
//  Done
//
//  The phone end of the watch link. Owns the `WCSession`, pushes a
//  `WristSnapshot` whenever the calendar or the type catalog changes (and on
//  foreground / activation / watch pairing), and applies incoming
//  `WristCommand`s through `WristCommandApplier` with an idempotency ledger.
//
//  Lifecycle: `activate()` runs from the app delegate at launch so a
//  background launch for an incoming transfer has a delegate in place;
//  `attach(store:templates:)` runs once the SwiftUI scene has built the
//  stores. Commands that arrive in between wait in `inbox`. When the iOS app
//  is not running at all the system queues the transfer and delivers it on
//  the next launch — the watch shows its optimistic state meanwhile.
//

import Combine
import Foundation
import os
import WatchConnectivity

@MainActor
final class WristBridge: NSObject {
    static let receiptLimit = 32
    static let inboxLimit = 64

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Done", category: "Wrist")
    private var session: WCSession?
    private weak var store: EventStore?
    private weak var templates: EventTypeTemplateStore?
    private var subscriptions: [AnyCancellable] = []
    private var inbox: [WristCommand] = []
    private var receipts: [WristReceipt] = []
    private var ledger: WristAppliedLedger
    private(set) var lastSent: WristSnapshot?
    var now: () -> Date = Date.init

    init(ledger: WristAppliedLedger = WristAppliedLedger()) {
        self.ledger = ledger
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
        let queued = inbox
        inbox = []
        for command in queued { handle(command) }
        pushSnapshot()
    }

    /// Build and send the snapshot unless the watch already holds this
    /// content. Safe to call often.
    func pushSnapshot() {
        guard let store, let templates else { return }
        guard let session, session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else { return }
        let snapshot = WristSnapshotBuilder.snapshot(
            events: store.canvasRenderableCalendarEvents,
            templates: templates.templates,
            now: now(),
            calendar: .current,
            language: AppLanguage.current.rawValue,
            receipts: receipts,
            colorHex: { EventTypeTemplateStore.colorHex(for: $0) }
        )
        if let lastSent, lastSent.hasSameContent(as: snapshot) { return }
        do {
            try session.updateApplicationContext([WristWire.snapshotKey: try WristWire.encode(snapshot)])
            lastSent = snapshot
        } catch {
            logger.error("snapshot push failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Exposed for tests; production traffic enters through the delegate.
    /// Returns nil while no store is attached (the command waits in `inbox`).
    @discardableResult
    func handle(_ command: WristCommand) -> WristReceipt? {
        guard let store else {
            inbox.append(command)
            if inbox.count > Self.inboxLimit { inbox.removeFirst(inbox.count - Self.inboxLimit) }
            return nil
        }
        let receipt: WristReceipt
        if ledger.contains(command.id) {
            receipt = WristReceipt(id: command.id, outcome: .duplicate, reason: nil)
        } else {
            receipt = WristCommandApplier.apply(command, to: store)
            ledger.insert(command.id)
        }
        receipts.append(receipt)
        if receipts.count > Self.receiptLimit {
            receipts.removeFirst(receipts.count - Self.receiptLimit)
        }
        logger.info("command \(command.id.uuidString, privacy: .public) → \(receipt.outcome.rawValue, privacy: .public)")
        pushSnapshot()
        return receipt
    }

    var receiptsForTesting: [WristReceipt] { receipts }
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
            if let receipt = self.handle(command), let data = try? WristWire.encode(receipt) {
                replyHandler([WristWire.receiptKey: data])
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
