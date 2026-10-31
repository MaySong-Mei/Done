//
//  MacTestStore.swift
//  DoneMacTests
//
//  One way to build the store under test: a `MacEventStore` over a fresh,
//  isolated shared `EventStore` — its own UserDefaults suite and its own
//  ephemeral storage directory, so no test can reach the device's data or
//  another test's. Replaces the per-file `MacPersistence` rigs that retired
//  with the Mac's own truth layer (gh#257 catch-up).
//

import Foundation
@testable import Done

@MainActor
enum MacTestStore {
    /// `seed` lands as the shared store's starting rows — the "already on
    /// disk at launch" state — so the adapter adopts them without emitting a
    /// delta, exactly as it does for a real launch.
    static func make(
        seed: [Event] = [],
        bill: MacWorkBill? = nil,
        calendar: Calendar = .current
    ) -> MacEventStore {
        let defaults = UserDefaults(suiteName: "DoneMacTests-\(UUID().uuidString)")!
        let shared = EventStore(defaults: defaults, storage: .ephemeral(id: UUID()),
                                seedsSampleDataIfEmpty: false)
        if !seed.isEmpty { shared.rawCalendarEvents = seed }
        return MacEventStore(shared: shared, bill: bill ?? MacWorkBill(), calendar: calendar)
    }
}
