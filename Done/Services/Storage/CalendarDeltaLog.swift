//
//  CalendarDeltaLog.swift
//  Done
//
//  gh#235 — the write-ahead half of `.calendarEvents` persistence.
//
//  WHY THIS EXISTS
//  ---------------
//  On the dogfood device the calendar slot holds 4164 rows / 2.04 MB, and
//  EVERY change — a drag, a resize, a completion tick, an effort scrub —
//  re-encoded the WHOLE array on the main thread before `rename(2)`-ing it
//  into place. The device trail measured `encodeMs=48-70` per save across
//  4849 saves in one install (~10 GB of rewrites), and MetricKit reported
//  `diskWriteExceptionDiagnostics` with a `write` syscall callstack.
//
//  This file is the append log that removes that. `DurableEventStorage`'s
//  slot file (`calendarEvents.json`) is KEPT as the CHECKPOINT — its two-part
//  framed layout, its `SlotEnvelopeHeader` semantics and every byte of an
//  encoded `Event` unchanged (RED LINE 1, the ground `#220`'s Lean civil
//  theorems and the `#152→#212` projection lineage stand on) — and this log
//  holds only the deltas accumulated on top of it. The served state is
//  checkpoint ⊕ log; the whole array is re-encoded only when the LOG crosses
//  a byte bound, when one delta is itself large, at a background edge, or on
//  any `.destructive` write.
//
//  DELTA IS NOT DEFERRAL
//  ---------------------
//  `DurableEventStorage`'s file header says "Deferring a write is exactly the
//  bug", and that stands unchanged here. Nothing on this path is debounced,
//  coalesced or batched: `saveCalendarEvents()` still returns only after the
//  bytes of THIS change have been handed to `write(2)` and fsync'd. What
//  changed is how many bytes that is — the changed rows instead of all 4164 —
//  not when they are written. `saveCalendarEvents() == true` therefore keeps
//  meaning exactly what the delete chain's photo `unlink` and the gh#207
//  one-shot heal version flag already bet on.
//
//  RECORD SHAPE, AND WHY `order` IS OPTIONAL
//  -----------------------------------------
//  `ConversationDeltaLog` (gh#219, the proven precedent this borrows its
//  crash-safety mechanics from) writes the FULL ordered id list in every
//  record. At nine conversations that is free. At 4164 events it inverts the
//  whole argument: a UUID in JSON is 36 characters plus quotes and a comma,
//  so a full `order` is ~158 KB — 323x the ~490 B an average row encodes to,
//  and enough to trigger a 2 MB checkpoint every other save. So `order` is
//  written ONLY when membership or position actually changed (a create, a
//  delete, a reorder); a `nil` `order` INHERITS the previous folded order,
//  which is the overwhelmingly common case (drag, resize, tick, scrub).
//
//  Inheritance costs the records their self-sufficiency: a record no longer
//  proves what order it folds to. `orderDigest` — written on EVERY record —
//  buys that back, turning "the inherited order drifted" from a silent
//  wrong-array into a fault. `count` does the same for length.
//
//  TWO LOAD-BEARING PROPERTIES (see `CalendarDeltaFold.fold`)
//  ---------------------------------------------------------
//   * EXACTNESS: `fold(checkpoint, records)` equals, element for element, the
//     array the whole-array write path would have written.
//   * IDEMPOTENCE: folding records over a checkpoint that already
//     incorporates them is a fixed point. That is what makes the checkpoint
//     ordering crash-safe — a kill between "rename the checkpoint" and "clear
//     the log" replays stale deltas and lands on the same state.
//  Both are re-proven for the INHERITED-order shape (the precedent's proof
//  does not carry over unchanged) and both have their own tests; the proof is
//  in the fold's doc comment, the evidence is in `CalendarDeltaLogTests`.
//
//  GENERATIONS ARE THE THIRD PROPERTY, AND THE STRONGEST
//  ----------------------------------------------------
//  Each record carries `base` (the checkpoint seq it extends) and `seq` (the
//  generation it mints). Comparing `base` against the checkpoint's own seq
//  settles, without replaying anything, which of three things happened:
//  the checkpoint already absorbed this log (discard it), the log extends the
//  checkpoint (fold it), or the checkpoint went BACKWARDS underneath the log
//  (quarantine and freeze — a backup promotion, an out-of-process injection,
//  a hand-swapped file). See `CalendarDeltaFold.plan`.
//
//  CRASH SAFETY OF THE APPEND ITSELF
//  ---------------------------------
//  Mechanics deliberately identical to `ConversationDeltaLog`'s, which has
//  shipped: an append only ever appends, never rewrites a prior byte, so a
//  kill mid-append can damage only the tail. `loadRecords` drops a torn tail
//  (a final segment with no terminating newline — a write that never
//  completed, hence was never confirmed) and requires every COMPLETE
//  (newline-terminated) segment to decode. A complete segment that will not
//  decode is genuine corruption, not a torn write, and raises `fault` rather
//  than being skipped: an unreadable history that presents as a SHORTER one
//  is the one shape that gets mirrored outward — `diffSync` DELETEs the
//  difference in the cloud, `BackupSnapshotService` writes it into the DR
//  document, and the asset sweep unlinks the photos of the rows it no longer
//  sees. Three copies shorten together.
//
//  The two rules stay compatible because `append` TRUNCATES a torn tail
//  (never fsync-confirmed, so safe to drop) before writing, so a post-crash
//  append starts on a clean record boundary. The boundary is found by scanning
//  BACKWARDS through the handle that is already open, and a read that FAILS
//  aborts the append instead of being read as "no boundary found" — see
//  `append`'s heal block for why that distinction is the difference between
//  healing a tail and destroying the log.
//
//  READ FAILURE IS NOT AN EMPTY LOG
//  --------------------------------
//  `loadRecords` returns three distinct answers — `[]` (no file), `nil` +
//  `.io` (a file that would not read), `nil` + `.decode` (a complete segment
//  that would not decode) — because collapsing the first two is exactly the
//  "history that cannot be read presents as a shorter one" shape the previous
//  paragraph forbids.
//

