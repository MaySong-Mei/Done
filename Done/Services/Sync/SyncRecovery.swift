//
//  SyncRecovery.swift
//  Done
//
//  The one recovery prompt — design §6.6 一次恢复提示 of
//  Docs/sync/00-realtime-sync-design.md (v1.6, §10.8–10.9, "弹 + 保两份").
//  After a catch-up reaches head, the shelf lines the catch-up wrote are
//  judged once:
//
//    offered   the device's own edit was never confirmed (the copy was not
//              clean against its baseline, or the baseline was `?`); or
//              the copy is NOT an ancestor of the live row
//              (`is_ancestor(copy.vid, live.vid)` false: someone wrote the
//              row after the restore but not on top of this version, or
//              the re-upload that came back is an ancestor of it); or the
//              answer is unknown (either id outside the version log) and
//              the ledger says the copy was pushed after the last kept
//              number (`live.seq < copy.seq`, or clean and `copy.seq > kmin`).
//    not       an ancestor: someone edited on top of it; the line stays on
//              the shelf, unmarked.
//
//  The prompt is one alert, not one per row; relaunches do not repeat it —
//  the undecided offers show as a badge count. The write-back is a
//  conditional write per line on the lease the line recorded (`against`),
//  never refreshed; 0 rows is a lease failure and the line stays with that
//  reason. Before each write the live version it will overwrite is shelved
//  ("keep both"), so a wrong write-back costs a shelf line and no version.
//  Discard drops only the offered lines; later does nothing.
//

import Foundation

/// One line of the read-only "查看列表".
struct SyncRecoveryItem: Identifiable, Equatable {
    let id: String
    let table: String
    let rowId: String
    let title: String
    /// `updated_at` of the shelved copy, when it carried one.
    let lastEditedAt: Date?
    /// Whether the server holds a live row with this id now.
    let serverHasRow: Bool

    static func == (lhs: SyncRecoveryItem, rhs: SyncRecoveryItem) -> Bool { lhs.id == rhs.id }
}

/// What the alert shows: N offered, M of them already past their lease.
struct SyncRecoveryPrompt: Equatable {
    let count: Int
    let leaseFailedCount: Int
    let items: [SyncRecoveryItem]
}

/// The per-line result of a write-back, for the summary line.
struct SyncRecoveryWriteBack: Equatable {
    var accepted = 0
    var leaseFailed = 0
}

@MainActor
final class SyncRecovery {
    private unowned let engine: SupabaseSyncService
    private let gateway: SyncGateway
    private let shelf: ConflictShelf
    /// Applies the rows a write-back landed to local state, the way a pull
    /// would (the puller's applier, cursor untouched).
    var applyLocally: (([SyncFeedRow]) -> Void)?

    init(engine: SupabaseSyncService, gateway: SyncGateway, shelf: ConflictShelf) {
        self.engine = engine
        self.gateway = gateway
        self.shelf = shelf
    }

    // MARK: Reading the shelf

    private var uid: String { engine.userId }

    /// This account's shelf lines the prompt may name: id tables only. The
    /// three one-row tables (user_settings, agent_preferences,
    /// agent_conversations) are settled by the catch-up itself — merged
    /// per key, or POSTed again — and a line for one has no title a user
    /// could recognise (sim QA round 2: agent_preferences listed as the raw
    /// user UUID, counted as a second lost change). Their lines stay on the
    /// shelf; they are never offered, counted, or written back from here.
    private func mine() -> [ConflictShelfEntry] {
        shelf.entries().filter { $0.uid == uid && !SupabaseSyncService.isSingletonTable($0.table) }
    }

    /// Offered lines without a decision: the badge and the sign-out / erase guard.
    var undecidedOffers: [ConflictShelfEntry] {
        mine().filter(\.isUndecidedOffer)
    }

    var hasUndecidedOffers: Bool { !undecidedOffers.isEmpty }

    func refreshBadge() {
        engine.setPendingPromptCount(undecidedOffers.count)
    }

    // MARK: Computing the offer (rule 5)

