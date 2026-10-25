//
//  WristAppliedLedger.swift
//  Done
//
//  The receipts of wrist commands this phone has already handled. A
//  redelivery (the watch retrying after a dropped connection, or re-sending
//  from a new process) is answered `duplicate` instead of applied twice, and
//  the most recent receipts ride every snapshot so the watch can settle its
//  pending commands even when the phone process that applied them is gone.
//  Bounded and persisted in UserDefaults: it only has to outlive the app
//  process, not a reinstall — a start carries its own event id as a second
//  line of defence.
//

import Foundation

nonisolated struct WristAppliedLedger {
    static let defaultsKey = "wrist.appliedReceipts"
    static let capacity = 256

    private struct Entry: Codable {
        var receipt: WristReceipt
        var remembered: Bool
    }

    private let defaults: UserDefaults
    private var entries: [Entry]
    private var ids: Set<UUID>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = (defaults.data(forKey: Self.defaultsKey))
            .flatMap { try? WristWire.decode([Entry].self, from: $0) } ?? []
        ids = Set(entries.filter(\.remembered).map(\.receipt.id))
    }

    func contains(_ id: UUID) -> Bool {
        ids.contains(id)
    }

    /// The newest `limit` receipts, oldest first.
    func recent(_ limit: Int) -> [WristReceipt] {
        entries.suffix(limit).map(\.receipt)
    }

    /// Remembers a receipt; a second receipt for a remembered id is ignored.
    /// `remember: false` carries the receipt to the watch without counting
    /// the command as seen — a later delivery of it may still apply.
    mutating func record(_ receipt: WristReceipt, remember: Bool = true) {
        if remember {
            guard ids.insert(receipt.id).inserted else { return }
        }
        entries.append(Entry(receipt: receipt, remembered: remember))
        if entries.count > Self.capacity {
            let overflow = entries.count - Self.capacity
            for dropped in entries.prefix(overflow) where dropped.remembered { ids.remove(dropped.receipt.id) }
            entries.removeFirst(overflow)
        }
        if let data = try? WristWire.encode(entries) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    var count: Int { entries.count }
}
