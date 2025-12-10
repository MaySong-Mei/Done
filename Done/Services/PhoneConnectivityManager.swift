//
//  PhoneConnectivityManager.swift
//  Done
//
//  Created by Yifan Mei on 12/10/25.
//

import Foundation
import WatchConnectivity
import Combine

@MainActor
class PhoneConnectivityManager: NSObject, ObservableObject {
    static let shared = PhoneConnectivityManager()

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func syncTemplates(_ templates: [ActivityTemplate]) {
        guard WCSession.default.activationState == .activated else {
            print("WCSession not activated")
            return
        }

        guard let data = try? JSONEncoder().encode(templates) else {
            print("Failed to encode templates")
            return
        }

        let message = SyncMessage(type: .templatesUpdate, data: data)

        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message.toDictionary(), replyHandler: nil) { error in
                print("Error sending templates: \(error.localizedDescription)")
            }
        } else {
            do {
                try WCSession.default.updateApplicationContext(message.toDictionary())
            } catch {
                print("Error updating context: \(error.localizedDescription)")
            }
        }
    }
}

extension PhoneConnectivityManager: WCSessionDelegate {
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        print("WCSession became inactive")
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        print("WCSession deactivated")
        session.activate()
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error = error {
            print("WCSession activation failed: \(error.localizedDescription)")
        } else {
            print("WCSession activated with state: \(activationState.rawValue)")
            Task { @MainActor in
                DataManager.shared.saveTemplates()
            }
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
        case .timeEntrySync:
            if let data = message.data,
               let entry = try? JSONDecoder().decode(TimeEntry.self, from: data) {
                DataManager.shared.addTimeEntry(entry)
            }
        case .requestTemplates:
            syncTemplates(DataManager.shared.templates)
        case .templatesUpdate, .timeEntryUpdate:
            break
        }
    }
}