import CryptoKit
import Foundation
import os

private let calendarDeltaLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Done",
    category: "Persistence"
)

private func deltaTrail(_ message: String) {
    calendarDeltaLogger.log("\(message, privacy: .public)")
    DiagnosticTrail.record("Persistence", message)
}

private func deltaTrailError(_ message: String) {
    calendarDeltaLogger.error("\(message, privacy: .public)")
    DiagnosticTrail.record("Persistence", "ERROR " + message)
}

// MARK: - Record

/// One appended delta.
///
/// `v` is the schema flag (the straddle-heal precedent: a version stamp so an
/// older reader refuses a shape it does not know rather than mis-folding it).
struct CalendarDeltaRecord: Codable, Equatable {
    static let currentVersion = 1

    var v: Int
    /// The checkpoint generation this record extends. Every record in one log
    /// carries the same `base`; the fold refuses a log whose records disagree.
    var base: UInt64
    /// The generation this record mints — `base + (1-based index)`. This is
    /// what keeps `DurableEventStorage.committedSeq` strictly increasing on an
    /// append, which the restore marker's staleness test depends on.
    var seq: UInt64
    /// The full ordered id list after this record, written ONLY when
    /// membership or position changed. `nil` inherits the previous folded
    /// order — see the file header for why that is worth its complexity here
    /// and was not in `ConversationDeltaLog`.
    var order: [UUID]?
    /// Digest of the complete order this record folds to, written always.
    /// The structural guard the optional `order` gives up.
    var orderDigest: String
    /// Row count after this record, written always.
    var count: Int
    /// Full bodies of the rows whose value differs from the last PERSISTED
    /// array, last-write-wins by id.
    var changed: [Event]
    /// The Domino stamp this write carries. It rides in the SAME record as the
    /// rows it describes, for the same reason `SlotEnvelopeHeader.dominoLastPush`
    /// rides in the same file as the rows: losing the stamp while keeping the
    /// rows makes the next launch re-apply the whole elapsed delta on top of
    /// already-shifted todos — silent, permanent date corruption.
    var dominoLastPush: Date?