    /// Judges every catch-up line not yet judged — whichever reset shelved
    /// it: a reset abandoned before head (another epoch change, paused)
    /// leaves its lines for the chain that does reach head — marks the
    /// offered ones, publishes the prompt. Returns nil when nothing is
    /// offered.
    @discardableResult
    func computeOffers() async -> SyncRecoveryPrompt? {
        let candidates = mine().filter { $0.catchup && !$0.offered && $0.resolution == nil }
        guard !candidates.isEmpty else {
            refreshBadge()
            return nil
        }
        var offered: Set<ConflictShelfEntry.DedupeKey> = []
        var unknown = 0
        let kmin = engine.cursor.kmin
        for candidate in candidates {
            let live = engine.baseline.entry(table: candidate.table, id: candidate.id)
            if !candidate.localClean {
                offered.insert(candidate.dedupeKey)
                continue
            }
            guard let copyVid = candidate.localVid, let live, let liveVid = live.vid, live.seq != nil else {
                // No live version to be an ancestor of: offer.
                offered.insert(candidate.dedupeKey)
                continue
            }
            let serverTable = SupabaseSyncService.serverTable(forBaselineTable: candidate.table)
            let answer: Bool?
            do {
                answer = try await gateway.isAncestor(table: serverTable, id: candidate.id, a: copyVid, b: liveVid)
            } catch {
                answer = nil
            }
            switch answer {
            case .some(false):
                offered.insert(candidate.dedupeKey)
            case .some(true):
                break
            case .none:
                unknown += 1
                if Self.ledgerSaysOffer(copySeq: candidate.localSeq, liveSeq: live.seq, copyClean: candidate.localClean, kmin: kmin) {
                    offered.insert(candidate.dedupeKey)
                }
            }
        }
        if unknown > 0 {
            DiagnosticTrail.record("Sync", "sync.ancestry unknown=\(unknown)")
        }
        guard !offered.isEmpty else {
            refreshBadge()
            return nil
        }
        shelf.rewrite { entry in
            guard offered.contains(entry.dedupeKey) else { return entry }
            var next = entry
            next.offered = true
            return next
        }
        let prompt = buildPrompt()
        DiagnosticTrail.record("Sync", "sync.restore.prompt n=\(prompt.count) m=\(prompt.leaseFailedCount)")
        engine.presentRecoveryPrompt(prompt)
        refreshBadge()
        return prompt
    }

    /// The ledger's answer when the version log cannot say (design §6.6
    /// 一次恢复提示, the unknown branch).
    static func ledgerSaysOffer(copySeq: Int64?, liveSeq: Int64?, copyClean: Bool, kmin: Int64?) -> Bool {
        guard let copySeq else { return true }
        if let liveSeq, liveSeq < copySeq { return true }
        if copyClean, let kmin, copySeq > kmin { return true }
        return false
    }

    /// The prompt over the undecided offers: M counts the lines whose lease
    /// is already known to be stale (the live row moved since).
    func buildPrompt() -> SyncRecoveryPrompt {
        let offers = undecidedOffers
        var leaseFailed = 0
        let items = offers.map { entry -> SyncRecoveryItem in
            let live = engine.baseline.entry(table: entry.table, id: entry.id)
            let serverHasRow = live?.seq != nil
            if let against = entry.against, let liveSeq = live?.seq, liveSeq != against.seq { leaseFailed += 1 }
            let title = (entry.row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (entry.row["name"] as? String)
                ?? entry.id
            let edited = (entry.row["updated_at"] as? String).flatMap(Self.parseDate)
            return SyncRecoveryItem(id: "\(entry.table)|\(entry.id)|\(entry.seq)", table: entry.table, rowId: entry.id,
                                    title: title, lastEditedAt: edited, serverHasRow: serverHasRow)
        }
        return SyncRecoveryPrompt(count: offers.count, leaseFailedCount: leaseFailed, items: items)
    }

    private static func parseDate(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: text) { return date }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }

    // MARK: The three buttons

