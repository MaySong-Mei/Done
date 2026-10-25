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
//  Sending: every pending entry with no `sentAt` is due. One rule
//  (`WristStateReducer.channel`) says whether it may go now and on which
//  channel: a message while the phone is reachable (the reply acknowledges
//  it), a user-info transfer otherwise. Commands for one event keep their
//  order because a later one waits behind an unanswered earlier one unless
//  both ride the transfer channel, which is FIFO. The simulator never
//  delivers transfers and a device delivers them when it gets around to it,
//  so whenever reachability (re)appears every unanswered transfer is also
//  sent as a message, in order — the phone's ledger absorbs the duplicate.
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
    /// Sessions finished from this watch (event id → tap instant): hidden
    /// while the phone still projects them running, and ended at the tap.
    @Published private(set) var dismissed: [UUID: Date] = [:]
    @Published private(set) var isReachable = false

    private let logger = Logger(subsystem: "DoneWatch", category: "Wrist")
    private let persistence: WristLocalPersistence
    private var session: WCSession?
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
        pump()
        persist()
    }

    /// Hand every due entry the channel rule allows to the session, oldest
    /// first so a held entry also holds the ones behind it.
    private func pump() {
        guard let session, session.activationState == .activated else { return }
        let order = pending.indices.sorted { pending[$0].command.issuedAt < pending[$1].command.issuedAt }
        for i in order where pending[i].sentAt == nil {
            guard let channel = WristStateReducer.channel(
                for: pending[i], among: pending, reachable: session.isReachable
            ) else { continue }
            switch channel {
            case .message:
                sendMessage(pending[i].command)
                pending[i].sentAt = Date()
            case .transfer:
                if transfer(pending[i].command) {
                    pending[i].sentAt = Date()
                    pending[i].sentAsTransfer = true
                }
            }
        }
    }

    private func sendMessage(_ command: WristCommand) {
        guard let session, let data = try? WristWire.encode(command) else { return }
        session.sendMessage([WristWire.commandKey: data], replyHandler: { [weak self] reply in
            let receiptData = reply[WristWire.receiptKey] as? Data
            let repliedAt = reply[WristWire.repliedAtKey] as? Date
            Task { @MainActor in self?.acknowledge(receiptData: receiptData, repliedAt: repliedAt) }
        }, errorHandler: { [weak self] error in
            let message = error.localizedDescription
            Task { @MainActor in self?.messageFailed(command, message) }
        })
    }

    /// The message did not get through: the entry moves to the transfer
    /// channel (or back to due if the session cannot take a transfer yet).
    private func messageFailed(_ command: WristCommand, _ message: String) {
        logger.notice("sendMessage failed, falling back to transfer: \(message, privacy: .public)")
        guard let i = pending.firstIndex(where: { $0.command.id == command.id }) else { return }
        if transfer(command) {
            pending[i].sentAsTransfer = true
        } else {
            pending[i].sentAt = nil
        }
        pump()
        persist()
    }

    @discardableResult
    private func transfer(_ command: WristCommand) -> Bool {
        guard let session, session.activationState == .activated,
              let data = try? WristWire.encode(command) else { return false }
        session.transferUserInfo([WristWire.commandKey: data])
        return true
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

    /// A transfer failed: it and every transfer behind it for the same
    /// event go back to due, so they leave again in order.
    private func transferFailed(_ command: WristCommand) {
        for i in pending.indices
        where pending[i].command.eventID == command.eventID && pending[i].sentAsTransfer
            && pending[i].acknowledgedAt == nil && pending[i].command.issuedAt >= command.issuedAt {
            pending[i].sentAt = nil
            pending[i].sentAsTransfer = false
        }
        pump()
        persist()
    }

    /// The phone answered a message. An applied command stays in the
    /// overlay until a snapshot reflects it; a rejected or duplicate one is
    /// dropped now. Either way the next command for that event may go.
    private func acknowledge(receiptData: Data?, repliedAt: Date?) {
        guard let receiptData, let receipt = try? WristWire.decode(WristReceipt.self, from: receiptData) else { return }
        let updated = WristStateReducer.acknowledge(pending, receipt: receipt, repliedAt: repliedAt, now: Date())
        guard updated != pending else { return }
        pending = updated
        pump()
        persist()
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
        // A settled entry may have been gating later ones for its event.
        pump()
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
        persistence.save(
            WristLocalState(snapshot: snapshot, pending: pending, dismissed: dismissed)
        )
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
            self.pending = WristStateReducer.resetMessagesFromAnEarlierProcess(self.pending)
            self.adopt(snapshotData: data)
            self.pump()
            self.resendUnansweredTransfers()
            self.persist()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
            self.pump()
            self.resendUnansweredTransfers()
            self.persist()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let data = applicationContext[WristWire.snapshotKey] as? Data
        Task { @MainActor in self.adopt(snapshotData: data) }
    }

    /// A failed transfer goes out again, with everything queued behind it
    /// for the same event; a finished one needs nothing — its receipt rides
    /// the next snapshot.
    nonisolated func session(
        _ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?
    ) {
        guard let error else { return }
        let data = userInfoTransfer.userInfo[WristWire.commandKey] as? Data
        let message = error.localizedDescription
        Task { @MainActor in
            self.logger.error("transfer failed: \(message, privacy: .public)")
            if let data, let command = try? WristWire.decode(WristCommand.self, from: data) {
                self.transferFailed(command)
            }
        }
    }
}