    init(base: UInt64, seq: UInt64, order: [UUID]?, orderDigest: String, count: Int,
         changed: [Event], dominoLastPush: Date?,
         v: Int = CalendarDeltaRecord.currentVersion) {
        self.v = v
        self.base = base
        self.seq = seq
        self.order = order
        self.orderDigest = orderDigest
        self.count = count
        self.changed = changed
        self.dominoLastPush = dominoLastPush
    }
}

// MARK: - Fold (pure)

enum CalendarDeltaFold {
    /// What to do with a log, decided from generations alone — before any
    /// replay, and before any internal commit can clear it.
    enum Plan: Equatable {
        /// No records: serve the checkpoint.
        case useCheckpoint
        /// The checkpoint is NEWER than the base these records extend, so it
        /// already absorbed (or replaced) them. This is exactly the window a
        /// kill between `rename` and `clear` leaves behind. Not a fault.
        case discardLog(String)
        case fold
        /// The checkpoint went backwards underneath the log, or the log is
        /// internally inconsistent. The bodies are not recoverable onto this
        /// base: quarantine and freeze rather than serve a state that is
        /// missing edits the user made.
        case quarantine(String)
    }

    enum FoldFault: Error, Equatable {
        case unknownVersion(Int)
        case baseMismatch(checkpoint: UInt64, record: UInt64)
        case seqGap(expected: UInt64, found: UInt64)
        case danglingID(UUID)
        case countMismatch(expected: Int, folded: Int)
        case orderDrift
        case duplicateBaseID(UUID)

        var detail: String { String(describing: self) }
    }

    struct Folded: Equatable {
        var rows: [Event]
        /// The generation the folded state stands at — the last record's seq.
        var seq: UInt64
        var dominoLastPush: Date?
    }

