//
//  WristAppliedLedger.swift
//  Done
//
//  The ids of wrist commands this phone has already handled, so a redelivery
//  (the watch retrying after a dropped connection) is answered with a
//  `duplicate` receipt instead of applied twice. Bounded and persisted in
//  UserDefaults: it only has to outlive the app process, not a reinstall —
//  a start carries its own event id as a second line of defence.
//

import Foundation

struct WristAppliedLedger {
    static let defaultsKey = "wrist.appliedCommandIDs"
    static let capacity = 256

    private let defaults: UserDefaults
    private var ids: [String]
    private var set: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        set = Set(ids)
    }

    func contains(_ id: UUID) -> Bool {
        set.contains(id.uuidString)
    }

    mutating func insert(_ id: UUID) {
        let key = id.uuidString
        guard set.insert(key).inserted else { return }
        ids.append(key)
        if ids.count > Self.capacity {
            let overflow = ids.count - Self.capacity
            for dropped in ids.prefix(overflow) { set.remove(dropped) }
            ids.removeFirst(overflow)
        }
        defaults.set(ids, forKey: Self.defaultsKey)
    }

    var count: Int { ids.count }
}
