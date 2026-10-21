//
//  SyncCatchUp.swift
//  Done
//
//  The device's catch-up after the server went backwards — design §6.6
//  设备追平 of Docs/sync/00-realtime-sync-design.md (v1.6, §10.8). Three
//  pieces, none of them touching the §6 decision core:
//
//    reset     at a chain boundary (the puller saw a new epoch): the cursor
//              is dropped, every baseline entry keeps its hash / seq /
//              version id and gains the stale marker, the in-memory tables
//              are emptied, and `kmin` is taken from the restore ledger —
//              the smallest kept_max among the records later than the
//              device's old epoch, and the min of that with the previous
//              kmin when stale entries from an earlier reset are still
//              waiting (§6.6 恢复帐本: `ledgerLast` and `noMinCarry` are the
//              two mutants that hide a lost version).
//    decide    the pre-rules a LIVE incoming row meets on a STALE entry with
//              a local row present (rules 1 and 2): server authoritative —
//              same bytes settle, a clean local copy goes to the shelf and
//              the row is adopted; an unpushed local edit is kept only when
//              the incoming row is the version the edit chain started from
//              (the old baseline, the recorded origin) or an ancestor of it
//              (`is_ancestor`, pre-queried by the puller), otherwise it goes
//              to the shelf too. A tombstone, or an absent local row, is
//              handed to the §6 table with the entry's seq hidden, so the
//              skip row cannot fire (rule 3 is the §6 pending-delete row).
//    finalize  at head: every entry still stale was not seen on the new
//              timeline. A row the device still holds is re-uploaded with
//              `parent_version_id` = the entry's version id (rule 4: the
//              entry keeps its marker and loses its seq, so the flush POSTs
//              it and, until that lands, a peer's re-upload still wins); a
//              row the device deleted becomes a dead-row insert (rule 3's
//              second half).
//
//  The shelf line a catch-up writes carries what the prompt needs
//  (`SyncRecovery`): the local copy's version id and seq, whether it was
//  clean, and the version it lost to (`against`).
//

import Foundation

/// What the applier is handed for one page of a catch-up.
struct SyncCatchUpContext {
    /// The epoch of the reset this page belongs to; stamped on shelf lines.
    let epoch: String
    /// `is_ancestor(vid_in, origin.vid)` for the rows the puller asked
    /// about before the page: `.some(true)` / `.some(false)`, `.some(nil)`
    /// for an unknown answer; absent when not asked.
    var ancestry: [SyncBaselineKey: Bool?] = [:]

    init(epoch: String, ancestry: [SyncBaselineKey: Bool?] = [:]) {
        self.epoch = epoch
        self.ancestry = ancestry
    }

    /// True only when the oracle answered true.
    func isAncestor(_ key: SyncBaselineKey) -> Bool {
        if case .some(.some(true)) = ancestry[key] { return true }
        return false
    }
}

enum SyncCatchUpAction: String, Equatable {
    /// Same bytes on both sides: the entry is settled, nothing moves.
    case same
    /// Server authoritative: the local copy goes to the shelf, the
    /// incoming row is adopted.
    case shelveAndAdopt = "shelved"
    /// Origin fast-forward: the local edit is kept and goes out on the
    /// incoming seq; nothing is shelved.
    case keepOrigin = "kept_origin"
}

struct SyncCatchUpDecision: Equatable {
    let action: SyncCatchUpAction
    /// The entry after the row: `(h_in, seq_in, vid_in)`, marker cleared.
    let entry: SyncBaselineEntry
    /// Whether the local copy equalled its baseline (a confirmed version)
    /// when it was shelved; false is the user's own unconfirmed edit.
    let localClean: Bool
}

@MainActor
enum SyncCatchUp {

    // MARK: Rules 1 and 2

    /// - Parameters:
    ///   - incomingHash / incomingSeq / incomingVid: the live incoming row.
    ///   - localHash: the local row (present).
    ///   - base: the stale entry.
    ///   - origin: the recorded origin version id, if any; the old
    ///     baseline's version id stands in for it.
    ///   - ancestorOfOrigin: `is_ancestor(vid_in, origin.vid)` answered true.
    static func decide(
        incomingHash: String,
        incomingSeq: Int64,
        incomingVid: String?,
        localHash: String,
        base: SyncBaselineEntry,
        origin: String?,
        ancestorOfOrigin: Bool
    ) -> SyncCatchUpDecision {
        let written = SyncBaselineEntry(hash: incomingHash, seq: incomingSeq, vid: incomingVid, stale: false)
        if localHash == incomingHash {
            return SyncCatchUpDecision(action: .same, entry: written, localClean: true)
        }
        let baseKnown = !base.isUnknown
        let localClean = baseKnown && localHash == base.hash
        if localClean {
            return SyncCatchUpDecision(action: .shelveAndAdopt, entry: written, localClean: true)
        }
        // An unpushed local edit: fast-forward when the incoming row is
        // where the edit chain started, or older than that.
        if baseKnown, incomingHash == base.hash {
            return SyncCatchUpDecision(action: .keepOrigin, entry: written, localClean: false)
        }
        if let incomingVid, let baseVid = base.vid, incomingVid == baseVid {
            return SyncCatchUpDecision(action: .keepOrigin, entry: written, localClean: false)
        }
        if let incomingVid, let originVid = origin ?? base.vid, incomingVid == originVid {
            return SyncCatchUpDecision(action: .keepOrigin, entry: written, localClean: false)
        }
        if ancestorOfOrigin {
            return SyncCatchUpDecision(action: .keepOrigin, entry: written, localClean: false)
        }
        return SyncCatchUpDecision(action: .shelveAndAdopt, entry: written, localClean: false)
    }

