//
//  SyncOwnerGuard.swift
//  Done
//
//  Whose data this device holds (survey S5, gap G11; design §6.4 所有者守卫,
//  I11). A plain sign-out keeps local data, and a new uid has no cursor and
//  no baseline, so without this every row of account A looks new to account
//  B: a full pull mixes B's rows in and the flush POSTs A's rows into B.
//
//  The owner is a uid under `syncHashes.ownerUid` — inside the prefix the
//  erase sweeps, so an erase clears it with no purge of its own. A session
//  for another uid, while the stored owner still has synced state on this
//  device, stops the engine: no pull, no push, nothing deleted. Only the
//  erase or an explicit "use this device's data for this account" action
//  (`SupabaseSyncService.adoptLocalDataForCurrentAccount`) lifts it.
//

import Foundation

enum SyncOwnerState: Equatable {
    /// No session.
    case signedOut
    /// The session's uid owns the local data; the engine may run.
    case active(uid: String)
    /// The local data belongs to `owner`; the session is `session`. The
    /// engine neither pulls nor pushes until the user decides.
    case blocked(owner: String, session: String)

    var allowsSync: Bool {
        if case .active = self { return true }
        return false
    }
}

enum SyncOwnerGuard {
    nonisolated static let ownerKey = SyncBaselineStore.keyPrefix + "ownerUid"

    static func storedOwner(_ defaults: UserDefaults) -> String? {
        guard let owner = defaults.string(forKey: ownerKey), !owner.isEmpty else { return nil }
        return owner
    }

    static func setOwner(_ uid: String, _ defaults: UserDefaults) {
        defaults.set(uid, forKey: ownerKey)
    }

    /// Whether `owner` left synced state on this device: a baseline, a
    /// cursor or a rejected set under its own `syncHashes.<owner>.` keys.
    /// That state is the evidence that local rows were synced as `owner`.
    static func hasSyncedState(owner: String, _ defaults: UserDefaults) -> Bool {
        let prefix = "\(SyncBaselineStore.keyPrefix)\(owner)."
        return defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix(prefix) }
    }

    /// The decision at sign-in. Unset or same owner → the session owns the
    /// data (and the key is written). A different owner with synced state
    /// → blocked. A different owner that never synced anything here → the
    /// data was never claimed by it; the session takes ownership.
    static func evaluate(sessionUid: String, _ defaults: UserDefaults) -> SyncOwnerState {
        guard !sessionUid.isEmpty else { return .signedOut }
        if let owner = storedOwner(defaults), owner != sessionUid,
           hasSyncedState(owner: owner, defaults) {
            return .blocked(owner: owner, session: sessionUid)
        }
        if storedOwner(defaults) != sessionUid { setOwner(sessionUid, defaults) }
        return .active(uid: sessionUid)
    }
}