    /// SHA256 over each UUID's 16 RAW bytes concatenated in order, hex-encoded.
    ///
    /// Raw bytes rather than the string form, and no separator: a separator
    /// invites the "is it part of the id or between ids?" ambiguity, and a
    /// fixed 16-byte stride has no ambiguity to resolve. The threat model is
    /// accident (an inherited order that drifted), not forgery, so the choice
    /// of hash is free — what must be pinned is the INPUT definition, which
    /// this comment and `testOrderDigestDistinguishesPermutations` pin
    /// together.
    static func orderDigest(_ order: [UUID]) -> String {
        var hasher = SHA256()
        for id in order {
            withUnsafeBytes(of: id.uuid) { hasher.update(bufferPointer: $0) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Decide what a log means relative to the checkpoint it was found beside.
    /// Generation comparison is STRONGER than replaying and checking: it
    /// settles the stale-log case without touching a single body.
    static func plan(checkpointSeq: UInt64, records: [CalendarDeltaRecord]) -> Plan {
        guard let first = records.first else { return .useCheckpoint }
        if let bad = records.first(where: { $0.v > CalendarDeltaRecord.currentVersion }) {
            return .quarantine("record version \(bad.v) is newer than \(CalendarDeltaRecord.currentVersion)")
        }
        guard records.allSatisfy({ $0.base == first.base }) else {
            return .quarantine("records disagree about their base generation")
        }
        if first.base < checkpointSeq {
            return .discardLog("checkpoint seq=\(checkpointSeq) already absorbed a log based on \(first.base)")
        }
        if first.base > checkpointSeq {
            return .quarantine("log base \(first.base) is ahead of checkpoint seq \(checkpointSeq)")
        }
        return .fold
    }

    /// Reconstruct the array from a checkpoint and the log records, in order.
    ///
    /// EXACTNESS (RED LINE 3). Let `persisted_k` be the array that was durable
    /// after record k, and `rows_k` the array `commit` was handed at step k.
    /// Record k is built by `delta(from: persisted_{k-1}, to: rows_k)`, which
    /// puts in `changed` every row of `rows_k` whose body differs from
    /// `persisted_{k-1}`, and writes `order` whenever the id sequence differs.
    /// Inductively, suppose the fold after k-1 records equals `persisted_{k-1}`
    /// (the base case is the checkpoint, which by construction IS
    /// `persisted_0`). Then at step k:
    ///   * every id whose body changed is upserted by `changed`;
    ///   * every id whose body did not change already carries `rows_k`'s body,
    ///     since it equals `persisted_{k-1}`'s;
    ///   * the order is `rows_k`'s, either written explicitly or inherited in
    ///     precisely the case where `persisted_{k-1}`'s order already equals it.
    /// So the fold after k equals `rows_k = persisted_k`. The terminal fold is
    /// `persisted_n` element for element.
    ///
    /// IDEMPOTENCE (RED LINE 3). If the base already equals
    /// `fold(oldBase, records)`, replaying them changes nothing: each id's
    /// final body is the last record that touched it (already in the base) or
    /// the base's own; the final order is the last explicit `order` (already
    /// the base's) or, with every `order` nil, the inherited base order. Note
    /// this holds for the INHERITED shape only because inheritance starts from
    /// the base being folded onto — which is what the independent idempotence
    /// test exists to hold down rather than this paragraph.
    ///
    /// COMPLETENESS (RED LINE 2 / G6). An id in `order` that resolves in
    /// neither the base nor any `changed` is corruption, and this returns a
    /// fault for it. It deliberately does NOT `compactMap` it away: a history
    /// that cannot be read must never present as a shorter history.
    static func fold(base: [Event], baseSeq: UInt64, baseStamp: Date?,
                     records: [CalendarDeltaRecord]) -> Result<Folded, FoldFault> {
        guard let last = records.last else {
            return .success(Folded(rows: base, seq: baseSeq, dominoLastPush: baseStamp))
        }
        if let bad = records.first(where: { $0.v > CalendarDeltaRecord.currentVersion }) {
            return .failure(.unknownVersion(bad.v))
        }
        for (offset, record) in records.enumerated() {
            guard record.base == baseSeq else {
                return .failure(.baseMismatch(checkpoint: baseSeq, record: record.base))
            }
            let expected = baseSeq + UInt64(offset + 1)
            guard record.seq == expected else {
                return .failure(.seqGap(expected: expected, found: record.seq))
            }
        }

        var byID: [UUID: Event] = [:]
        byID.reserveCapacity(base.count + last.changed.count)
        for row in base {
            // A checkpoint holding two rows under one id would fold to two
            // copies of ONE body — a fold whose count matches and whose
            // contents are wrong — so this refuses instead.
            //
            // `DurableEventStorage` refuses the delta path when EITHER the
            // incoming rows OR the installed base carries a duplicate id
            // (G19 + round-2 A-F1), so this writer does not mint a log over a
            // duplicated base. That is a statement about THIS writer, not a
            // proof that the case is unreachable: the base can acquire a
            // duplicate between launches (a cloud overwrite, an out-of-process
            // injection, a hand-swapped file) while a log written before it
            // still stands beside it. Both halves are pinned by fixtures —
            // the writer-side refusal by
            // `testABaseThatAlreadyHoldsADuplicateIDRefusesTheDeltaPath`, this
            // refusal by `testADuplicatedIDInTheBaseFaultsRatherThanCollapsing`
            // — and neither by this comment.
            guard byID.updateValue(row, forKey: row.id) == nil else {
                return .failure(.duplicateBaseID(row.id))
            }
        }
        var order: [UUID] = base.map(\.id)
        var stamp = baseStamp

        for record in records {
            if let explicit = record.order { order = explicit }
            for row in record.changed { byID[row.id] = row }
            if let recorded = record.dominoLastPush {
                // Only ever forward: the same `max` rule `dominoStampToCommit`
                // and the heartbeat loader use.
                stamp = stamp.map { Swift.max($0, recorded) } ?? recorded
            }
        }

        guard order.count == last.count else {
            return .failure(.countMismatch(expected: last.count, folded: order.count))
        }
        guard orderDigest(order) == last.orderDigest else {
            return .failure(.orderDrift)
        }
        var rows: [Event] = []
        rows.reserveCapacity(order.count)
        for id in order {
            guard let row = byID[id] else { return .failure(.danglingID(id)) }
            rows.append(row)
        }
        return .success(Folded(rows: rows, seq: last.seq, dominoLastPush: stamp))
    }

    /// The delta from the last PERSISTED array to `next`, or nil when disk
    /// already folds to exactly `next` (same rows, same order, same stamp) —
    /// in which case the caller writes nothing, exactly as the byte-digest
    /// skip does on the checkpoint path.
    ///
    /// The fast path is the one the device actually runs: the id sequence is
    /// unchanged (a drag, a resize, a tick, an effort scrub), so this is one
    /// linear pass of `Event.==` with no dictionary built at all. The
    /// dictionary is only paid when membership or position moved.
    static func delta(from persisted: [Event], to next: [Event],
                      base: UInt64, seq: UInt64,
                      dominoLastPush: Date?, persistedStamp: Date?) -> CalendarDeltaRecord? {
        var changed: [Event] = []
        let sameOrder = persisted.count == next.count
            && !zip(persisted, next).contains { $0.id != $1.id }

        if sameOrder {
            for index in next.indices where persisted[index] != next[index] {
                changed.append(next[index])
            }
        } else {
            var persistedByID: [UUID: Event] = [:]
            persistedByID.reserveCapacity(persisted.count)
            for row in persisted { persistedByID[row.id] = row }
            changed = next.filter { persistedByID[$0.id] != $0 }
        }

        // A nil incoming stamp never erases a known one (the fold takes `max`
        // and only moves forward), so it is not a change worth a record.
        let stampMoved = dominoLastPush != nil && dominoLastPush != persistedStamp

        guard !changed.isEmpty || !sameOrder || stampMoved else { return nil }

        let order = next.map(\.id)
        return CalendarDeltaRecord(
            base: base,
            seq: seq,
            order: sameOrder ? nil : order,
            orderDigest: orderDigest(order),
            count: next.count,
            changed: changed,
            dominoLastPush: dominoLastPush
        )
    }
}

// MARK: - Store

/// The append-only file beside `calendarEvents.json`.
///
/// Owned exclusively by `DurableEventStorage`, which is the one object allowed
/// to decide when the log is read, appended to, quarantined or cleared — the
/// same reason the freeze guard lives inside `commit` rather than at its call
/// sites.
@MainActor
final class CalendarDeltaLog {
    /// Why the last `loadRecords` refused to answer. The two cases are
    /// deliberately NOT collapsed: the repo's own `readEnvelope` takes
    /// opposite postures on them for the primary (`.io` moves not one byte,
    /// `.decode` quarantines), and a log deserves the same two answers for
    /// the same reason.
    enum LoadFault: Equatable {
        /// The bytes could not be read at all (EIO, EACCES, protected data
        /// unavailable). Possibly transient, possibly a perfectly good file.
        case io(String)
        /// A COMPLETE (newline-terminated) segment would not decode. Genuine
        /// corruption, never a torn tail.
        case decode(String)

        var detail: String {
            switch self {
            case .io(let detail): return "unreadable: \(detail)"
            case .decode(let detail): return detail
            }
        }
    }

    private(set) var loadFault: LoadFault?

    /// Non-nil once a load refused. Kept as a `String?` because the write path
    /// only asks "may I append?" and both answers are no.
    var fault: String? { loadFault?.detail }

    /// Raised when the heal scan cannot read the bytes it is about to
    /// truncate past. Never surfaced to the user: `append` turns it into a
    /// `nil` return, i.e. the fallback-to-checkpoint rung.
    private enum HealFault: Error { case unreadable(UInt64) }

    let fileURL: URL

    private let fm = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Same load-bearing reason as the row encoder's: two encodes of one
        // value must not differ byte-wise.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    var exists: Bool { fm.fileExists(atPath: fileURL.path) }

    var byteSize: Int {
        ((try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    // MARK: Reading

    /// Every complete record, torn tail dropped.
    ///
    /// THREE distinct answers, and keeping them apart is load-bearing:
    ///  * `[]` — no file. A store that has never logged. Not a fault.
    ///  * `nil` + `loadFault == .io` — the file IS there and would not read.
    ///    No information; the caller must freeze rather than serve a state
    ///    this log may have added to.
    ///  * `nil` + `loadFault == .decode` — a COMPLETE (newline-terminated)
    ///    segment would not decode. Genuine corruption, never a torn tail.
    ///
    /// Round 1 collapsed the first two into one `try?`, which made an
    /// unreadable log present as an EMPTY one — the single shape this file's
    /// header forbids, since a history that reads as SHORTER is mirrored
    /// outward by `diffSync` (cloud DELETEs) and `BackupSnapshotService` (the
    /// DR document). Three copies shorten together.
    func loadRecords() -> [CalendarDeltaRecord]? {
        guard fm.fileExists(atPath: fileURL.path) else {
            loadFault = nil
            return []
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            loadFault = .io(String(describing: error))
            deltaTrailError("deltalog: \(fileURL.lastPathComponent) exists but could not be read: \(error)")
            return nil
        }
        guard !data.isEmpty else {
            loadFault = nil
            return []
        }
        let text = String(decoding: data, as: UTF8.self)
        // Drop the last component unconditionally: in a clean file it is the
        // empty string after the final newline; in a file torn mid-append it
        // is the partial, un-terminated tail. Either way it is exactly the
        // segment that must not be required to decode.
        var segments = text.components(separatedBy: "\n")
        segments.removeLast()

        var records: [CalendarDeltaRecord] = []
        records.reserveCapacity(segments.count)
        for segment in segments {
            if segment.isEmpty { continue }
            guard let recordData = segment.data(using: .utf8),
                  let record = try? decoder.decode(CalendarDeltaRecord.self, from: recordData) else {
                loadFault = .decode("calendar delta log: undecodable committed record")
                deltaTrailError("deltalog: \(fileURL.lastPathComponent) undecodable committed record")
                return nil
            }
            records.append(record)
        }
        loadFault = nil
        return records
    }

    /// The generation of the last complete record, without decoding any
    /// bodies' worth of meaning beyond it. Used by the manifest reconcile,
    /// which runs before any read and must take the "no information" posture
    /// on anything it cannot make sense of.
    func tailSeq() -> UInt64? {
        loadRecords()?.last?.seq
    }

    // MARK: Writing

    /// What one landed append cost and left behind.
    struct AppendOutcome: Equatable {
        /// The log's length on disk AFTER this append, read back from the
        /// open handle — not computed. This is the delta path's twin of the
        /// checkpoint path's `stat` on its temp file, and it is what makes
        /// `CommitReceipt.onDiskBytes` mean the same thing on both paths.
        var onDiskBytes: Int
        /// Measured `fsync`. Round 1 reported `syncMs: 0` on every delta
        /// receipt while running one `synchronize()` per append — the number
        /// the device A/B compares against the checkpoint row's own `syncMs`.
        var syncMs: Int
    }

    /// Encode one record, without writing it.
    ///
    /// Split out from `append` so the caller can size-bound the payload and
    /// MEASURE the encode without paying for it twice: round 1 encoded every
    /// record once in `DurableEventStorage` (for the byte bounds) and again
    /// in here, then reported `encodeMs: 0`. The bytes are identical either
    /// way (`.sortedKeys` on both encoders), which is exactly why the second
    /// encode bought nothing.
    func encode(_ record: CalendarDeltaRecord) -> Data? {
        guard let payload = try? encoder.encode(record) else {
            deltaTrailError("deltalog: \(fileURL.lastPathComponent) could not encode a delta")
            return nil
        }
        return payload
    }

    /// Encode and append in one call.
    ///
    /// NOT the production path: `DurableEventStorage` needs the encoded
    /// payload before it writes (for the two byte bounds) and needs the
    /// encode MEASURED (round-2 B3), so it calls `encode` and
    /// `append(encoded:)` itself. This overload exists for callers that need
    /// neither.
    @discardableResult
    func append(_ record: CalendarDeltaRecord) -> AppendOutcome? {
        guard let payload = encode(record) else { return nil }
        return append(encoded: payload)
    }

    /// Append one ALREADY-ENCODED record (no trailing newline — this adds it)
    /// and return what it cost, or nil on any failure. Never rewrites a prior
    /// byte: the whole crash-safety argument rests on that.
    func append(encoded record: Data) -> AppendOutcome? {
        var payload = record
        payload.append(0x0A)

        let directory = fileURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            deltaTrailError("deltalog: \(fileURL.lastPathComponent) directory unavailable: \(error)")
            return nil
        }
        if !fm.fileExists(atPath: fileURL.path) {
            guard fm.createFile(atPath: fileURL.path, contents: nil) else {
                deltaTrailError("deltalog: \(fileURL.lastPathComponent) could not be created")
                return nil
            }
        }
        // `forUpdatingTo` (O_RDWR), not `forWritingTo`: the heal step below
        // reads the last byte on disk, and a write-only handle cannot read.
        guard let handle = try? FileHandle(forUpdating: fileURL) else {
            deltaTrailError("deltalog: \(fileURL.lastPathComponent) could not be opened for append")
            return nil
        }
        defer { try? handle.close() }
        do {
            var base = try handle.seekToEnd()
            // Drop a torn tail before appending: if the last byte on disk is
            // not a newline, a prior append was killed mid-write. Those bytes
            // were never fsync-confirmed (the crashed `append` never
            // returned), so truncating back to the last complete record loses
            // nothing — and it keeps every surviving segment
            // newline-terminated, so the reader can hold the strict rule "a
            // COMPLETE segment that will not decode is corruption" without a
            // healed partial ever tripping it.
            //
            // Round-2 A-F3. This must NEVER re-read the whole file to find
            // the boundary. Round 1 did `(try? Data(contentsOf:)) ?? Data()`,
            // so a read that FAILED (protected data unavailable, EIO, a
            // revoked descriptor) produced an empty `Data`, `lastIndex(of:)`
            // found no newline, `truncateTo` collapsed to 0 — and the log was
            // truncated to zero bytes and TRAILED as "dropped a torn tail".
            // That is the writer destroying every un-checkpointed edit while
            // reporting a routine heal. The boundary now comes from a
            // backwards scan of the handle that is already open, and a read
            // failure throws into the `catch` below, which returns nil — the
            // fallback-to-checkpoint rung, where nothing is lost.
            if base > 0 {
                try handle.seek(toOffset: base - 1)
                let lastByte = try handle.read(upToCount: 1)
                if lastByte != Data([0x0A]) {
                    let truncateTo = try lastRecordBoundary(in: handle, before: base)
                    try handle.truncate(atOffset: truncateTo)
                    deltaTrail("deltalog: \(fileURL.lastPathComponent) dropped a torn tail (\(base - truncateTo)B) before append")
                    base = truncateTo
                }
            }
            let expectedEnd = base + UInt64(payload.count)
            try handle.seek(toOffset: base)
            try handle.write(contentsOf: payload)
            let syncStart = Date()
            try? handle.synchronize()
            let syncMs = Int(Date().timeIntervalSince(syncStart) * 1000)
            // The delta path's twin of the checkpoint path's
            // `guard onDisk == data.count` short-write refusal, and cheap
            // here because the handle is already open — `seekToEnd` is an
            // `lseek`, not a `stat`.
            //
            // Why a short write could not cost a RECORD even without this
            // guard, written down so the next reader need not re-derive it
            // (and pinned by `testAnUnterminatedTailIsNeverServedAsARecord`):
            //   * `FileHandle.write(contentsOf:)` loops over partial writes
            //     and throws on error, so it either wrote every byte or threw;
            //   * a record's JSON body can hold no RAW newline (JSON escapes
            //     them), so the only 0x0A in `payload` is the terminator
            //     appended above;
            //   * therefore any prefix shorter than the whole payload ends
            //     WITHOUT a newline — which `loadRecords` drops as a torn tail
            //     and the next `append` truncates away.
            // The guard still earns its line: it converts "silently healed at
            // some later launch" into "this save falls back to a whole-array
            // checkpoint right now", which is the stronger of the two.
            let confirmedEnd = try handle.seekToEnd()
            guard confirmedEnd == expectedEnd else {
                deltaTrailError("deltalog: \(fileURL.lastPathComponent) short append: \(confirmedEnd) on disk, expected \(expectedEnd)")
                return nil
            }
            return AppendOutcome(onDiskBytes: Int(confirmedEnd), syncMs: syncMs)
        } catch {
            deltaTrailError("deltalog: \(fileURL.lastPathComponent) append failed: \(error)")
            return nil
        }
    }

    /// Offset of the first byte AFTER the last newline at or before `end`, or
    /// 0 when the whole file holds no newline (one un-terminated partial
    /// record, which truncating to 0 loses nothing of).
    ///
    /// Throws rather than returning 0 when a read FAILS. That is the entire
    /// point of the function: "I scanned the file and found no boundary" and
    /// "I could not scan the file" are opposite facts, and answering the
    /// second with the first is what truncated the log in round 1.
    /// Not `private` so the throw contract can be pinned directly by
    /// `testTheBoundaryScanThrowsRatherThanAnsweringZeroWhenItCannotRead` —
    /// "could not scan" reaching the caller as "no boundary, truncate to 0"
    /// is the exact defect this replaced, and it is invisible from the
    /// outside on any file that reads normally.
    func lastRecordBoundary(in handle: FileHandle, before end: UInt64) throws -> UInt64 {
        let window: UInt64 = 64 * 1024
        var cursor = end
        while cursor > 0 {
            let size = Swift.min(window, cursor)
            let start = cursor - size
            try handle.seek(toOffset: start)
            guard let chunk = try handle.read(upToCount: Int(size)), chunk.count == Int(size) else {
                throw HealFault.unreadable(start)
            }
            if let index = chunk.lastIndex(of: 0x0A) {
                return start + UInt64(chunk.distance(from: chunk.startIndex, to: index)) + 1
            }
            cursor = start
        }
        return 0
    }

    /// Drop every delta, reporting whether the file is actually gone.
    ///
    /// Three callers, all in `DurableEventStorage`: right after a
    /// checkpoint's `rename` lands, after a stale log is discarded by
    /// generation, and the post-wipe purge. An absent file IS success — the
    /// post-wipe purge routinely runs with nothing to remove.
    ///
    /// The return value is load-bearing (round-2 A-F5). A kill mid-clear is
    /// harmless (the surviving log's base is older than the new checkpoint's
    /// seq, so the next launch discards it by generation) but a clear that
    /// FAILS while this process keeps appending is not: the next append
    /// writes a record with the NEW base into a file that still holds records
    /// on the old one, and `CalendarDeltaFold.plan` quarantines a log whose
    /// records disagree about their base — one whole session of edits. The
    /// caller must disable the delta path until a clear succeeds.
    @discardableResult
    func clear() -> Bool {
        guard fm.fileExists(atPath: fileURL.path) else {
            loadFault = nil
            return true
        }
        do {
            try fm.removeItem(at: fileURL)
            loadFault = nil
            return true
        } catch {
            deltaTrailError("deltalog: \(fileURL.lastPathComponent) could not be cleared: \(error)")
            return false
        }
    }

    /// Move the log aside, keeping it for support retrieval, and return the
    /// name it landed under. Leaving it in place would re-freeze the slot on
    /// every launch forever; moving it means the NEXT launch reads a clean
    /// checkpoint and the user is out of the freeze with no new UI.
    @discardableResult
    func quarantine(into directory: URL?, named name: String) -> String? {
        guard let directory, fm.fileExists(atPath: fileURL.path) else { return nil }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try fm.moveItem(at: fileURL, to: directory.appendingPathComponent(name))
            loadFault = nil
            return name
        } catch {
            deltaTrailError("deltalog: \(fileURL.lastPathComponent) could not be quarantined: \(error)")
            return nil
        }
    }

    func clearFault() {
        loadFault = nil
    }
}