    /// Whether the puller should ask `is_ancestor(vid_in, origin)` for
    /// this row before the page: a stale entry whose incoming version is
    /// neither the baseline's nor the origin's. The answer only matters on
    /// the dirty branch, which the puller cannot know without hashing, so
    /// it asks for every such row; a catch-up is rare.
    static func ancestryQuestion(base: SyncBaselineEntry?, origin: String?, incomingVid: String?) -> (a: String, b: String)? {
        guard let base, base.stale, let incomingVid else { return nil }
        if let baseVid = base.vid, baseVid == incomingVid { return nil }
        guard let originVid = origin ?? base.vid, originVid != incomingVid else { return nil }
        return (incomingVid, originVid)
    }

    // MARK: Reset

    /// The ledger's minimum kept_max among the records later than the
    /// device's old epoch; nil (∞) when there is none. A device whose old
    /// epoch is not in the ledger (the seeded epoch, or an epoch the ledger
    /// never recorded) treats every record as later.
    static func kmin(ledger: [SyncRestoreRecord], oldEpoch: String?) -> Int64? {
        var records = ledger
        if let oldEpoch, let index = ledger.lastIndex(where: { $0.epoch == oldEpoch }) {
            records = Array(ledger[(index + 1)...])
        }
        return records.map(\.keptMax).min()
    }

    /// The reset itself; returns the kmin recorded.
    @discardableResult
    static func reset(engine: SupabaseSyncService, newEpoch: String, ledger: [SyncRestoreRecord]) -> Int64? {
        let oldEpoch = engine.cursor.epoch
        var kmin = Self.kmin(ledger: ledger, oldEpoch: oldEpoch)
        if engine.baseline.hasStaleEntries, let previous = engine.cursor.kmin {
            kmin = min(kmin ?? previous, previous)
        }
        engine.cursor.reset(newEpoch: newEpoch, kmin: kmin, baseline: engine.baseline)
        engine.clearInMemoryForReset()
        DiagnosticTrail.record("Sync", "sync.reset reason=epoch kmin=\(kmin.map(String.init) ?? "inf") old=\(oldEpoch ?? "none") new=\(newEpoch)")
        return kmin
    }

    // MARK: Finalize (rules 3b and 4)

    struct FinalizeOutcome {
        var reuploaded: [SyncBaselineKey] = []
        var deadInserted: [SyncBaselineKey] = []
    }

    /// At head: the entries still stale were not on the new timeline.
    static func finalize(engine: SupabaseSyncService, gateway: SyncGateway) async -> FinalizeOutcome {
        var outcome = FinalizeOutcome()
        let baseline = engine.baseline
        for table in SyncBaselineStore.allTables where table != SyncBaselineStore.settingsTable {
            for (id, entry) in baseline.staleEntries(table: table).sorted(by: { $0.key < $1.key }) {
                let key = SyncBaselineKey(table: table, id: id)
                if engine.localRow(table: table, id: id) != nil {
                    // Rule 4: the flush POSTs a seq-less entry; the marker
                    // stays so a peer's re-upload arriving first still wins.
                    baseline.setEntry(SyncBaselineEntry(hash: entry.hash, seq: nil, vid: entry.vid, stale: true), table: table, id: id)
                    if let vid = entry.vid { engine.reuploadParents[key] = vid }
                    engine.markNeedsFlush(table)
                    outcome.reuploaded.append(key)
                    DiagnosticTrail.record("Sync", "sync.catchup.reupload table=\(table) id=\(id)")
                } else {
                    // Rule 3, second half: the device deleted it and the
                    // server no longer has it — a dead row, so a peer's
                    // later re-upload meets a tombstone instead of reviving it.
                    let serverTable = SupabaseSyncService.serverTable(forBaselineTable: table)
                    let keyColumn = SupabaseSyncService.isSingletonTable(table) ? "user_id" : "id"
                    var row: [String: Any] = [
                        keyColumn: id,
                        "user_id": engine.userId,
                        "deleted_at": SupabaseSyncService.isoString(engine.scheduler.now()),
                    ]
                    if let vid = entry.vid { row["parent_version_id"] = vid }
                    if table == "calendar_events" { row["kind"] = "calendar" }
                    if table == "events" { row["kind"] = "todo" }
                    do {
                        _ = try await gateway.insertIgnoringDuplicates(table: serverTable, rows: [row])
                        DiagnosticTrail.record("Sync", "sync.catchup.dead_insert table=\(table) id=\(id)")
                    } catch {
                        DiagnosticTrail.record("Sync", "sync.catchup.dead_insert_failed table=\(table) id=\(id) code=\(SyncWriteFailure.classify(error).code)")
                    }
                    baseline.removeEntry(table: table, id: id)
                    baseline.removeOrigin(table: table, id: id)
                    outcome.deadInserted.append(key)
                }
            }
        }
        if baseline.settingsStale {
            // Unseen settings row: the server has none. A seq-less baseline
            // with no key hashes reads every key as changed, so the next
            // settings flush POSTs the row and the response writes the keys.
            if case .versioned(_, _, let zone)? = baseline.settings {
                baseline.setSettings(.versioned(seq: nil, keys: [:], zone: zone))
            } else {
                baseline.setSettingsStale(false)
            }
            engine.markNeedsFlush(SyncBaselineStore.settingsTable)
        }
        // Every table may hold rows the pre-rules kept with a local edit
        // (rule 2) or re-uploads (rule 4), and the reset emptied the flush
        // flags: the head flush that follows covers all of them (a clean
        // table sends nothing).
        for table in SyncBaselineStore.allTables { engine.markNeedsFlush(table) }
        baseline.persist()
        return outcome
    }
}
