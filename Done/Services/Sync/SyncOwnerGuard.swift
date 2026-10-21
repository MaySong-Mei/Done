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
//  erase sweeps — and the same uid in `owner.json` beside the data files
//  (`SyncOwnerRecord`; staging QA round 7, finding 2: with the device's
//  preferences daemon refusing writes the key was gone while the data
//  stayed, and a sign-in uploaded the previous account's rows into the new
//  one). Either one names the owner; the file wins when they differ. A session
//  for another uid, while the stored owner still has synced state on this
//  device, stops the engine: no pull, no push, nothing deleted. Data
//  belongs to its account (gh#257, 2026-10-21): the erase lifts it — alone
//  or as "switch to this account" (`SupabaseSyncService.switchToCurrentAccount`)
//  — and "use this device's data for this account"
//  (`adoptLocalDataForCurrentAccount`) lifts it only once the owner was
//  erased on another device (design §10.7 (c)).
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

    /// The owner on record: the file when there is one, else the key.
    static func storedOwner(_ defaults: UserDefaults, record: SyncOwnerRecord?) -> String? {
        record?.read() ?? ownerInDefaults(defaults)
    }

    private static func ownerInDefaults(_ defaults: UserDefaults) -> String? {
        guard let owner = defaults.string(forKey: ownerKey), !owner.isEmpty else { return nil }
        return owner
    }

    static func setOwner(_ uid: String, _ defaults: UserDefaults, record: SyncOwnerRecord?) {
        defaults.set(uid, forKey: ownerKey)
        record?.write(uid)
    }

    /// Design §10.7 (c), the one lift besides the erase and the adopt
    /// action: after the account was erased on another device, the user
    /// chose to upload this device's data into the next account they sign
    /// in with. With no owner on record, that sign-in takes ownership and
    /// its first flush uploads. Only this choice clears the key: under (a)
    /// the guard keeps standing, so a new uid is still blocked (G11 场景二).
    static func clearOwner(_ defaults: UserDefaults, record: SyncOwnerRecord?) {
        defaults.removeObject(forKey: ownerKey)
        record?.remove()
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
    ///
    /// The file is the record. When the key disagrees with it (gone, or
    /// another uid) the defaults cannot be trusted to show the owner's
    /// synced state either — they were lost or rewritten while the data
    /// files stayed — so a different session is blocked on the file's
    /// owner, whose every row then counts as unsynced. A file missing while
    /// the key is there is a device from before the file: the key decides,
    /// and the next owner write adds the file.
    static func evaluate(sessionUid: String, _ defaults: UserDefaults, record: SyncOwnerRecord?) -> SyncOwnerState {
        guard !sessionUid.isEmpty else { return .signedOut }
        let inDefaults = ownerInDefaults(defaults)
        let onFile = record?.read()
        let disagree = onFile != nil && onFile != inDefaults
        if disagree {
            DiagnosticTrail.record("Sync", "sync.owner.record_mismatch file=\(onFile ?? "none") defaults=\(inDefaults ?? "none") session=\(sessionUid)")
        }
        if let owner = onFile ?? inDefaults, owner != sessionUid,
           disagree || hasSyncedState(owner: owner, defaults) {
            return .blocked(owner: owner, session: sessionUid)
        }
        if inDefaults != sessionUid || (record != nil && onFile != sessionUid) {
            setOwner(sessionUid, defaults, record: record)
        }
        return .active(uid: sessionUid)
    }
}

/// `owner.json` in the sync directory, beside the conflict shelf: the owner
/// guard's record kept with the data it guards (see the header). The erase
/// removes it by name and with the directory (`ConflictShelf.wipe()`).
struct SyncOwnerRecord {
    static let filename = "owner.json"
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent(Self.filename) }

    /// The app's record, in `ConflictShelf.productionDirectory` (redirected
    /// under XCTest). Handed in by the app (`ContentView`); an engine built
    /// without one keeps the owner in the defaults key only.
    static var production: SyncOwnerRecord { SyncOwnerRecord(directory: ConflictShelf.productionDirectory) }

    func read() -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uid = object["uid"] as? String, !uid.isEmpty else { return nil }
        return uid
    }

    @discardableResult
    func write(_ uid: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: ["uid": uid])
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            DiagnosticTrail.record("Sync", "sync.owner.record_write_failed")
            return false
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
