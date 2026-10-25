//
//  WristSessionClient.swift
//  DoneWatch
//
//  The watch end of the link. Holds the last snapshot the phone pushed, the
//  commands still in flight, and the sessions the user finished from here
//  (hidden until the phone's clamped end passes — see WristState.swift).
//  Everything is persisted locally so a cold launch renders at once, and the
//  phone's application context is re-read on activation anyway.
//
//  Sending: a command goes out as a message while the phone is reachable
//  (the reply acknowledges it) and as a user-info transfer otherwise. The
//  simulator never delivers transfers and a device delivers them when it
//  gets around to it, so whenever reachability (re)appears every unanswered
//  transfer is also sent as a message — the phone's ledger absorbs the
//  duplicate. Commands for one event keep their order: once one of them is
//  only on the transfer channel, the later ones go through the same
//  resend, so a Finish cannot reach the phone before its Start.
//

import Combine
import Foundation
import os
import WatchConnectivity

nonisolated struct WristLocalState: Codable {
    var snapshot: WristSnapshot?
    var pending: [WristPendingCommand] = []
    var dismissed: [UUID: Date] = [:]
}

nonisolated final class WristLocalPersistence {
    static let `default` = WristLocalPersistence(url: defaultURL)

    private let url: URL

    init(url: URL) {
        self.url = url
    }

    private static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("wrist-state.json")
    }

    func load() -> WristLocalState {
        guard let data = try? Data(contentsOf: url),
              let state = try? WristWire.decode(WristLocalState.self, from: data) else {
            return WristLocalState()
        }
        return state
    }

    func save(_ state: WristLocalState) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try WristWire.encode(state).write(to: url, options: .atomic)
        } catch {
            Logger(subsystem: "DoneWatch", category: "Wrist").error(
                "persist failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

@MainActor
final class WristSessionClient: NSObject, ObservableObject {
    @Published private(set) var snapshot: WristSnapshot?
    @Published private(set) var pending: [WristPendingCommand] = []
    /// Event id → the instant the user tapped Finish.
    @Published private(set) var dismissed: [UUID: Date] = [:]
    @Published private(set) var isReachable = false

    private let logger = Logger(subsystem: "DoneWatch", category: "Wrist")
    private let persistence: WristLocalPersistence
    private var session: WCSession?
    /// Commands minted before the session finished activating, or whose
    /// transfer failed and must go out again.
    private var outbox: [WristCommand] = []
#if DEBUG
    /// Simulator driving without a tap — see `runDebugDriveIfNeeded`.
    private var debugDriveDone = false
#endif

    init(persistence: WristLocalPersistence = .default, activates: Bool = true) {
        self.persistence = persistence
        super.init()
        let saved = persistence.load()
        snapshot = saved.snapshot
        pending = saved.pending
        dismissed = saved.dismissed
        if activates {
            activate()
        }
    }

    func activate() {
        guard session == nil, WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
    }

    func display(now: Date) -> WristDisplayState {
        WristStateReducer.display(snapshot: snapshot, pending: pending, dismissed: dismissed, now: now)
    }

    // MARK: Actions

    func start(_ type: WristType, now: Date = Date()) {
        let start = WristTiming.startInstant(now)
        send(
            WristCommand(
                id: UUID(), issuedAt: now,
                kind: .start(
                    eventID: UUID(), typeTitle: type.title, start: start,
                    end: WristTiming.defaultEnd(start: start)
                )
            )
        )
    }

    func finish(_ occurrence: WristOccurrence, now: Date = Date()) {
        dismissed[occurrence.eventID] = now
        send(
            WristCommand(
                id: UUID(), issuedAt: now,
                kind: .finish(eventID: occurrence.eventID, rangeStart: occurrence.start, at: now)
            )
        )
    }

    func extend(_ occurrence: WristOccurrence, now: Date = Date()) {
        send(
            WristCommand(
                id: UUID(), issuedAt: now,
                kind: .extend(eventID: occurrence.eventID, rangeStart: occurrence.start, by: WristTiming.extendStep)
            )
        )
    }

    /// Housekeeping the views drive on a slow timer: drop settled or stale
    /// pendings and dismissals that no longer matter.
    func tick(now: Date) {
        var changed = false
        let settled = WristStateReducer.settle(pending, snapshot: snapshot, now: now)
        if settled != pending {
            pending = settled
            changed = true
        }
        if let snapshot {
            let timeline = WristStateReducer.overlaid(snapshot, pending: pending, now: now).occurrences
            let pruned = WristStateReducer.pruneDismissed(dismissed, occurrences: timeline, now: now)
            if pruned != dismissed {
                dismissed = pruned
                changed = true
            }
        }
        if changed {
            persist()
        }
    }

    // MARK: Plumbing

    private func send(_ command: WristCommand) {
        pending.append(WristPendingCommand(command: command))
        outbox.append(command)
        flushOutbox()
        persist()
    }

    /// Hand every queued command to the session.
    private func flushOutbox() {
        guard let session, session.activationState == .activated, !outbox.isEmpty else { return }
        let due = outbox
        outbox.removeAll()
        for command in due {
            if session.isReachable {
                // Earlier commands for this event that are only on the
                // transfer channel go first, on this channel, so order holds.
                for earlier in unansweredTransfers(for: command.eventID, before: command) {
                    sendMessage(earlier)
                }
                sendMessage(command)
            } else {
                transfer(command)
            }
        }
    }

    private func unansweredTransfers(for eventID: UUID, before command: WristCommand) -> [WristCommand] {
        pending
            .filter {
                $0.sentAsTransfer && $0.acknowledgedAt == nil && $0.command.eventID == eventID
                    && $0.command.issuedAt < command.issuedAt && $0.command.id != command.id
            }
            .map(\.command)
    }

    private func sendMessage(_ command: WristCommand) {
        guard let session, let data = try? WristWire.encode(command) else { return }
        session.sendMessage([WristWire.commandKey: data], replyHandler: { [weak self] reply in
            let receiptData = reply[WristWire.receiptKey] as? Data
            Task { @MainActor in self?.acknowledge(receiptData: receiptData) }
        }, errorHandler: { [weak self] error in
            let message = error.localizedDescription
            Task { @MainActor in
                self?.logger.notice("sendMessage failed, falling back to transfer: \(message, privacy: .public)")
                self?.transfer(command)
            }
        })
    }

    private func transfer(_ command: WristCommand) {
        guard let session, session.activationState == .activated,
              let data = try? WristWire.encode(command) else { return }
        session.transferUserInfo([WristWire.commandKey: data])
        if let i = pending.firstIndex(where: { $0.command.id == command.id }) {
            pending[i].sentAsTransfer = true
            persist()
        }
    }

    /// Reachability just arrived: send, as messages and in order, every
    /// command that went out as a transfer and has not been answered.
    private func resendUnansweredTransfers() {
        guard let session, session.isReachable else { return }
        let due = pending
            .filter { $0.sentAsTransfer && $0.acknowledgedAt == nil }
            .sorted { $0.command.issuedAt < $1.command.issuedAt }
        for entry in due {
            sendMessage(entry.command)
        }
    }

    /// The phone answered a message. The pending entry stays in the overlay
    /// until a snapshot carries the receipt; this only ends the "sending"
    /// hint.
    private func acknowledge(receiptData: Data?) {
        guard let receiptData, let receipt = try? WristWire.decode(WristReceipt.self, from: receiptData) else { return }
        guard let i = pending.firstIndex(where: { $0.command.id == receipt.id }) else { return }
        if pending[i].acknowledgedAt == nil {
            pending[i].acknowledgedAt = Date()
            persist()
        }
    }

    private func adopt(snapshotData: Data?) {
        guard let snapshotData else { return }
        do {
            snapshot = try WristWire.decode(WristSnapshot.self, from: snapshotData)
        } catch {
            logger.error("undecodable snapshot: \(error.localizedDescription, privacy: .public)")
            return
        }
        tick(now: Date())
        persist()
#if DEBUG
        runDebugDriveIfNeeded()
#endif
    }

#if DEBUG
    /// Launch arguments for end-to-end checks on paired simulators, where
    /// nothing can tap the watch: `-wristAutoStart <type title>` starts that
    /// type as soon as a snapshot lists it; `-wristAutoFinish` finishes the
    /// current session as soon as a snapshot shows one. Each fires once per
    /// launch. Debug builds only.
    private func runDebugDriveIfNeeded() {
        guard !debugDriveDone, let snapshot else { return }
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-wristAutoStart"), index + 1 < arguments.count,
           let type = snapshot.types.first(where: { $0.title == arguments[index + 1] }) {
            debugDriveDone = true
            logger.notice("debug drive: start \(type.title, privacy: .public)")
            start(type)
        } else if arguments.contains("-wristAutoFinish"),
                  case .active(let occurrence, _) = display(now: Date()) {
            debugDriveDone = true
            logger.notice("debug drive: finish \(occurrence.title, privacy: .public)")
            finish(occurrence)
        }
    }
#endif

    private func persist() {
        persistence.save(WristLocalState(snapshot: snapshot, pending: pending, dismissed: dismissed))
    }
}

extension WristSessionClient: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?
    ) {
        if let error {
            logger.error("activation failed: \(error.localizedDescription, privacy: .public)")
        }
        let data = session.receivedApplicationContext[WristWire.snapshotKey] as? Data
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
            self.adopt(snapshotData: data)
            self.flushOutbox()
            self.resendUnansweredTransfers()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
            self.flushOutbox()
            self.resendUnansweredTransfers()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let data = applicationContext[WristWire.snapshotKey] as? Data
        Task { @MainActor in self.adopt(snapshotData: data) }
    }

    /// A failed transfer goes out again at once (and again when reachability
    /// changes); a finished one needs nothing — its receipt rides the next
    /// snapshot.
    nonisolated func session(
        _ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?
    ) {
        guard let error else { return }
        let data = userInfoTransfer.userInfo[WristWire.commandKey] as? Data
        let message = error.localizedDescription
        Task { @MainActor in
            self.logger.error("transfer failed: \(message, privacy: .public)")
            if let data, let command = try? WristWire.decode(WristCommand.self, from: data) {
                self.outbox.append(command)
                self.flushOutbox()
            }
        }
    }
}
