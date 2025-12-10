//
//  SyncMessage.swift
//  Done
//
//  Created by Yifan Mei on 12/10/25.
//

import Foundation

enum SyncMessageType: String, Codable {
    case templatesUpdate
    case timeEntryUpdate
    case timeEntrySync
    case requestTemplates
}

struct SyncMessage: Codable, Sendable {
    let type: SyncMessageType
    let data: Data?
    let timestamp: Date

    nonisolated init(type: SyncMessageType, data: Data? = nil, timestamp: Date = Date()) {
        self.type = type
        self.data = data
        self.timestamp = timestamp
    }

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "type": type.rawValue,
            "timestamp": timestamp.timeIntervalSince1970
        ]
        if let data = data {
            dict["data"] = data
        }
        return dict
    }

    nonisolated static func fromDictionary(_ dict: [String: Any]) -> SyncMessage? {
        guard
            let typeString = dict["type"] as? String,
            let type = SyncMessageType(rawValue: typeString),
            let timestampInterval = dict["timestamp"] as? TimeInterval
        else {
            return nil
        }

        let data = dict["data"] as? Data
        let timestamp = Date(timeIntervalSince1970: timestampInterval)

        return SyncMessage(type: type, data: data, timestamp: timestamp)
    }
}
