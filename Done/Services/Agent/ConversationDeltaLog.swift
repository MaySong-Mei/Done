//
//  ConversationDeltaLog.swift
//  Done
//
//  gh#219 — the write-ahead half of agent-chat persistence.
//
//  WHY THIS EXISTS
//  ---------------
//  `AgentConversationRepository.replaceAll` re-encoded and `rename(2)`'d the
//  ENTIRE `[AgentConversation]` array through `AtomicValueFile` on every
//  appended `ChatMessage` — 3–8 times per agent turn, on a history that only
//  grows (sized at 351 KB on the dogfood device). That is the exact shape an
//  append log removes: appending a message should write ONE line, not rewrite
//  the whole array.
//
//  This file is the append log. `AtomicValueFile` is KEPT as the checkpoint
//  (`conversations.json`, its format byte-for-byte unchanged) and carries all
//  of its hard-won freeze / quarantine / witness / legacy-migration machinery;
//  this log holds only the DELTAS accumulated on top of that checkpoint since
//  it was last written. The folded state = checkpoint ⊕ log. A checkpoint is
//  rewritten (the whole array, atomically) only when the log crosses a byte
//  bound — rarely — exactly the compaction shape `SpikeRunStore` proved.
//
//  RECORD SHAPE, AND WHY IT FOLDS EXACTLY (RED LINE 4)
//  --------------------------------------------------
//  Each record carries the FULL ordered id list (`order`) plus the bodies of
//  the conversations whose value differs from the prior folded state
//  (`changed`). `order` is the authority for membership and position; `changed`
//  is last-write-wins by id. The fold is `order.compactMap { latestBody[$0] }`.
//
//  Two properties this buys, both load-bearing:
//   * `fold(base, records) == the array the whole-value path would have
//     written` — proven in `ConversationDeltaFold.fold`'s doc — so a relaunch
//     reconstructs byte-identical state.
//   * the fold is IDEMPOTENT against a checkpoint that already incorporates it:
//     replaying a delta over a base that already equals its result yields the
//     result again. That is what makes checkpoint ordering crash-safe — a kill
//     between "write the checkpoint" and "clear the log" replays stale deltas
//     over the new checkpoint and lands on the same state, never a double
//     application.
//
//  CRASH SAFETY OF THE APPEND ITSELF
//  ---------------------------------
//  An append only ever appends confirmed bytes — it never rewrites a byte of a
//  prior record — so a kill mid-append can damage only the tail.
//  `loadRecords` drops a torn tail (a final segment with no terminating
//  newline: a write that never completed, hence was never confirmed) and
//  requires every COMPLETE (newline-terminated) segment to decode. A complete
//  segment that will not decode is genuine corruption, not a torn write, and
//  raises `fault` rather than being silently skipped — the same posture
//  `AtomicValueFile` takes on a corrupt primary, and the same reason: an
//  unreadable history that presents as a shorter one is a silent loss that
//  then gets mirrored to the cloud (RED LINE 3).
//
//  The two rules stay compatible because `append` TRUNCATES a torn tail (never
//  fsync-confirmed, so safe to drop) before writing, rather than healing it
//  into a complete line. That is what lets a post-crash append survive — its
//  record starts on a clean boundary — while keeping the strict "a complete
//  segment must decode" rule free of false positives.
//

import Foundation
import os

private let deltaLogLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Done",
    category: "Persistence"
)

private func deltaLogTrail(_ message: String) {
    deltaLogLogger.log("\(message, privacy: .public)")
    DiagnosticTrail.record("Persistence", message)
}

private func deltaLogTrailError(_ message: String) {
    deltaLogLogger.error("\(message, privacy: .public)")
    DiagnosticTrail.record("Persistence", "ERROR " + message)
}

// MARK: - Record

/// One appended delta. `v` is the schema flag (the straddle-heal precedent:
/// a version stamp so an older reader can refuse a shape it does not know
/// rather than mis-folding it). `order` is the full ordered id list after the
/// delta; `changed` holds the bodies that differ from the prior folded state.
struct ConversationDeltaRecord: Codable, Equatable {
    static let currentVersion = 1

