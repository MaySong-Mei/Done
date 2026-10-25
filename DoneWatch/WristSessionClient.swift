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

import Combine
import Foundation
import os
import WatchConnectivity

nonisolated struct WristLocalState: Codable {
    var snapshot: WristSnapshot?
    var pending: [WristPendingCommand] = []
    var dismissed: [UUID] = []
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
    @Published private(set) var dismissed: Set<UUID> = []
    @Published private(set) var isReachable = false

    private let logger = Logger(subsystem: "DoneWatch", category: "Wrist")
    private let persistence: WristLocalPersistence
    private var session: WCSession?
    /// Commands minted before the session finished activating.
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
        dismissed = Set(saved.dismissed)
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
                    end: start.addingTimeInterval(WristTiming.defaultDuration)
                )
            )
        )
    }

    func finish(_ occurrence: WristOccurrence, now: Date = Date()) {
        dismissed.insert(occurrence.eventID)
        send(WristCommand(id: UUID(), issuedAt: now, kind: .finish(eventID: occurrence.eventID, at: now)))
    }

    func extend(_ occurrence: WristOccurrence, now: Date = Date()) {
        send(
            WristCommand(
                id: UUID(), issuedAt: now,
                kind: .extend(eventID: occurrence.eventID, by: WristTiming.extendStep)
            )
        )
    }

    /// Housekeeping the views drive on a slow timer: drop settled or stale
    /// pendings and dismissals that no longer matter.
    func tick(now: Date) {
        let settled = WristStateReducer.settle(pending, snapshot: snapshot, now: now)
        if settled != pending {
            pending = settled
        }
        if let snapshot {
            let timeline = WristStateReducer.overlaid(snapshot, pending: pending, now: now).occurrences
            let pruned = WristStateReducer.pruneDismissed(dismissed, occurrences: timeline, now: now)
            if pruned != dismissed {
                dismissed = pruned
            }
        }
        persist()
    }

    // MARK: Plumbing

    private func send(_ command: WristCommand) {
        pending.append(WristPendingCommand(command: command))
        outbox.append(command)
        flushOutbox()
        persist()
    }

    private func flushOutbox() {
        guard let session, session.activationState == .activated, !outbox.isEmpty else { return }
        for command in outbox {
            do {
                session.transferUserInfo([WristWire.commandKey: try WristWire.encode(command)])
            } catch {
                logger.error("encode failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        outbox.removeAll()
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
        persistence.save(WristLocalState(snapshot: snapshot, pending: pending, dismissed: Array(dismissed)))
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
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.isReachable = reachable }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let data = applicationContext[WristWire.snapshotKey] as? Data
        Task { @MainActor in self.adopt(snapshotData: data) }
    }
}
