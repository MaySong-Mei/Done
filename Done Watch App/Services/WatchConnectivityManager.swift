//
//  WatchConnectivityManager.swift
//  Done Watch App
//
//  Created by Yifan Mei on 12/10/25.
//

import Foundation
import WatchConnectivity
import Combine

@MainActor
class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func sendTimeEntry(_ entry: TimeEntry) {
        guard WCSession.default.isReachable else {
            print("iPhone not reachable, will sync later")
            return
        }

        guard let data = try? JSONEncoder().encode(entry) else {
            print("Failed to encode time entry")
            return
        }

        let message = SyncMessage(type: .timeEntrySync, data: data)
        WCSession.default.sendMessage(message.toDictionary(), replyHandler: nil) { error in
            print("Error sending time entry: \(error.localizedDescription)")
        }
    }

    func requestTemplates() {
        guard WCSession.default.isReachable else {
            print("iPhone not reachable")
            return
        }

        let message = SyncMessage(type: .requestTemplates)
        WCSession.default.sendMessage(message.toDictionary(), replyHandler: nil) { error in
            print("Error requesting templates: \(error.localizedDescription)")
        }
    }
}

extension WatchConnectivityManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error = error {
            print("WCSession activation failed: \(error.localizedDescription)")
        } else {
            print("WCSession activated with state: \(activationState.rawValue)")
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let syncMessage = SyncMessage.fromDictionary(message) else {
            print("Failed to parse sync message")
            return
        }

        Task { @MainActor in
            handleSyncMessage(syncMessage)
        }
    }

    @MainActor
    private func handleSyncMessage(_ message: SyncMessage) {
        switch message.type {
        case .templatesUpdate:
            if let data = message.data,
               let templates = try? JSONDecoder().decode([ActivityTemplate].self, from: data) {
                DataManager.shared.updateTemplates(templates)
            }
        case .timeEntryUpdate, .timeEntrySync, .requestTemplates:
            break
        }
    }
}