    var v: Int
    var order: [UUID]
    var changed: [AgentConversation]

    init(order: [UUID], changed: [AgentConversation], v: Int = ConversationDeltaRecord.currentVersion) {
        self.v = v
        self.order = order
        self.changed = changed
    }
}

// MARK: - Fold (pure)

enum ConversationDeltaFold {
    /// Reconstruct the array from a checkpoint `base` and the log `records`,
    /// replayed in order.
    ///
    /// EXACTNESS (RED LINE 4). Let `prev_k` be the folded state before record
    /// k and `rows_k` the array `replaceAll` was handed at step k. Record k is
    /// built with `order = rows_k.map(id)` and `changed = rows_k.filter { body
    /// differs from prev_k[id] }`. Replaying all records over the original
    /// `base`:
    ///   * final `order` = `rows_n.map(id)` (last record wins);
    ///   * for an id in that order, its body is the LAST record that upserted
    ///     it, else `base[id]`.
    /// The last record to upsert an id necessarily carries `rows_n[id]`: any
    /// later change to that id would itself be a later upsert (the diff is
    /// against the running folded state, so every body change is captured), and
    /// if the id never changed after step m then `rows_n[id] == rows_m[id]`. An
    /// id never upserted by any record is one whose body equalled `base[id]`
    /// throughout. Either way the fold reproduces `rows_n` element for element.
    ///
    /// IDEMPOTENCE. If `base` already equals `fold(oldBase, records)`, then
    /// `fold(base, records) == base`: every id's final body is the last record
    /// that touched it (already in `base`) or `base[id]`, and the order is the
    /// records' final order (already `base`'s). This is what a checkpoint
    /// relies on when a crash leaves the log un-cleared over a fresh checkpoint.
    static func fold(base: [AgentConversation], records: [ConversationDeltaRecord]) -> [AgentConversation] {
        var byID: [UUID: AgentConversation] = [:]
        byID.reserveCapacity(base.count)
        for conversation in base { byID[conversation.id] = conversation }
        var order: [UUID] = base.map(\.id)

        for record in records {
            order = record.order
            for conversation in record.changed { byID[conversation.id] = conversation }
        }
        return order.compactMap { byID[$0] }
    }

    /// The delta from `previous` to `next`, or nil when nothing changed (so the
    /// caller writes nothing and posts nothing — the identical-payload skip
    /// `AtomicValueFile.commit` performed, preserved here). `changed` is every
    /// row in `next` whose body differs from `previous` (a new id included);
    /// membership and reordering ride in `order`, so a pure reorder or a
    /// deletion still produces a record even with an empty `changed`.
    static func delta(from previous: [AgentConversation], to next: [AgentConversation]) -> ConversationDeltaRecord? {
        var previousByID: [UUID: AgentConversation] = [:]
        previousByID.reserveCapacity(previous.count)
        for conversation in previous { previousByID[conversation.id] = conversation }

        let changed = next.filter { previousByID[$0.id] != $0 }
        let orderChanged = previous.map(\.id) != next.map(\.id)
        guard !changed.isEmpty || orderChanged else { return nil }
        return ConversationDeltaRecord(order: next.map(\.id), changed: changed)
    }
}

// MARK: - Store

@MainActor
final class ConversationDeltaLog {
    /// Non-nil once a COMPLETE (newline-terminated) segment failed to decode —
    /// genuine corruption, not a torn tail. While it stands the repository
    /// treats the store as frozen: it serves the last checkpoint, suppresses
    /// export, and refuses writes, exactly as a corrupt checkpoint would.
    private(set) var fault: String?

    let fileURL: URL

    private let fm = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Same load-bearing reason as `AtomicValueFile`'s: two encodes of one
        // value must not differ byte-wise, so a re-fold-then-re-encode is
        // stable and the delta diff never fires on key reordering alone.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // MARK: Reading