    /// 写回服务器: each offered line is one conditional write on its lease,
    /// the overwritten live version shelved first.
    @discardableResult
    func accept() async -> SyncRecoveryWriteBack {
        var result = SyncRecoveryWriteBack()
        var resolutions: [ConflictShelfEntry.DedupeKey: ConflictShelfResolution] = [:]
        for entry in undecidedOffers {
            let serverTable = SupabaseSyncService.serverTable(forBaselineTable: entry.table)
            let keyColumn = SupabaseSyncService.isSingletonTable(entry.table) ? "user_id" : "id"
            var body = entry.row
            body["seq"] = nil
            body["deleted_at"] = nil
            if let copyVid = entry.localVid { body["restored_from_version_id"] = copyVid }
            let live = engine.baseline.entry(table: entry.table, id: entry.id)
            var landed: [[String: Any]] = []
            do {
                if let against = entry.against, live?.seq != nil {
                    // Keep both: the live version this write overwrites.
                    if let liveRow = engine.localRow(table: entry.table, id: entry.id) {
                        _ = shelf.append(ConflictShelfEntry(uid: uid, table: entry.table, id: entry.id, seq: against.seq,
                                                            reason: .restoreOverwritten, row: liveRow, against: against))
                        shelf.flushDurably()
                    }
                    landed = try await gateway.patchConditional(table: serverTable, keyColumn: keyColumn, key: entry.id,
                                                                baseSeq: against.seq, body: body)
                } else {
                    // The server has no live row: insert where not exists.
                    landed = try await gateway.insertIgnoringDuplicates(table: serverTable, rows: [body])
                }
            } catch {
                DiagnosticTrail.record("Sync", "sync.restore.write_failed table=\(entry.table) id=\(entry.id) code=\(SyncWriteFailure.classify(error).code)")
                continue
            }
            if let row = landed.first, !SupabaseSyncService.isTombstoned(row) {
                resolutions[entry.dedupeKey] = .accepted
                result.accepted += 1
                if let seq = (row["seq"] as? NSNumber)?.int64Value {
                    engine.noteObservedSeq(seq)
                    applyLocally?([SyncFeedRow(table: serverTable, seq: seq, data: row)])
                }
            } else {
                resolutions[entry.dedupeKey] = .leaseFailed
                result.leaseFailed += 1
                DiagnosticTrail.record("Sync", "sync.restore.lease_failed table=\(entry.table) id=\(entry.id)")
            }
        }
        shelf.rewrite { entry in
            guard let resolution = resolutions[entry.dedupeKey] else { return entry }
            var next = entry
            next.resolution = resolution.rawValue
            return next
        }
        DiagnosticTrail.record("Sync", "sync.restore.accept k=\(result.accepted) m=\(result.leaseFailed)")
        engine.presentRecoveryPrompt(nil)
        refreshBadge()
        return result
    }

    /// 丢弃本机修改: only the offered lines.
    @discardableResult
    func discard() -> Int {
        let offered = Set(undecidedOffers.map(\.dedupeKey))
        guard !offered.isEmpty else {
            engine.presentRecoveryPrompt(nil)
            return 0
        }
        shelf.rewrite { entry in
            guard offered.contains(entry.dedupeKey) else { return entry }
            var next = entry
            next.resolution = ConflictShelfResolution.discarded.rawValue
            return next
        }
        DiagnosticTrail.record("Sync", "sync.restore.discard n=\(offered.count)")
        engine.presentRecoveryPrompt(nil)
        refreshBadge()
        return offered.count
    }

    /// The badge's tap (design §6.6: the quiet badge stands for the
    /// undecided offers, and it is how the user gets back to the decision
    /// after 稍后 — QA S4 found it inert). The same prompt over the same
    /// offered lines: nothing is judged again, no lease is refreshed. Nil,
    /// and nothing shown, when no offer is undecided.
    @discardableResult
    func presentAgain() -> SyncRecoveryPrompt? {
        guard hasUndecidedOffers else { return nil }
        let prompt = buildPrompt()
        engine.presentRecoveryPrompt(prompt)
        return prompt
    }

    /// 稍后: the alert goes away, the badge stays.
    func later() {
        engine.presentRecoveryPrompt(nil)
        refreshBadge()
    }
}
