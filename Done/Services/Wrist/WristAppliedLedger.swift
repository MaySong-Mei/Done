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

    private let defaults: UserDefaults
    private var receipts: [WristReceipt]
    private var ids: Set<UUID>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        receipts = (defaults.data(forKey: Self.defaultsKey))
            .flatMap { try? WristWire.decode([WristReceipt].self, from: $0) } ?? []
        ids = Set(receipts.map(\.id))
    }

    func contains(_ id: UUID) -> Bool {
        ids.contains(id)
    }

    /// The newest `limit` receipts, oldest first.
    func recent(_ limit: Int) -> [WristReceipt] {
        Array(receipts.suffix(limit))
    }

    /// Remembers a receipt; a second receipt for the same id is ignored.
    mutating func record(_ receipt: WristReceipt) {
        guard ids.insert(receipt.id).inserted else { return }
        receipts.append(receipt)
        if receipts.count > Self.capacity {
            let overflow = receipts.count - Self.capacity
            for dropped in receipts.prefix(overflow) { ids.remove(dropped.id) }
            receipts.removeFirst(overflow)
        }
        if let data = try? WristWire.encode(receipts) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    var count: Int { receipts.count }
}