    /// Every complete record, torn tail dropped. Returns nil and sets `fault`
    /// when a complete segment will not decode (corruption). An absent file is
    /// an empty log, not a fault. Clears a stale `fault` on a clean read.
    func loadRecords() -> [ConversationDeltaRecord]? {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            fault = nil
            return []
        }
        let text = String(decoding: data, as: UTF8.self)
        // `components(separatedBy:)` and drop the last element unconditionally:
        // for a clean file it is the empty string after the final newline; for
        // a file torn mid-append it is the partial, un-terminated tail. Either
        // way it is exactly the segment that must not be required to decode.
        var segments = text.components(separatedBy: "\n")
        segments.removeLast()

        var records: [ConversationDeltaRecord] = []
        records.reserveCapacity(segments.count)
        for segment in segments {
            if segment.isEmpty { continue }
            guard let recordData = segment.data(using: .utf8),
                  let record = try? decoder.decode(ConversationDeltaRecord.self, from: recordData) else {
                fault = "delta log: undecodable committed record"
                deltaLogTrailError("deltalog: \(fileURL.lastPathComponent) undecodable committed record; freezing")
                return nil
            }
            records.append(record)
        }
        fault = nil
        return records
    }

    var byteSize: Int {
        ((try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    // MARK: Writing

    /// Append one delta. Never rewrites a prior byte: the whole crash-safety
    /// argument rests on this. `fsync` before returning is the power-loss
    /// insurance `AtomicValueFile` also takes; it is not observable in a
    /// simulator unit test (the page cache serves the bytes regardless), so the
    /// observable durability guardian is the append-only discipline itself.
    @discardableResult
    func append(_ record: ConversationDeltaRecord) -> Bool {
        guard var payload = try? encoder.encode(record) else {
            deltaLogTrailError("deltalog: \(fileURL.lastPathComponent) could not encode a delta")
            return false
        }
        payload.append(0x0A)

        let directory = fileURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            deltaLogTrailError("deltalog: \(fileURL.lastPathComponent) directory unavailable: \(error)")
            return false
        }
        if !fm.fileExists(atPath: fileURL.path) {
            guard fm.createFile(atPath: fileURL.path, contents: nil) else {
                deltaLogTrailError("deltalog: \(fileURL.lastPathComponent) could not be created")
                return false
            }
        }
        // `forUpdatingTo` (O_RDWR), not `forWritingTo`: the heal step below
        // reads the last byte on disk, and a write-only handle cannot read.
        guard let handle = try? FileHandle(forUpdating: fileURL) else {
            deltaLogTrailError("deltalog: \(fileURL.lastPathComponent) could not be opened for append")
            return false
        }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            // Drop a torn tail before appending: if the last byte on disk is not
            // a newline, a prior append was killed mid-write. Those bytes were
            // never fsync-confirmed (the crashed `append` never returned), so
            // truncating them back to the last complete record loses nothing —
            // and it keeps every surviving segment newline-terminated, so a
            // reader can hold the strict rule "a COMPLETE segment that will not
            // decode is corruption" without a healed partial ever tripping it.
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                let lastByte = try handle.read(upToCount: 1)
                if lastByte != Data([0x0A]) {
                    let whole = (try? Data(contentsOf: fileURL)) ?? Data()
                    let truncateTo = whole.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
                    try handle.truncate(atOffset: UInt64(truncateTo))
                    deltaLogTrail("deltalog: \(fileURL.lastPathComponent) dropped a torn tail (\(end - UInt64(truncateTo))B) before append")
                }
            }
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
            try? handle.synchronize()
            return true
        } catch {
            deltaLogTrailError("deltalog: \(fileURL.lastPathComponent) append failed: \(error)")
            return false
        }
    }

    /// Drop every delta. Called after a checkpoint has folded the log into the
    /// checkpoint file, and on restore/wipe. A kill mid-clear leaves either the
    /// old log (replays idempotently onto the new checkpoint) or no log (the
    /// checkpoint alone) — both correct.
    func clear() {
        try? fm.removeItem(at: fileURL)
        fault = nil
    }

    func clearFault() {
        fault = nil
    }
}
