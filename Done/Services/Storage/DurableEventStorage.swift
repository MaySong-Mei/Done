//
//  DurableEventStorage.swift
//  Done
//
//  File-backed, crash-safe storage for the eight arrays in `StorageSlot`.
//
//  WHY THIS EXISTS
//  ---------------
//  `UserDefaults.set` returns once the bytes reach **cfprefsd** — a separate
//  user-space process — not once anything is on disk. cfprefsd batches its
//  disk writes; on the dogfood device a 1.25 MB calendar blob whose `save`
//  reported success was gone 3.2 seconds later when the user swipe-killed the
//  app and relaunched. The `set` call cannot fail and returns nothing, so the
//  app had no way to know.
//
//  `write(2)` is different in the way that matters: when it returns the bytes
//  are in the kernel's unified buffer cache, owned by the filesystem. SIGKILL
//  (swipe-to-kill, jetsam) cannot take them back. That alone is the fix.
//
//  `rename(2)` buys a second, independent thing: a 1.25 MB in-place overwrite
//  that is killed halfway leaves a truncated file mixing old and new bytes —
//  which upgrades "lost the last edit" into "lost all 2690 rows". Since plain
//  process death is enough to trigger that, the temp-file + rename commit is
//  not optional.
//
//  `fsync` of the data before the rename is the third piece and buys only
//  power-loss resistance: it moves the worst case from "file is corrupt"
//  (which freezes the slot and shows the user a scary banner) back to "file is
//  stale" (harmless). It is measured separately in the trail as `syncMs` so it
//  can be dropped if it ever shows up in the p95.
//
//  WHAT THIS DELIBERATELY DOES NOT DO
//  ----------------------------------
//  No debouncing, no background queue, no SQLite. Deferring a write is exactly
//  the bug; moving it off the main actor makes "the process died before the
//  write" reachable again; a real database is a different quarter's migration
//  risk and must not ride along with the bleeding being stopped here.
//
//  That stands unchanged under gh#235. The calendar's delta log (see
//  `CalendarDeltaLog`) does not defer anything: a `commit` still returns only
//  after THIS change's bytes have been handed to `write(2)` and fsync'd. What
//  it changes is how many bytes that is — the changed rows, not all 4164.
//  Delta is not deferral.
//
//  FILE FORMAT
//  -----------
//      <header JSON on one line>\n<rows JSON>
//
//  Framed rather than nested so the rows can be encoded exactly ONCE per
//  commit. Nesting the rows inside a `Codable` envelope would mean either
//  encoding 1.25 MB twice (once to digest, once to write) or giving up the
//  identical-payload skip. The header contains no strings, so it can never
//  contain a raw newline.
//
//  Byte-for-byte unchanged by gh#235, deliberately: the delta log is a WRITE
//  STRATEGY, not a format. `RestoreCoordinator`, `BackupSnapshotService` and
//  `SupabaseSyncService` encode rows exactly as before, so `#220`'s Lean civil
//  theorems and the `#152 → #212` projection lineage need no re-proving.
//

import Foundation
import CryptoKit
import os

private let storageLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Done",
    category: "Persistence"
)

private func trail(_ message: String) {
    storageLogger.log("\(message, privacy: .public)")
    DiagnosticTrail.record("Persistence", message)
}

private func trailError(_ message: String) {
    storageLogger.error("\(message, privacy: .public)")
    DiagnosticTrail.record("Persistence", "ERROR " + message)
}

/// `.sortedKeys` is load-bearing, not cosmetic. Without it `JSONEncoder`
/// emits a struct's keys in `Dictionary` iteration order, which varies
/// between calls **within a single process** — measured here, two encodes of
/// the same array produced different key orders in different elements of the
/// same array. That makes byte comparison of two encodes meaningless, so the
/// identical-payload skip below could never fire, and any future "did this
/// file change?" check would be quietly wrong. Measured cost at device scale
/// (2700 events, 1.8 MB): 23.5 ms unsorted vs 26.0 ms sorted.
private let rowEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}()

// MARK: - Types

/// The one-line header that precedes the rows in every slot file.
struct SlotEnvelopeHeader: Codable, Equatable {
    static let currentSchema = 1

    var schema: Int = SlotEnvelopeHeader.currentSchema
    /// Monotonic per slot. Forensic only: a device trail can answer "which
    /// generation did this launch read?" without guessing from timestamps.
    var seq: UInt64
    var writtenAt: Date
    /// True only for the empty envelopes written by "erase all local data".
    /// This is what lets an intentionally-empty store be told apart from a
    /// never-written one, so the sample-data seeder still fires after a wipe
    /// (matching today's behaviour) and never fires over a real store.
    var wiped: Bool
    /// Only `.calendarEvents` uses this. Lives in the SAME file as the rows,
    /// committed by the SAME `rename`, because the timestamp and the shifted
    /// rows are one fact: losing the timestamp while keeping the rows makes
    /// the next launch re-apply the whole elapsed delta on top of already
    /// shifted todos — a silent, permanent corruption of user dates.
    var dominoLastPush: Date?
    var count: Int
}

struct SlotEnvelope<Row: Codable> {
    var header: SlotEnvelopeHeader
    var rows: [Row]
}

enum StorageProvenance: String {
    case primary
    case backup
    case legacyMigrated
}

enum SlotFault: Error, Equatable {
    /// Bytes were read but are not valid JSON. The ONLY case that may move
    /// the file aside.
    case decodeFailed(detail: String, quarantinedAs: String?)
    /// The bytes could not be read at all (EIO, EACCES, protected data
    /// unavailable). Possibly transient, possibly a perfectly good file — so
    /// not one byte is touched.
    case ioError(detail: String)
    case directoryUnavailable(detail: String)
    /// The manifest says this slot was committed, and now neither the primary
    /// nor the backup is there. Never seed over this.
    case lostAfterManifest
    /// The `AtomicValueFile` twin: its own witness (or a quarantine trace)
    /// says the file was committed, and now neither copy is there. A separate
    /// case rather than a reuse, because the EVIDENCE differs — a value file
    /// has no manifest to consult — and a fault the user may have to report
    /// should name the thing that proved it.
    case lostAfterCommit

    var isTransient: Bool {
        switch self {
        case .ioError, .directoryUnavailable: return true
        case .decodeFailed, .lostAfterManifest, .lostAfterCommit: return false
        }
    }
}

enum SlotRead<Row: Codable> {
    /// Provably never written: directory readable, no primary, no backup, no
    /// manifest record, no legacy bytes. The ONLY state that may be seeded.
    case fresh
    case loaded(SlotEnvelope<Row>, StorageProvenance)
    case unreadable(SlotFault)
}

enum WriteIntent {
    case normal
    /// Wipe / restore / cloud-overwrites-local: a large shrink is the point,
    /// so the shrink guard must not snapshot as if it were an accident.
    case destructive
    /// An ordinary write that must land as a whole-array CHECKPOINT rather
    /// than as a delta (gh#235): the background edge that folds the calendar
    /// delta log back into the slot file. Shrink-guarded exactly like
    /// `.normal` — it is an ordinary write, not an intentional shrink — and
    /// distinguished from it only so the delta dispatch can refuse it.
    case checkpointOnly
}

/// How a commit reached the disk (gh#235). Present on EVERY receipt, both
/// paths, so a device A/B can separate the two with `grep mode=` instead of
/// inferring from byte counts.
enum CommitMode: String {
    case checkpoint
    case delta
}

struct CommitReceipt {
    var slot: StorageSlot
    var seq: UInt64
    /// ALWAYS the full folded row count, never the number of changed rows.
    /// The `load: calendar=N` line's comparison against the previous run's
    /// `save calendarEvents: count=M` is a written forensic contract
    /// (`EventStore.load`), and a delta-sized count here would make it report
    /// a catastrophic shrink on every single save.
    var rowCount: Int
    /// The bytes THIS write produced: the encoded rows on the checkpoint
    /// path, the encoded delta record on the delta path (its newline
    /// terminator excluded, which is also the unit the byte bounds judge).
    var bytes: Int
    /// The file's length ON DISK after this write, READ BACK — never assumed.
    /// The checkpoint path `stat`s its temp file and refuses a short write;
    /// the delta path reads the log's end offset back from the open handle
    /// after `fsync` and refuses a short append the same way (round-2 B4). So
    /// the two paths differ in WHICH file they measure (the slot file vs the
    /// log) but not in what the number means.
    var onDiskBytes: Int
    /// Main-thread milliseconds spent encoding. MEASURED on both paths: the
    /// whole array on the checkpoint path, the one delta record on the delta
    /// path. This is the field the gh#235 device A/B is priced in — a delta
    /// row's `encodeMs` against a checkpoint row's `encodeMs=48-70` — so a
    /// hard-coded 0 here would make the ticket unanswerable (round-2 B3).
    var encodeMs: Int
    var writeMs: Int
    /// Main-thread milliseconds spent in `fsync`. Measured on both paths; the
    /// delta path runs one `synchronize()` per append, so this is never
    /// free-by-construction.
    var syncMs: Int
    /// The payload was byte-identical to the last committed one; nothing was
    /// written and `seq` did not advance.
    var skipped: Bool = false

    // gh#235. All defaulted, so every existing producer and consumer keeps
    // its behaviour byte for byte.

    var mode: CommitMode = .checkpoint
    /// Rows carried by this delta. Zero on the checkpoint path.
    var changedRowCount: Int = 0
    /// The delta log's byte size AFTER this commit (zero once checkpointed).
    var logBytes: Int = 0
    /// Delta-log records folded into this checkpoint. Forensic only.
    var foldedRecords: Int = 0
    /// Main-thread cost of diffing against the last persisted array. The one
    /// new cost on the save path, so it is measured rather than assumed.
    var diffMs: Int = 0
    /// Why this landed as a checkpoint instead of a delta, when the slot was
    /// otherwise eligible. Forensic only.
    var reason: String?
    /// The disk now folds to exactly the array the caller handed in, even
    /// though nothing was written.
    ///
    /// NOT the same statement as `skipped`, and the difference is load-bearing
    /// (G5). `skipped` on the checkpoint path is a byte-digest match against
    /// THE LAST CHECKPOINT PAYLOAD, which says nothing about whether an
    /// earlier failed write left memory ahead of disk — so it must not clear
    /// the degraded banner. A `nil` delta is measured against `persisted`,
    /// the last array actually confirmed to disk, so it is positive evidence
    /// that disk has caught up and it MAY clear the banner. Two rules pointing
    /// opposite ways, both correct; this field is what keeps them apart.
    var diskMatchesRequest: Bool = false
}

enum StorageError: Error {
    case directoryUnavailable(String)
    case shortWrite(expected: Int, actual: Int)
    case renameFailed(errno: Int32)
    case slotFrozen(StorageSlot)
    /// The recorded seq cannot be advanced without overflowing. Only reachable
    /// if a seq at `UInt64.max` slipped past the plausibility checks on both
    /// the manifest and the headers — but "unreachable" is exactly what a
    /// checked `+ 1` TRAP would have bet the whole commit path on, and losing
    /// that bet is a crash loop on the first save of every launch. A refused
    /// commit degrades and banners; a trap in the writer recovers never.
    case seqExhausted(StorageSlot)
    /// The `AtomicValueFile` equivalent of `slotFrozen`. Separate case rather
    /// than a synthetic `StorageSlot`, because a value file is not a slot and
    /// giving it one would put it in `StorageSlot.allCases` — where
    /// `sweepUnknownEntries` and the wipe loop would both act on it.
    case valueFileFrozen(name: String)
    /// gh#235 round 3. A `.calendarEvents` delta log is on disk whose records
    /// this process has never managed to read, so the generation it stands on
    /// is unknown — and a checkpoint would clear it. Refusing the write is
    /// what keeps the un-checkpointed edits recoverable at the next launch.
    /// Separate from `slotFrozen` because at the moment it is thrown no fault
    /// has been raised yet: the ONE commit that can run before `read` has
    /// established readability is the restore replay, and it runs first.
    case calendarLogGenerationUnproven
}

// MARK: - Manifest

struct StorageManifest: Codable {
    struct SlotRecord: Codable {
        var everCommitted: Bool = false
        var seq: UInt64 = 0
    }
    var schema: Int = 1
    var slots: [String: SlotRecord] = [:]
    /// Set only at the N+1 step, after legacy bytes have been archived and
    /// removed. Until then legacy keys are frozen, never updated, never
    /// deleted, so downgrading the binary lands the user back on the
    /// migration-time snapshot instead of on nothing.
    var legacyPurged: Bool = false
}

// MARK: - Storage

@MainActor
final class DurableEventStorage {
    /// The ceiling on any seq this class will BELIEVE from disk. Both inputs
    /// it reads seqs from — a slot header and `manifest.json` — are arbitrary
    /// on-disk bytes (bit damage, a tampered backup, any other writer), and a
    /// `UInt64` up to 2^64−1 is perfectly decodable JSON. A believed
    /// `UInt64.max` is not a curiosity: the mint below does `seq + 1`, which
    /// is a checked overflow, so one absurd integer on disk becomes a TRAP in
    /// the writer — a crash loop on the first save of every launch, with no
    /// freeze or quarantine path ever reached because the crash is not in the
    /// reader. 2^48 is one commit per millisecond for nine thousand years;
    /// anything at or above it is evidence of damage, not of history, and is
    /// treated exactly like an unreadable value: no information.
    static let maxPlausibleSeq: UInt64 = 1 << 48

    /// gh#235 kill switch, read at RUNTIME on every calendar commit so a flip
    /// takes effect on the very next save — no relaunch, no new build. Default
    /// ON: the key being absent means the delta path is live.
    ///
    /// Why a switch at all, for the app's ONE irreplaceable slot: the old
    /// whole-array path cannot otherwise be reached again on an install that
    /// already shipped this, so the only field rollback would be a new binary
    /// through review. Flipping it OFF makes every calendar commit a
    /// whole-array checkpoint — which also folds and clears whatever is in the
    /// log, so OFF is a complete return to the pre-gh#235 write path rather
    /// than a half state.
    ///
    ///     (lldb) po UserDefaults.standard.set(false, forKey: "storageCalendarDeltaLogEnabled")
    ///
    /// Read through the store's own defaults (the same object `EventStore` was
    /// constructed with), so a test suite's isolated domain governs its own
    /// storage and never the device's.
    static let calendarDeltaLogEnabledKey = "storageCalendarDeltaLogEnabled"

    let location: EventStorageLocation
    /// Migration source only. Never written to.
    let legacyDefaults: UserDefaults?
    /// Where runtime flags are read from. NEVER written to, and deliberately
    /// a different reference from `legacyDefaults` (which may be nil, and
    /// which this class must never read anything but migration bytes from).
    private let flagDefaults: UserDefaults

    private(set) var directoryURL: URL?
    private(set) var faults: [StorageSlot: SlotFault] = [:]
    private(set) var manifest = StorageManifest()
    /// Set when a legacy blob decoded fine but the readback of the file we
    /// wrote from it did not verify. The session serves the (proven-good)
    /// legacy content and the next ordinary save retries the file write.
    private(set) var migrationPendingSlots: Set<StorageSlot> = []

    /// gh#235. The log-byte bound at which the folded calendar state is
    /// written back into the slot file and the log dropped.
    ///
    /// Bounded on the LOG's bytes, which reset to zero after each checkpoint —
    /// so, unlike `SpikeRunStore`'s pre-fix total-file bound (its R-F3
    /// thrash), a large checkpoint can never make the store re-checkpoint on
    /// every append: the log must always grow a fresh threshold's worth first.
    /// Scaled to the store so a 5 KB new-user install does not carry a 512 KB
    /// log. The arithmetic is pinned by a fixture test, not by this comment.
    static let calendarCompactionFloorBytes = 64 * 1024
    static let calendarCompactionCeilingBytes = 512 * 1024

    static func calendarCompactionThreshold(checkpointBytes: Int) -> Int {
        max(calendarCompactionFloorBytes,
            min(calendarCompactionCeilingBytes, checkpointBytes / 4))
    }

    /// A single delta at or above this fraction of the checkpoint has stopped
    /// being a delta. Judged BEFORE the cumulative bound (G20): any
    /// "keep the newest prefix" eviction degenerates to the empty set when one
    /// record alone exceeds the bound — which is how `MetricPayloadStore`
    /// (575483b) emptied the whole forensic store. Nothing here ever evicts a
    /// record to make room; the oversize delta becomes a checkpoint instead.
    static func calendarSingleDeltaCeiling(checkpointBytes: Int) -> Int {
        max(calendarCompactionFloorBytes / 2, checkpointBytes / 2)
    }

    private var lastCommittedDigest: [StorageSlot: Data] = [:]
    private var lastKnownCount: [StorageSlot: Int] = [:]

    // MARK: gh#235 delta-log state (all `.calendarEvents`)

    private lazy var calendarLog: CalendarDeltaLog? = {
        url(StorageSlot.calendarEvents.deltaFilename).map { CalendarDeltaLog(fileURL: $0) }
    }()

    /// The last array this process actually got onto the disk.
    ///
    /// `nil` means "this process has not established a base", and the delta
    /// path is refused outright until it has — there is nothing to diff
    /// against, and diffing against the in-memory array instead is precisely
    /// the durability regression gh#219's QA pass caught on the conversation
    /// twin (an append that failed, followed by a successful write of
    /// something else, permanently lost the failed write's rows).
    ///
    /// Seeded ONLY from what `read` / `commit` put on disk — never assumed
    /// equal to a previous launch's in-memory array. `Event.init(from:)`
    /// normalises at ingress (recurrence day keys, the legacy
    /// `startTime`/`endTime` → `timeRanges` lift, `location ?? ""`), so
    /// `decode(encode(x)) != x` is reachable for an un-normalised in-memory
    /// value. Seeding from the decode keeps the diff honest in the only
    /// direction that matters: at worst one extra row rides along.
    private var persistedCalendarRows: [Event]?
    /// Whether `persistedCalendarRows` — the BASE the log folds onto — holds
    /// two rows under one id.
    ///
    /// Scanned once per base install (three sites, all through
    /// `installPersistedCalendarRows`) rather than once per save, because the
    /// base changes only at a checkpoint or a read while a save happens on
    /// every drag. `calendarDeltaAttempt` refuses the delta path while it is
    /// true: `CalendarDeltaFold`'s `byID` collapses the duplicate, and an
    /// `order` naming the id twice then folds to two copies of ONE body.
    ///
    /// Round-2 A-F1: scanning only the INCOMING rows (G19) left the whole
    /// base direction uncovered, and the base direction is the one that loses
    /// data. `deleteCalendarEvent` does `removeAll { $0.id == id }`, so
    /// deleting a duplicated id takes BOTH rows out at once: the incoming
    /// array is duplicate-free, the delta path is taken, and the fold that
    /// replays it at the next launch hits `duplicateBaseID` — quarantining
    /// the log and freezing the slot.
    private var persistedCalendarRowsHaveDuplicateID = false
    /// Set when `CalendarDeltaLog.clear()` did NOT get the file off the disk.
    ///
    /// The checkpoint that preceded it is durable and the stale log is
    /// harmless to the next launch (older base ⇒ discarded by generation).
    /// What it is not harmless to is THIS process: an append would put a
    /// record with the new base into a file still holding the old one, and
    /// `plan` quarantines a log whose records disagree about their base. So
    /// the delta path stays refused until a later checkpoint's clear
    /// succeeds — and `calendarDeltaLogIsEmpty` stays false so the background
    /// edge keeps producing those checkpoints.
    private var calendarLogClearFailed = false
    /// Whether this process has ever held the log's records in its hands.
    ///
    /// Written in exactly one place — `noteCalendarLogRead`, which every
    /// `loadRecords()` in this class goes through — so the question "have we
    /// read this log?" has one answer rather than three call sites' opinions.
    /// `[]` from an ABSENT log counts: a store with no log has no unknown
    /// generation, which is the property below.
    private var calendarLogRecordsSeen = false
    /// gh#235 round 3, THE BLOCKING invariant of this file:
    ///
    ///     `commit` never UNLINKS a calendar delta log whose records this
    ///     process has not read.
    ///
    /// True exactly when a log is ON DISK and nothing has proven what
    /// generation it stands on. `read` takes the same posture on the same
    /// fact — `.io` means "possibly a perfectly good file we could not read
    /// this once", freeze, move not one byte, let the next launch recover
    /// (A-F2) — but `read` is NOT the earliest thing that touches this slot.
    /// `EventStore.load()` runs `replayPendingRestoreIfNeeded()` BEFORE
    /// `adopt(.calendarEvents, …)`, so the restore replay is the one commit
    /// in the app that can land while readability is still unestablished,
    /// and it lands `.destructive`:
    ///
    ///   * `reconcileManifestWithPrimaryHeaders` could not read the log, so
    ///     `committedSeq` stays at the stale manifest/header value;
    ///   * the replay's staleness test is `committedSeq(slot) == base`, which
    ///     therefore says "this slot has not moved since the marker";
    ///   * it replays the marker payload as a whole-array checkpoint, whose
    ///     `clearCalendarLog` deletes the log;
    ///   * `commit`'s freeze guard cannot catch it — no fault is registered
    ///     yet, because `read` has not run.
    ///
    /// The result was the branch's own new code destroying recoverable user
    /// edits with no freeze and no banner. Two layers answer it, and they are
    /// deliberately not the same layer: `commit` REFUSES up front (so the
    /// checkpoint never lands, the marker is kept, and the next launch folds
    /// the edits once the log reads), and `clearCalendarLog` quarantines
    /// instead of unlinking (so the bytes survive even for a caller that
    /// somehow gets past the refusal).
    ///
    /// Self-releasing in both directions: a successful read sets
    /// `calendarLogRecordsSeen`, and a log that is no longer on disk is no
    /// longer an unknown generation.
    private var calendarLogGenerationUnproven: Bool {
        // Ordered so the steady state — read once at launch, true forever
        // after — costs no `stat` per save.
        !calendarLogRecordsSeen && (calendarLog?.exists ?? false)
    }
    /// Main-thread milliseconds the last `read` spent inside
    /// `CalendarDeltaFold.fold` — the fold ALONE, not the 2 MB primary read
    /// that precedes it (round-2 B2).
    private var calendarFoldMs = 0
    /// Generation of the checkpoint the log currently extends.
    private var calendarCheckpointSeq: UInt64 = 0
    /// Generation of the folded state (checkpoint seq + record count).
    private var calendarFoldedSeq: UInt64 = 0
    private var calendarLogRecordCount = 0
    private var calendarLogBytes = 0
    /// Encoded size of the rows in the checkpoint the log extends; the scale
    /// both byte bounds are derived from.
    private var calendarCheckpointBytes = 0
    /// Identity of the checkpoint file the log was built against.
    ///
    /// A delta is only meaningful relative to a base that is still THERE and
    /// still the one we read. Without this, a primary that vanished or was
    /// replaced underneath us would keep accepting appends — every one of them
    /// reporting success — onto a base the next launch cannot fold, so the
    /// whole session's work would be quarantined at relaunch while
    /// `saveCalendarEvents()` had been returning `true` throughout. One `stat`
    /// per save buys the check; a mismatch falls back to a whole-array
    /// checkpoint, which also HEALS the base by rewriting it.
    private var calendarBaseSignature: PrimarySignature?

    /// Inode + size + mtime. Catches deletion, truncation, replacement by
    /// another writer, and a non-regular file sitting at the path. It does not
    /// catch in-place bit rot — nothing cheap does — which is the honest cost
    /// of writing the checkpoint ~1000x less often: the whole-array write used
    /// to heal a damaged base on the very next save, and now heals it at the
    /// next checkpoint, i.e. within one backgrounding.
    struct PrimarySignature: Equatable {
        var inode: UInt64
        var size: Int
        var modified: Date?
    }
    /// What `.calendarEvents`' header says about the Domino stamp, as it stands
    /// on disk. `nil` means "not looked at yet" — distinct from a known-absent
    /// stamp, which is `.some(nil)`.
    private var dominoStampOnDisk: Date??
    private var directoryFault: SlotFault?
    /// Simulators and some sandboxes reject the data-protection attribute.
    /// Losing protection must never lose a write, so the first rejection
    /// downgrades for the process lifetime and says so in the trail.
    private var fileProtectionSupported = true

    private let fm = FileManager.default

    init(location: EventStorageLocation, legacyDefaults: UserDefaults?,
         flagDefaults: UserDefaults = .standard) {
        self.location = location
        self.legacyDefaults = legacyDefaults
        self.flagDefaults = flagDefaults
        do {
            directoryURL = try location.directoryURL()
        } catch {
            directoryFault = .directoryUnavailable(detail: String(describing: error))
        }
        _ = ensureDirectory()
        sweepUnknownEntries()
        manifest = readManifest()
        reconcileManifestWithPrimaryHeaders()
    }

    // MARK: - Paths

    private func url(_ component: String) -> URL? {
        directoryURL?.appendingPathComponent(component)
    }

    private var quarantineDirectory: URL? { directoryURL?.appendingPathComponent("quarantine", isDirectory: true) }
    private var snapshotsDirectory: URL? { directoryURL?.appendingPathComponent("snapshots", isDirectory: true) }
    private var pendingDirectory: URL? { directoryURL?.appendingPathComponent("pending", isDirectory: true) }
    private var manifestURL: URL? { url("manifest.json") }
    private var dominoURL: URL? { url("domino.json") }

    private func primaryURL(_ slot: StorageSlot) -> URL? { url(slot.filename) }
    private func backupURL(_ slot: StorageSlot) -> URL? { url(slot.backupFilename) }

    // MARK: - Directory

    @discardableResult
    func ensureDirectory() -> Bool {
        guard let directoryURL else { return false }
        if directoryFault == nil,
           fm.fileExists(atPath: directoryURL.path),
           fm.fileExists(atPath: quarantineDirectory?.path ?? "") {
            return true
        }
        do {
            for dir in [directoryURL, quarantineDirectory, snapshotsDirectory, pendingDirectory] {
                guard let dir else { continue }
                if !fm.fileExists(atPath: dir.path) {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                }
            }
            if fileProtectionSupported {
                do {
                    try fm.setAttributes(
                        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                        ofItemAtPath: directoryURL.path
                    )
                } catch {
                    // Never `.complete`: that class is unreadable before first
                    // unlock, and an unreadable store is treated as a fault the
                    // user is shown. Parity with the old
                    // `Library/Preferences/<bid>.plist` is the goal, and losing
                    // the attribute is not worth failing a write over.
                    fileProtectionSupported = false
                    trail("storage: file protection attribute unavailable, continuing without")
                }
            }
            directoryFault = nil
            return true
        } catch {
            directoryFault = .directoryUnavailable(detail: String(describing: error))
            trailError("storage: directory unavailable: \(error)")
            return false
        }
    }

    /// Everything in this directory is ours, so anything off the whitelist is
    /// debris — most importantly `.tmp-*` left by a commit that was killed
    /// between the write and the rename. Those never participate in a read, so
    /// they are only a disk-space and forensic-noise problem, but sweeping
    /// them keeps "what is in here" answerable.
    private func sweepUnknownEntries() {
        guard let directoryURL, fm.fileExists(atPath: directoryURL.path) else { return }
        var whitelist: Set<String> = ["manifest.json", "domino.json",
                                      "quarantine", "snapshots", "pending", "legacy-archive"]
        for slot in StorageSlot.allCases {
            whitelist.insert(slot.filename)
            whitelist.insert(slot.backupFilename)
            // gh#235. This sweep runs in `init`, BEFORE any read, and deletes
            // whatever is not listed here without raising or trailing — so a
            // missing entry would silently destroy every un-checkpointed
            // calendar edit on every cold launch. Derived from the slot, never
            // written out as a literal, so the day a second slot starts
            // logging it is covered by construction.
            whitelist.insert(slot.deltaFilename)
        }
        guard let entries = try? fm.contentsOfDirectory(atPath: directoryURL.path) else { return }
        var swept = 0
        for entry in entries where !whitelist.contains(entry) {
            try? fm.removeItem(at: directoryURL.appendingPathComponent(entry))
            swept += 1
        }
        if swept > 0 { trail("storage: swept \(swept) stray entr\(swept == 1 ? "y" : "ies")") }
    }

    /// Push the directory's metadata (and the drive's own cache) all the way
    /// down. Deliberately NOT on the per-save path — the observed failure is
    /// process death, which a plain `write` already survives, and this app is
    /// under active frame-drop investigation. Called from the app's
    /// background/terminate sinks.
    func syncDirectoryToStableStorage() {
        guard let directoryURL else { return }
        let fd = open(directoryURL.path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        if fcntl(fd, F_FULLFSYNC) == -1 { _ = fsync(fd) }
    }

    // MARK: - Faults

    func isFrozen(_ slot: StorageSlot) -> Bool { faults[slot] != nil }
    var hasAnyFault: Bool { !faults.isEmpty }

    /// Only ever called from inside a user-confirmed restore. Automatic paths
    /// must never unfreeze — a frozen slot presents as empty, and an automatic
    /// unfreeze would let the next ordinary save write that emptiness down.
    func clearFaults() {
        faults.removeAll()
        migrationPendingSlots.removeAll()
    }

    private func raise(_ fault: SlotFault, on slot: StorageSlot) {
        faults[slot] = fault
        trailError("storage: slot=\(slot.rawValue) FROZEN \(fault)")
    }

    // MARK: - Reading

    func read<Row: Codable>(_ slot: StorageSlot, as type: Row.Type) -> SlotRead<Row> {
        guard ensureDirectory(), directoryURL != nil else {
            // With the directory unreadable we cannot prove anything is
            // absent, so `.fresh` (the only seedable state) is unreachable by
            // construction. Reads fall back to legacy so the user still sees
            // their data; every write is refused while the fault stands.
            let fault = directoryFault ?? .directoryUnavailable(detail: "unknown")
            raise(fault, on: slot)
            if let rows: [Row] = decodedLegacyRows(slot) {
                trail("storage: slot=\(slot.rawValue) read from legacy (directory unavailable) count=\(rows.count)")
                let header = SlotEnvelopeHeader(seq: 0, writtenAt: Date(), wiped: false,
                                                dominoLastPush: nil, count: rows.count)
                lastKnownCount[slot] = rows.count
                return .loaded(SlotEnvelope(header: header, rows: rows), .legacyMigrated)
            }
            return .unreadable(fault)
        }

        // gh#235. The calendar's delta log is resolved HERE, before any branch
        // below can issue an internal commit — because `commit` clears the log
        // on success, and a backup promotion or a legacy migration commits
        // from inside this function. Getting this ordering wrong would let a
        // promotion silently drop the deltas it was supposed to be caught out
        // by (P7), serving a whole generation of edits back as if the user had
        // never made them.
        var calendarRecords: [CalendarDeltaRecord] = []
        if slot == .calendarEvents {
            guard let records = loadCalendarRecordsForRead(slot) else {
                // Round-2 A-F2. The two refusals get the two postures this
                // file already takes on the PRIMARY, and for the same reasons:
                // `.io` means "possibly a perfectly good file we could not
                // read this once", so not one byte moves; `.decode` means the
                // bytes are proven bad, so they go to quarantine. Either way
                // the slot FREEZES — which is what closes the three export
                // gates (`diffSync`'s cloud DELETEs, the DR snapshot, the
                // asset sweep) rather than serving a silently shorter array.
                let fault: SlotFault
                switch calendarLog?.loadFault {
                case .io(let detail):
                    fault = .ioError(detail: "calendar delta log unreadable: \(detail)")
                default:
                    fault = .decodeFailed(
                        detail: "calendar delta log undecodable",
                        quarantinedAs: quarantineCalendarLog(reason: "undecodable committed record")
                    )
                }
                raise(fault, on: slot)
                return .unreadable(fault)
            }
            calendarRecords = records
        }

        // (a) primary present
        if let primary = primaryURL(slot), fm.fileExists(atPath: primary.path) {
            switch readEnvelope(at: primary, as: Row.self) {
            case .success(let envelope):
                guard let folded: SlotEnvelope<Row> = foldCalendarLog(into: envelope, slot: slot,
                                                                      records: calendarRecords,
                                                                      primary: primary) else {
                    // Round-2 B1, belt to `foldCalendarLog`'s braces. Every
                    // arm in there raises before returning nil; if one ever
                    // stops doing so, this REGISTERS the fault it invents
                    // rather than returning `.unreadable` with the slot left
                    // unfrozen. `EventStore.adopt` documents "`read` never
                    // returns `.unreadable` without raising" as an invariant
                    // and hands an empty array to three export gates when it
                    // is false.
                    guard let existing = faults[slot] else {
                        let fault = SlotFault.decodeFailed(detail: "calendar delta fold refused",
                                                           quarantinedAs: nil)
                        raise(fault, on: slot)
                        return .unreadable(fault)
                    }
                    return .unreadable(existing)
                }
                lastKnownCount[slot] = folded.rows.count
                trail("storage: slot=\(slot.rawValue) read primary seq=\(envelope.header.seq) count=\(folded.rows.count)"
                      + (calendarLogRecordCount > 0
                         ? " deltaRecords=\(calendarLogRecordCount) deltaBytes=\(calendarLogBytes)" : ""))
                return .loaded(folded, .primary)
            case .io(let detail):
                // Not one byte moves. Renaming a file that is merely
                // unreadable-right-now turns a transient failure into a
                // permanent loss.
                raise(.ioError(detail: detail), on: slot)
                return .unreadable(.ioError(detail: detail))
            case .decode(let detail):
                // Order matters twice over. The corrupt primary is moved aside
                // FIRST, unchanged from before — a frozen slot must never be
                // left with unreadable bytes under its own name.
                let quarantined = quarantineAside(primary, slot: slot, tag: "corrupt")
                trailError("storage: slot=\(slot.rawValue) primary corrupt, quarantined as \(quarantined ?? "<failed>")")
                // THEN the one place gh#235 deliberately TIGHTENS existing
                // behaviour, and it has to come before `promoteBackup`, whose
                // internal commit would clear the log. A corrupt primary with
                // a non-empty log means the recovery about to run would serve
                // an OLDER generation and drop this one's deltas — and a
                // promotion raises no fault and lights no banner, so that loss
                // would be invisible while `diffSync` DELETEs the difference in
                // the cloud. A corrupt primary with an EMPTY log keeps today's
                // behaviour to the letter.
                if let fault = refuseCalendarPromotionWithLiveLog(slot, records: calendarRecords,
                                                                  detail: detail) {
                    return .unreadable(fault)
                }
                if let promoted: SlotEnvelope<Row> = promoteBackup(slot) {
                    return .loaded(promoted, .backup)
                }
                let fault = SlotFault.decodeFailed(detail: detail, quarantinedAs: quarantined)
                raise(fault, on: slot)
                return .unreadable(fault)
            }
        }

        // (b) primary absent, backup present
        if let backup = backupURL(slot), fm.fileExists(atPath: backup.path) {
            if let fault = refuseCalendarPromotionWithLiveLog(slot, records: calendarRecords,
                                                              detail: "primary absent") {
                return .unreadable(fault)
            }
            if let promoted: SlotEnvelope<Row> = promoteBackup(slot) {
                return .loaded(promoted, .backup)
            }
            // Backup exists but is unusable; fall through only if it is also
            // absent-shaped. Treat as a fault rather than seeding over it.
            let fault = SlotFault.decodeFailed(detail: "backup unusable", quarantinedAs: nil)
            raise(fault, on: slot)
            return .unreadable(fault)
        }

        // (c) neither exists
        // A delta log is evidence that this slot WAS committed, ranking with
        // `manifest.everCommitted` — so `.fresh` is unreachable while one
        // stands. Without this, folding onto `[]` yields an empty array, and
        // `rawCalendarEvents.isEmpty && isSeedable` both being true has six
        // demo rows overwrite the last trace of the real store. `EventStore`'s
        // three seed gates guard against a failed READ; they are blind to a
        // base that vanished while its log survived.
        if slot == .calendarEvents, !calendarRecords.isEmpty {
            trailError("storage: slot=\(slot.rawValue) has \(calendarRecords.count) delta record(s) but neither primary nor backup")
            raise(.lostAfterManifest, on: slot)
            return .unreadable(.lostAfterManifest)
        }
        if manifest.slots[slot.rawValue]?.everCommitted == true {
            raise(.lostAfterManifest, on: slot)
            return .unreadable(.lostAfterManifest)
        }
        if manifest.legacyPurged { return .fresh }
        guard location.migratesLegacyDefaults, let legacyDefaults else { return .fresh }
        guard let legacyBytes = legacyDefaults.data(forKey: slot.legacyDefaultsKey) else { return .fresh }

        let rows: [Row]
        do {
            rows = try JSONDecoder().decode([Row].self, from: legacyBytes)
        } catch {
            // Bytes exist and are unreadable: keep them for forensics and
            // freeze. Seeding here would write demo rows over a user's real
            // (if damaged) data.
            let name = writeLegacyQuarantine(legacyBytes, slot: slot)
            let fault = SlotFault.decodeFailed(detail: String(describing: error), quarantinedAs: name)
            raise(fault, on: slot)
            return .unreadable(fault)
        }

        // Migration. Legacy is never mutated here — not updated, not deleted.
        // Every kill point during this leaves either (legacy only) or
        // (legacy + a complete file), both of which are correct on the next
        // launch. "A file exists" is an absolute rule: once it does, the
        // legacy key is dead data and is never read, merged or compared again.
        do {
            let receipt = try commit(rows, to: slot, intent: .destructive)
            if let verified: [Row] = verifyReadback(slot, expecting: rows.count, as: Row.self) {
                markCommitted(slot, seq: receipt.seq)
                trail("storage: slot=\(slot.rawValue) MIGRATED from legacy count=\(verified.count) bytes=\(receipt.bytes)")
                let header = SlotEnvelopeHeader(seq: receipt.seq, writtenAt: Date(), wiped: false,
                                                dominoLastPush: nil, count: verified.count)
                return .loaded(SlotEnvelope(header: header, rows: verified), .legacyMigrated)
            }
            migrationPendingSlots.insert(slot)
            trailError("storage: slot=\(slot.rawValue) migration readback failed; serving legacy content, will retry on next save")
        } catch {
            migrationPendingSlots.insert(slot)
            trailError("storage: slot=\(slot.rawValue) migration write failed: \(error); serving legacy content")
        }
        // The CONTENT is proven good (it decoded), so writing it later is safe
        // and the slot is deliberately NOT frozen.
        lastKnownCount[slot] = rows.count
        let header = SlotEnvelopeHeader(seq: 0, writtenAt: Date(), wiped: false,
                                        dominoLastPush: nil, count: rows.count)
        return .loaded(SlotEnvelope(header: header, rows: rows), .legacyMigrated)
    }

    // MARK: - Calendar delta log (gh#235)

    /// True while the calendar's folded state is the checkpoint alone.
    /// The background edge asks this so it only pays a 2 MB checkpoint when
    /// there is actually something to fold.
    ///
    /// `calendarLogClearFailed` counts as NOT empty on purpose: the file is
    /// still on the disk, the delta path is refused while it is, and the
    /// background edge is the thing that retries the clear.
    var calendarDeltaLogIsEmpty: Bool { calendarLogRecordCount == 0 && !calendarLogClearFailed }
    var calendarDeltaLogRecordCount: Int { calendarLogRecordCount }
    var calendarDeltaLogBytes: Int { calendarLogBytes }
    /// Milliseconds the last `read` spent in `CalendarDeltaFold.fold`.
    ///
    /// The FOLD, and nothing else. `EventStore.load` separately times the
    /// whole `adopt(.calendarEvents, …)` — which is dominated by reading and
    /// decoding the 2 MB primary and would be paid with or without gh#235 —
    /// and reports that as `calendarReadMs`. Round 1 had one number labelled
    /// `foldMs` doing both jobs, which reported the entire slot decode as the
    /// new mechanism's cost in the expected steady state (an empty log at a
    /// normal cold start). This is the number that answers "did gh#235 slow
    /// the launch down?"; that one answers "how long does the calendar take
    /// to load?".
    var calendarDeltaLogFoldMs: Int { calendarFoldMs }

    /// The single place the delta-fold base is installed, so the duplicate-id
    /// scan cannot be forgotten at one of the three sites (round-2 A-F1).
    ///
    /// `knownDuplicateFree` skips the O(n) scan for the one caller that has
    /// ALREADY scanned these exact rows this turn — `calendarDeltaAttempt`,
    /// whose incoming-row guard runs a few lines earlier.
    private func installPersistedCalendarRows(_ rows: [Event]?, knownDuplicateFree: Bool = false) {
        persistedCalendarRows = rows
        guard let rows, !knownDuplicateFree else {
            persistedCalendarRowsHaveDuplicateID = false
            return
        }
        var seen = Set<UUID>()
        seen.reserveCapacity(rows.count)
        persistedCalendarRowsHaveDuplicateID = rows.contains { !seen.insert($0.id).inserted }
    }

    /// The one writer of `calendarLogRecordsSeen`. Every `loadRecords()` in
    /// this class is spelled `noteCalendarLogRead(log.loadRecords())` so that
    /// a fourth reader added later cannot forget to answer the question the
    /// destructive paths ask (`calendarLogGenerationUnproven`).
    @discardableResult
    private func noteCalendarLogRead(_ records: [CalendarDeltaRecord]?) -> [CalendarDeltaRecord]? {
        if records != nil { calendarLogRecordsSeen = true }
        return records
    }

    /// Clear the log and keep the in-memory view honest about whether that
    /// worked. See `calendarLogClearFailed`.
    ///
    /// Round 3: the UNLINK is conditional on this process having read the
    /// file — see `calendarLogGenerationUnproven` for the restore-replay path
    /// that reaches a clear before `read` has established readability. The
    /// wipe purge is deliberately NOT special-cased: it routes through here
    /// too, its log lands in `quarantine/`, and the very next thing
    /// `purgeAuxiliaryCopies` does is delete every `quarantine/` entry for
    /// this slot — so an erase still erases, through one code path rather
    /// than two.
    @discardableResult
    private func clearCalendarLog(context: String) -> Bool {
        guard let log = calendarLog else {
            resetCalendarLogState()
            calendarLogClearFailed = false
            return true
        }
        if calendarLogGenerationUnproven {
            trailError("storage: calendar delta log cleared (\(context)) without this process ever reading it; quarantining instead of deleting")
            guard quarantineCalendarLog(reason: "generation unproven at clear (\(context))") != nil else {
                // Quarantine failed, so the file is still exactly where it
                // was — which is the outcome this branch wanted anyway. Latch
                // as a failed clear so the delta path stays off.
                resetCalendarLogState()
                calendarLogClearFailed = true
                return false
            }
            return true
        }
        if log.clear() {
            resetCalendarLogState()
            calendarLogClearFailed = false
            return true
        }
        trailError("storage: calendar delta log could not be cleared (\(context)); delta path disabled until it is")
        resetCalendarLogState()
        calendarLogClearFailed = true
        return false
    }

    /// Records for `read`. `nil` means a COMPLETE record would not decode —
    /// genuine corruption, never a torn tail.
    private func loadCalendarRecordsForRead(_ slot: StorageSlot) -> [CalendarDeltaRecord]? {
        guard slot == .calendarEvents, let log = calendarLog else { return [] }
        guard let records = noteCalendarLogRead(log.loadRecords()) else { return nil }
        calendarLogRecordCount = records.count
        calendarLogBytes = records.isEmpty ? 0 : log.byteSize
        return records
    }

    /// Move the log aside and forget it. This IS the unfreeze exit: `faults`
    /// is in-memory state rebuilt by every launch's `read`, so a log that is
    /// no longer there cannot re-freeze the next launch — the user lands back
    /// on the checkpoint with no new UI, and the deltas stay in `quarantine/`
    /// for support to retrieve.
    ///
    /// The cost has to be stated honestly: the user silently loses the
    /// un-checkpointed edits at the NEXT launch. This session's banner and the
    /// `load: calendar=N` versus previous `save calendarEvents: count=M`
    /// comparison are the only channels that say so.
    ///
    /// Round 3 gave it a second kind of caller. The `read`-side ones above are
    /// verdicts on a file judged BAD; `clearCalendarLog` calls it for a file
    /// judged only UNREAD, to keep the bytes when a delete was asked for. The
    /// "user loses the edits" cost does not apply there, because the only
    /// caller that reaches it is a wipe — see `clearCalendarLog`.
    @discardableResult
    private func quarantineCalendarLog(reason: String) -> String? {
        guard let log = calendarLog else { return nil }
        let name = "\(StorageSlot.calendarEvents.rawValue)-deltalog-\(timestampComponent()).log"
        let landed = log.quarantine(into: quarantineDirectory, named: name)
        trailError("storage: calendar delta log quarantined (\(reason)) as \(landed ?? "<failed>")")
        resetCalendarLogState()
        // A landed quarantine got the file off the path just as a clear would,
        // so it also releases the "could not delete it" latch; a FAILED one
        // leaves the file exactly where it was, and the latch with it.
        if landed != nil { calendarLogClearFailed = false }
        return landed
    }

    private func resetCalendarLogState() {
        calendarLogRecordCount = 0
        calendarLogBytes = 0
    }

    /// A backup promotion (or any other route that serves an OLDER
    /// generation) must not run while a log stands on top of the newer one.
    /// Returns the fault to surface, or nil when the promotion may proceed
    /// exactly as it does today.
    private func refuseCalendarPromotionWithLiveLog(_ slot: StorageSlot,
                                                    records: [CalendarDeltaRecord],
                                                    detail: String) -> SlotFault? {
        guard slot == .calendarEvents, !records.isEmpty else { return nil }
        let quarantined = quarantineCalendarLog(reason: "base lost or corrupt while \(records.count) delta record(s) stood on it")
        let fault = SlotFault.decodeFailed(
            detail: "calendar base unusable (\(detail)) with a live delta log",
            quarantinedAs: quarantined
        )
        raise(fault, on: slot)
        return fault
    }

    /// Turn a checkpoint envelope plus the log into the envelope the rest of
    /// the app sees.
    ///
    /// Returning the FOLDED header — not the checkpoint's — is what keeps
    /// every downstream consumer at zero changes: `adopt`'s `slotSeq`,
    /// `loadedDominoStamp`, the seedable decision, and the `load:` forensic
    /// line all read the header and are all automatically right.
    /// Returns nil once a fault has been raised.
    private func foldCalendarLog<Row: Codable>(into envelope: SlotEnvelope<Row>,
                                               slot: StorageSlot,
                                               records: [CalendarDeltaRecord],
                                               primary: URL) -> SlotEnvelope<Row>? {
        guard slot == .calendarEvents else { return envelope }

        calendarCheckpointSeq = envelope.header.seq
        calendarFoldedSeq = envelope.header.seq
        calendarCheckpointBytes = checkpointRowBytes(at: primary)
        calendarBaseSignature = primarySignature(slot)

        calendarFoldMs = 0
        switch CalendarDeltaFold.plan(checkpointSeq: envelope.header.seq, records: records) {
        case .useCheckpoint:
            resetCalendarLogState()
            calendarLogClearFailed = false
            installPersistedCalendarRows(envelope.rows as? [Event])
            dominoStampOnDisk = .some(envelope.header.dominoLastPush)
            noteCalendarGeneration(envelope.header.seq)
            return envelope

        case .discardLog(let why):
            // The kill-between-rename-and-clear window. Generations settle it
            // outright: the checkpoint already contains (or replaced) these
            // deltas, so replaying them is unnecessary — which is a stronger
            // statement than the fold's idempotence, and needs no bodies read.
            trail("storage: calendar delta log discarded — \(why)")
            clearCalendarLog(context: "stale log discarded by generation")
            installPersistedCalendarRows(envelope.rows as? [Event])
            dominoStampOnDisk = .some(envelope.header.dominoLastPush)
            noteCalendarGeneration(envelope.header.seq)
            return envelope

        case .quarantine(let why):
            let quarantined = quarantineCalendarLog(reason: why)
            raise(.decodeFailed(detail: "calendar delta log: \(why)", quarantinedAs: quarantined),
                  on: slot)
            return nil

        case .fold:
            guard let base = envelope.rows as? [Event] else {
                // Unreachable in the app: `.calendarEvents` is `[Event]`
                // everywhere. Reachable in a test that commits a foreign row
                // type to this slot — and freezing is the only honest answer,
                // since the records hold `Event` bodies this reader cannot
                // put back. Never silent: gh#202's `as?`-skip family.
                trailError("storage: calendar delta log present but rows are not [Event]; refusing to fold")
                raise(.decodeFailed(detail: "calendar delta log read with a non-Event row type",
                                    quarantinedAs: nil), on: slot)
                return nil
            }
            let foldStart = Date()
            let outcome = CalendarDeltaFold.fold(base: base, baseSeq: envelope.header.seq,
                                                 baseStamp: envelope.header.dominoLastPush,
                                                 records: records)
            calendarFoldMs = Int(Date().timeIntervalSince(foldStart) * 1000)
            switch outcome {
            case .failure(let fault):
                let quarantined = quarantineCalendarLog(reason: fault.detail)
                raise(.decodeFailed(detail: "calendar delta fold: \(fault.detail)",
                                    quarantinedAs: quarantined), on: slot)
                return nil
            case .success(let folded):
                guard let rows = folded.rows as? [Row] else {
                    // Round-2 B1. This was `return nil` with no `raise`, which
                    // made it the ONE exit from `read` that answers
                    // `.unreadable` while leaving the slot UNFROZEN — so
                    // `adopt` returns [] with `isSlotFrozen` false, and the
                    // three export gates (`diffSync`'s cloud DELETEs, the DR
                    // snapshot, the orphan-asset sweep that unlinks photos)
                    // all act on an empty calendar. Its sibling ten lines
                    // above already promises this family is never silent.
                    // Unreachable in the app (`.calendarEvents` is `[Event]`
                    // everywhere); reachable from the generic-row fixtures in
                    // `DurableEventStorageTests`.
                    trailError("storage: calendar delta fold produced [Event] the caller cannot take as \(Row.self); refusing to serve")
                    raise(.decodeFailed(detail: "calendar delta fold row type mismatch",
                                        quarantinedAs: nil), on: slot)
                    return nil
                }
                var header = envelope.header
                header.seq = folded.seq
                header.count = folded.rows.count
                header.dominoLastPush = folded.dominoLastPush
                // A wiped checkpoint with live deltas on top is NOT a wiped
                // store: the user erased everything and then created
                // something. Left at `true`, `EventStore.adopt` would call
                // `purgeAuxiliaryCopies` on every launch — which deletes the
                // log the new events live in.
                header.wiped = envelope.header.wiped && records.isEmpty
                installPersistedCalendarRows(folded.rows)
                dominoStampOnDisk = .some(folded.dominoLastPush)
                calendarFoldedSeq = folded.seq
                noteCalendarGeneration(folded.seq)
                return SlotEnvelope(header: header, rows: rows)
            }
        }
    }

    /// The checkpoint's ROW bytes, as the byte bounds measure them. The header
    /// line is a couple of hundred bytes on a multi-megabyte file, so the
    /// whole-file size stands in for it; being a little generous errs towards
    /// a larger threshold, i.e. fewer checkpoints, never more.
    private func checkpointRowBytes(at primary: URL) -> Int {
        ((try? fm.attributesOfItem(atPath: primary.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// `nil` when nothing usable is at the path — including a directory, which
    /// is exactly what a jammed-slot fixture puts there and what a botched
    /// external repair could leave behind.
    private func primarySignature(_ slot: StorageSlot) -> PrimarySignature? {
        guard let primary = primaryURL(slot),
              let attributes = try? fm.attributesOfItem(atPath: primary.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular else { return nil }
        return PrimarySignature(
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            size: (attributes[.size] as? NSNumber)?.intValue ?? -1,
            modified: attributes[.modificationDate] as? Date
        )
    }

    /// Record a calendar generation in the IN-MEMORY manifest without writing
    /// `manifest.json`.
    ///
    /// An append is a real write and must advance `committedSeq` — the restore
    /// marker's `committedSeq(slot) == base` staleness test is what stops an
    /// abandoned marker from resurrecting weeks later and `.destructive`-ally
    /// overwriting everything the user did since. The DURABLE evidence is the
    /// log itself (each record carries its `seq`), and
    /// `reconcileManifestWithPrimaryHeaders` rebuilds the generation from the
    /// log's tail on the next launch — so this costs zero extra file writes
    /// per save. This class already tolerates a manifest lagging its primaries
    /// and reconciles for exactly that reason.
    private func noteCalendarGeneration(_ seq: UInt64) {
        var record = manifest.slots[StorageSlot.calendarEvents.rawValue] ?? .init()
        guard seq > record.seq || !record.everCommitted else { return }
        record.everCommitted = true
        record.seq = max(record.seq, seq)
        manifest.slots[StorageSlot.calendarEvents.rawValue] = record
    }

    private func decodedLegacyRows<Row: Codable>(_ slot: StorageSlot) -> [Row]? {
        guard location.migratesLegacyDefaults,
              let data = legacyDefaults?.data(forKey: slot.legacyDefaultsKey),
              let rows = try? JSONDecoder().decode([Row].self, from: data) else { return nil }
        return rows
    }

    private func promoteBackup<Row: Codable>(_ slot: StorageSlot) -> SlotEnvelope<Row>? {
        guard let backup = backupURL(slot), fm.fileExists(atPath: backup.path) else { return nil }
        guard case .success(let envelope) = readEnvelope(at: backup, as: Row.self) else { return nil }
        lastKnownCount[slot] = envelope.rows.count
        // Put the good copy back under the primary name immediately: leaving
        // the store running off a `.bak` means the next crash finds "primary
        // absent" again and the recovery is re-derived every launch.
        do {
            let receipt = try commit(envelope.rows, to: slot,
                                     dominoLastPush: envelope.header.dominoLastPush,
                                     wiped: envelope.header.wiped,
                                     intent: .destructive)
            trail("storage: slot=\(slot.rawValue) RECOVERED from backup count=\(envelope.rows.count) newSeq=\(receipt.seq)")
        } catch {
            trailError("storage: slot=\(slot.rawValue) backup recovered but could not be written back: \(error)")
        }
        return envelope
    }

    private func verifyReadback<Row: Codable>(_ slot: StorageSlot, expecting count: Int,
                                              as type: Row.Type) -> [Row]? {
        guard let primary = primaryURL(slot),
              case .success(let envelope) = readEnvelope(at: primary, as: Row.self),
              envelope.rows.count == count else { return nil }
        return envelope.rows
    }

    private enum EnvelopeReadResult<Row: Codable> {
        case success(SlotEnvelope<Row>)
        case io(String)
        case decode(String)
    }

    private func readEnvelope<Row: Codable>(at url: URL, as type: Row.Type) -> EnvelopeReadResult<Row> {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [])
        } catch {
            return .io(String(describing: error))
        }
        guard let newline = data.firstIndex(of: 0x0A) else {
            return .decode("no header terminator")
        }
        do {
            let header = try JSONDecoder().decode(SlotEnvelopeHeader.self,
                                                  from: data[data.startIndex..<newline])
            let rows = try JSONDecoder().decode([Row].self, from: data[(newline + 1)...])
            return .success(SlotEnvelope(header: header, rows: rows))
        } catch {
            return .decode(String(describing: error))
        }
    }

    // MARK: - Writing

    @discardableResult
    func commit<Row: Codable>(_ rows: [Row], to slot: StorageSlot,
                              dominoLastPush: Date? = nil,
                              wiped: Bool = false,
                              intent: WriteIntent = .normal) throws -> CommitReceipt {
        // The freeze rule enforced HERE rather than only at the call site.
        // A frozen slot's in-memory array is not a faithful copy of the file
        // (the read failed, or it was served from the frozen legacy snapshot),
        // so writing it destroys the file. `EventStore.persist` checks its own
        // mirror of this first for the user-facing message; this guard is what
        // makes "forgot to ask" impossible — including for the writes this
        // class issues internally (migration, backup promotion).
        guard faults[slot] == nil else { throw StorageError.slotFrozen(slot) }

        // gh#235 round 3, and it sits HERE for the same reason the freeze
        // guard does: the caller that trips it is not one any `EventStore`
        // branch could gate, because it runs before `EventStore` has read
        // anything. See `calendarLogGenerationUnproven` for the full path.
        //
        // Refusing BEFORE the encode — not just refusing to unlink afterwards
        // — is what makes the next launch able to fold the edits rather than
        // merely able to find their bytes. A checkpoint that lands puts a
        // NEWER seq on the primary, and `CalendarDeltaFold.plan` then discards
        // a log whose records stand on the older base (`.discardLog`, by
        // generation). So "the log survives" and "the edits survive" are only
        // the same statement while no checkpoint has landed on top of it.
        //
        // The refusal is not a loss: `replayPendingRestoreIfNeeded` keeps its
        // marker whenever a slot's write fails, and the reconcile that could
        // not read the log this launch will read it the next one — at which
        // point the tail advances `committedSeq`, the marker is correctly
        // judged stale, and `read` folds the edits in.
        //
        // `wiped` is the deliberate exception. An erase is the user asking
        // for exactly these bytes to go, and the wipe's own purge routes
        // through `clearCalendarLog` → quarantine → the `quarantine/` sweep,
        // so nothing is left behind by letting it through.
        if slot == .calendarEvents, !wiped, calendarLogGenerationUnproven {
            trailError("storage: slot=\(slot.rawValue) commit REFUSED — a delta log is on disk that this"
                       + " process has never read; its un-checkpointed edits stay recoverable")
            throw StorageError.calendarLogGenerationUnproven
        }

        guard ensureDirectory(), let directoryURL, let primary = primaryURL(slot) else {
            throw StorageError.directoryUnavailable(String(describing: directoryFault))
        }

        // gh#235. The delta dispatch sits INSIDE `commit`, above the encode it
        // exists to avoid, for the same reason the freeze guard does: `commit`
        // has three call sites, two of them internal to this class (legacy
        // migration, backup promotion) that an `EventStore`-level branch could
        // never see. A `.destructive` write — wipe, restore replay, migration,
        // promotion — always lands as a whole-array checkpoint, which is what
        // removes those four from the delta path's reasoning entirely instead
        // of relying on each caller to remember.
        var deltaFallbackReason: String?
        // Round-2 B8: `calendarDeltaAttempt` takes the shrink snapshot itself
        // when it is about to append. If it then falls back, the checkpoint
        // below must NOT snapshot the same shrink a second time — three kept
        // generations would lose two to one bulk delete.
        var shrinkGuardAlreadyApplied = false
        if slot == .calendarEvents {
            switch intent {
            case .destructive: deltaFallbackReason = "destructive"
            case .checkpointOnly: deltaFallbackReason = "background"
            case .normal where wiped: deltaFallbackReason = "wiped"
            case .normal where !calendarDeltaLogEnabled:
                // Round-2 B7. The runtime kill switch, judged here rather
                // than at any call site for the same reason the whole
                // dispatch is: a checkpoint is a COMPLETE return to the
                // pre-gh#235 path, because the rename below folds and clears
                // whatever the log still holds.
                deltaFallbackReason = "killSwitch"
            case .normal:
                if let events = rows as? [Event] {
                    switch calendarDeltaAttempt(events, dominoLastPush: dominoLastPush) {
                    case .committed(let receipt): return receipt
                    case .fallback(let why, let guarded):
                        deltaFallbackReason = why
                        shrinkGuardAlreadyApplied = guarded
                    }
                } else {
                    // Never silent (gh#202's `as?`-skip family): falling back
                    // to a checkpoint is the safe default, but a calendar slot
                    // holding something other than `[Event]` is a fact the
                    // trail has to carry. Deliberately not an
                    // `assertionFailure`: `DurableEventStorageTests` exercises
                    // this slot with a generic row type on purpose, and
                    // trapping there would convert a test fixture into a crash.
                    deltaFallbackReason = "nonEventRows"
                    trailError("storage: calendarEvents commit with non-[Event] rows; delta path skipped")
                }
            }
        }

        let encodeStart = Date()
        let rowsData = try rowEncoder.encode(rows)
        let encodeMs = Int(Date().timeIntervalSince(encodeStart) * 1000)

        let digest = payloadDigest(rowsData, wiped: wiped, dominoLastPush: dominoLastPush)
        // The digest proves "these bytes equal the last CHECKPOINT payload",
        // which stops being the same as "the disk already holds this array"
        // the moment a delta log stands on top of that checkpoint. Skipping
        // then would report success while leaving the disk folding to
        // something else entirely.
        let logStandsOnCheckpoint = slot == .calendarEvents
            && (calendarLogRecordCount > 0 || calendarLogClearFailed)
        if !logStandsOnCheckpoint, lastCommittedDigest[slot] == digest {
            return CommitReceipt(slot: slot, seq: manifest.slots[slot.rawValue]?.seq ?? 0,
                                 rowCount: rows.count, bytes: rowsData.count, onDiskBytes: 0,
                                 encodeMs: encodeMs, writeMs: 0, syncMs: 0, skipped: true,
                                 reason: deltaFallbackReason)
        }

        if !shrinkGuardAlreadyApplied {
            applyShrinkGuard(slot: slot, newCount: rows.count, intent: intent)
        }

        // `+ 1` on a UInt64 is a checked overflow. The plausibility checks in
        // `readManifest` and `reconcileManifestWithPrimaryHeaders` should make
        // a near-max seq unreachable here, but this is the line that would
        // TRAP if they ever miss one, so it refuses for itself: a refused
        // commit is a degraded-save banner, a trap is a crash loop.
        let committed = manifest.slots[slot.rawValue]?.seq ?? 0
        guard committed < UInt64.max else {
            trailError("storage: slot=\(slot.rawValue) seq \(committed) cannot advance; commit refused")
            throw StorageError.seqExhausted(slot)
        }
        let seq = committed + 1
        let header = SlotEnvelopeHeader(seq: seq, writtenAt: Date(), wiped: wiped,
                                        dominoLastPush: dominoLastPush, count: rows.count)
        var data = try rowEncoder.encode(header)
        data.append(0x0A)
        data.append(rowsData)

        let tmp = directoryURL.appendingPathComponent(".tmp-\(slot.rawValue)-\(UUID().uuidString)")
        let writeStart = Date()
        do {
            try writeProtected(data, to: tmp)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        let writeMs = Int(Date().timeIntervalSince(writeStart) * 1000)

        let syncStart = Date()
        do {
            let handle = try FileHandle(forWritingTo: tmp)
            try handle.synchronize()
            try handle.close()
        } catch {
            // fsync is the power-loss insurance, not the process-death fix.
            // Failing the whole commit over it would trade a real guarantee
            // for a speculative one.
            trailError("storage: slot=\(slot.rawValue) fsync failed (continuing): \(error)")
        }
        let syncMs = Int(Date().timeIntervalSince(syncStart) * 1000)

        let onDisk = ((try? fm.attributesOfItem(atPath: tmp.path))?[.size] as? NSNumber)?.intValue ?? -1
        guard onDisk == data.count else {
            try? fm.removeItem(at: tmp)
            throw StorageError.shortWrite(expected: data.count, actual: onDisk)
        }

        // Refresh `.bak` by HARDLINK, not by moving the primary aside: a move
        // leaves a window where the primary does not exist, and "primary does
        // not exist" is exactly the state that triggers migration/seed
        // decisions. A link only ever makes the BACKUP briefly absent.
        // Skipped when the primary is missing — otherwise a recovery-from-
        // backup commit would delete the very backup it is recovering from.
        //
        // gh#235 changed this line's CADENCE, not its mechanics, and the
        // change is a real one to state: `.bak` used to refresh on every
        // save and now refreshes once per CHECKPOINT — worst case, one
        // foreground session behind. Backup promotion is therefore a
        // checkpoint behind rather than an edit behind. It loses nothing (a
        // live log REFUSES the promotion outright, see
        // `refuseCalendarPromotionWithLiveLog`, and freezes instead of
        // silently serving the older generation) but it is a user-visible
        // recovery-granularity change and belongs in the release notes.
        if fm.fileExists(atPath: primary.path), let backup = backupURL(slot) {
            try? fm.removeItem(at: backup)
            try? fm.linkItem(at: primary, to: backup)
        }

        // The commit point.
        let renamed = tmp.path.withCString { old in
            primary.path.withCString { new in rename(old, new) }
        }
        guard renamed == 0 else {
            let code = errno
            try? fm.removeItem(at: tmp)
            throw StorageError.renameFailed(errno: code)
        }

        lastCommittedDigest[slot] = digest
        lastKnownCount[slot] = rows.count
        var foldedRecords = 0
        if slot == .calendarEvents {
            dominoStampOnDisk = .some(dominoLastPush)
            // THE one place an ordinary commit clears the log, immediately
            // after the rename that made its contents redundant. Putting it
            // here — rather than at each caller — is what makes migration,
            // backup promotion, wipe, restore replay and compaction all
            // covered without any of them knowing a log exists.
            //
            // A failure to clear is not free, which round 1's comment here
            // had backwards (round-2 A-F5). It is harmless to the NEXT LAUNCH
            // — the surviving log's base is now older than this seq, so
            // `plan` discards it by generation — and harmful to THIS process,
            // where the next append would write a record on the new base into
            // a file still holding records on the old one, and `plan`
            // quarantines a log whose records disagree about their base. One
            // session of edits. So `clearCalendarLog` latches
            // `calendarLogClearFailed`, which refuses the delta path and
            // keeps the background edge producing checkpoints that retry it.
            foldedRecords = calendarLogRecordCount
            clearCalendarLog(context: "checkpoint seq=\(seq)")
            calendarCheckpointSeq = seq
            calendarFoldedSeq = seq
            calendarCheckpointBytes = rowsData.count
            calendarBaseSignature = primarySignature(slot)
            // `nil` for a foreign row type, which simply leaves the delta path
            // disabled until a real `[Event]` commit establishes a base.
            installPersistedCalendarRows(rows as? [Event])
        }
        markCommitted(slot, seq: seq)

        return CommitReceipt(slot: slot, seq: seq, rowCount: rows.count, bytes: rowsData.count,
                             onDiskBytes: onDisk, encodeMs: encodeMs, writeMs: writeMs, syncMs: syncMs,
                             mode: .checkpoint, foldedRecords: foldedRecords,
                             reason: deltaFallbackReason)
    }

    // MARK: - Calendar delta commit (gh#235)

    private enum CalendarDeltaAttempt {
        case committed(CommitReceipt)
        /// Not eligible, or the append failed. Either way the caller writes a
        /// whole-array checkpoint next — the fallback rung that makes "never
        /// lose an event" hold even when the log cannot be written at all.
        ///
        /// `shrinkGuarded` says whether this attempt already took the
        /// pre-shrink snapshot, so the checkpoint that follows does not take
        /// a second one for the same shrink (round-2 B8).
        case fallback(String, shrinkGuarded: Bool)
    }

    /// The runtime kill switch's current value. Read per commit — that is
    /// what makes it a FIELD rollback rather than a build-time constant — and
    /// `object(forKey:)`, not `bool(forKey:)`, so an absent key is ON rather
    /// than `false`.
    private var calendarDeltaLogEnabled: Bool {
        flagDefaults.object(forKey: Self.calendarDeltaLogEnabledKey) as? Bool ?? true
    }

    /// One user edit, written as the changed rows instead of all 4164.
    ///
    /// The ladder, in order, and every rung falls back to the checkpoint that
    /// this class already knew how to write:
    ///   no log file / a faulted log / a log that would not clear / no base
    ///   yet / duplicate ids in the BASE / a base that changed underneath us /
    ///   duplicate ids in the INPUT / one huge delta / the log crossing its
    ///   cumulative bound / the append itself failing.
    /// The kill switch is judged one level up, in `commit`, because it must
    /// also cover the `[Event]`-cast failure this function never sees.
    private func calendarDeltaAttempt(_ rows: [Event], dominoLastPush: Date?) -> CalendarDeltaAttempt {
        guard let log = calendarLog else { return .fallback("noLogFile", shrinkGuarded: false) }
        guard log.fault == nil else { return .fallback("logFault", shrinkGuarded: false) }
        guard !calendarLogClearFailed else {
            // A log we could not delete still holds records on the PREVIOUS
            // base. Appending the new base into it makes `plan` quarantine
            // the whole file (round-2 A-F5).
            return .fallback("logNotCleared", shrinkGuarded: false)
        }
        guard let persisted = persistedCalendarRows else { return .fallback("noBase", shrinkGuarded: false) }
        // Round-2 A-F1: the BASE half of the duplicate-id guard below. A base
        // holding two rows under one id folds to two copies of ONE body, and
        // the incoming-row scan cannot see it — `removeAll { $0.id == id }`
        // takes both rows out at once, so the array handed in here is
        // perfectly duplicate-free while the base it diffs against is not.
        //
        // Round 3 correction (RED LINE 7). This used to read "a checkpoint
        // preserves duplicates byte for byte AND re-establishes a clean base,
        // so the fallback is also the repair". The second half was false. A
        // checkpoint writes the array it was HANDED and then re-installs it
        // through `installPersistedCalendarRows`, which rescans — so if the
        // duplicate is still in that array, the flag is set to true again and
        // the delta path is closed AGAIN. The fallback is data-SAFE, not a
        // repair, and nothing in this file repairs it: the duplicate leaves
        // only when the user's own edits remove it (`deleteCalendarEvent`
        // takes both rows, a cloud restore overwrites the array).
        //
        // The standing cost, stated because it is easy to underestimate:
        // for as long as the duplicate is in the array, EVERY save is a
        // whole-array checkpoint — the ~2 MB encode plus write that gh#235
        // exists to avoid, on every drag, for the rest of that store's life.
        // `reason=duplicateBaseID` on every one of those receipts is the
        // only way to see it. Both halves are pinned in
        // `CalendarDeltaLogQARound2Tests` by the test whose name says so
        // ("a duplicated base is preserved not repaired and the delta path
        // stays off"): three consecutive saves, all `.checkpoint`. A fixture
        // rather than this paragraph — because it was this paragraph that
        // was wrong.
        guard !persistedCalendarRowsHaveDuplicateID else {
            trail("storage: calendarEvents base holds a duplicate id; writing a checkpoint instead of a delta")
            return .fallback("duplicateBaseID", shrinkGuarded: false)
        }
        guard calendarCheckpointBytes > 0 else { return .fallback("noCheckpointBytes", shrinkGuarded: false) }
        // The base must still be the file the log was built on. A checkpoint
        // is the repair as well as the fallback, so a mismatch costs one
        // whole-array write and leaves everything consistent again.
        guard let signature = primarySignature(.calendarEvents),
              signature == calendarBaseSignature else { return .fallback("baseChanged", shrinkGuarded: false) }

        // `byID` collapses a duplicated id, and an `order` naming it twice
        // then yields two copies of ONE body — a fold whose count matches and
        // whose contents are wrong, which is precisely the failure the
        // exactness property forbids. `.calendarEvents` has no
        // `dedupedByIdentity` protection (only the two record slots do), so
        // this is a real state, not a hypothetical. A checkpoint preserves
        // duplicates byte for byte, so the fallback is also the repair-safe
        // answer.
        var seen = Set<UUID>()
        seen.reserveCapacity(rows.count)
        for row in rows where !seen.insert(row.id).inserted {
            trail("storage: calendarEvents holds a duplicate id (\(row.id)); writing a checkpoint instead of a delta")
            return .fallback("duplicateID", shrinkGuarded: false)
        }

        let diffStart = Date()
        let record = CalendarDeltaFold.delta(
            from: persisted, to: rows,
            base: calendarCheckpointSeq, seq: calendarFoldedSeq + 1,
            dominoLastPush: dominoLastPush,
            persistedStamp: dominoStampOnDisk.flatMap { $0 }
        )
        let diffMs = Int(Date().timeIntervalSince(diffStart) * 1000)

        guard let record else {
            // The disk already folds to exactly these rows. No I/O, and —
            // unlike the byte-digest skip — this IS positive evidence that
            // disk has caught up with memory, because it is measured against
            // `persisted`. See `CommitReceipt.diskMatchesRequest`.
            return .committed(CommitReceipt(
                slot: .calendarEvents, seq: calendarFoldedSeq, rowCount: rows.count,
                bytes: 0, onDiskBytes: 0, encodeMs: 0, writeMs: 0, syncMs: 0, skipped: true,
                mode: .delta, changedRowCount: 0, logBytes: calendarLogBytes,
                diffMs: diffMs, diskMatchesRequest: true
            ))
        }

        // ONE encode, whose cost is reported (round-2 B3). Round 1 encoded the
        // record here purely to size it and then again inside `append`, while
        // reporting `encodeMs: 0` — which made the delta row's `encodeMs`
        // incomparable with the checkpoint row's `encodeMs=48-70`, and that
        // comparison is the unit this whole ticket is priced in. The payload
        // is handed to `append` so the second encode is gone as well.
        let encodeStart = Date()
        let payload = log.encode(record)
        let encodeMs = Int(Date().timeIntervalSince(encodeStart) * 1000)
        guard let payload else {
            return .fallback("deltaEncodeFailed", shrinkGuarded: false)
        }
        // Single-record ceiling BEFORE the cumulative bound (G20).
        guard payload.count < Self.calendarSingleDeltaCeiling(checkpointBytes: calendarCheckpointBytes) else {
            return .fallback("single", shrinkGuarded: false)
        }
        guard calendarLogBytes + payload.count
                < Self.calendarCompactionThreshold(checkpointBytes: calendarCheckpointBytes) else {
            return .fallback("threshold", shrinkGuarded: false)
        }

        // Equivalent to the checkpoint path's guard, and for the same reason:
        // a delta-driven shrink (a bulk delete) deserves the same hardlinked
        // snapshot an atomic one gets.
        applyShrinkGuard(slot: .calendarEvents, newCount: rows.count, intent: .normal)

        let writeStart = Date()
        guard let outcome = log.append(encoded: payload) else {
            trailError("storage: calendarEvents delta append FAILED; falling back to a checkpoint")
            // The snapshot above is this shrink's, and the checkpoint that
            // follows must not take a second one (round-2 B8).
            return .fallback("appendFailed", shrinkGuarded: true)
        }
        // `writeMs` brackets the fsync as well, exactly as the checkpoint
        // path's does not — so `syncMs` is subtracted out rather than
        // double-counted in the trail's own arithmetic.
        let writeMs = max(0, Int(Date().timeIntervalSince(writeStart) * 1000) - outcome.syncMs)

        calendarLogBytes = outcome.onDiskBytes
        calendarLogRecordCount += 1
        calendarFoldedSeq = record.seq
        lastKnownCount[.calendarEvents] = rows.count
        if let stamp = record.dominoLastPush {
            dominoStampOnDisk = .some(max(dominoStampOnDisk.flatMap { $0 } ?? stamp, stamp))
        }
        // The bytes are confirmed, so this array IS the disk now. Already
        // scanned for duplicates a few lines up, so the install skips a
        // second O(n) pass over the same rows.
        installPersistedCalendarRows(rows, knownDuplicateFree: true)
        noteCalendarGeneration(record.seq)

        // Every millisecond field here is MEASURED (round-2 B3), and
        // `onDiskBytes` is the log's length read back from the handle after
        // the append — the same class of evidence the checkpoint path's
        // `stat`-backed short-write refusal stands on, not a copy of `bytes`
        // (round-2 B4).
        return .committed(CommitReceipt(
            slot: .calendarEvents, seq: record.seq, rowCount: rows.count,
            bytes: payload.count, onDiskBytes: outcome.onDiskBytes,
            encodeMs: encodeMs, writeMs: writeMs, syncMs: outcome.syncMs,
            mode: .delta, changedRowCount: record.changed.count,
            logBytes: outcome.onDiskBytes, diffMs: diffMs
        ))
    }

    private func payloadDigest(_ rowsData: Data, wiped: Bool, dominoLastPush: Date?) -> Data {
        var hasher = SHA256()
        hasher.update(data: rowsData)
        let suffix = "|\(wiped)|\(dominoLastPush?.timeIntervalSince1970 ?? -1)"
        hasher.update(data: Data(suffix.utf8))
        return Data(hasher.finalize())
    }

    private func writeProtected(_ data: Data, to url: URL) throws {
        if fileProtectionSupported {
            do {
                try data.write(to: url, options: [.completeFileProtectionUntilFirstUserAuthentication])
                return
            } catch {
                fileProtectionSupported = false
                trail("storage: write with protection class failed, retrying without: \(error)")
            }
        }
        try data.write(to: url, options: [])
    }

    /// Catches the failure class that `rename` cannot: atomically writing the
    /// WRONG bytes. A hardlink costs no copy, so keeping a few generations of
    /// "the file just before it shrank by more than half" is nearly free.
    /// The write is never refused — refusing would fork memory from disk,
    /// which is its own way to lose data.
    private func applyShrinkGuard(slot: StorageSlot, newCount: Int, intent: WriteIntent) {
        guard let previous = lastKnownCount[slot], previous > 50, newCount < previous / 2 else { return }
        trail("storage: SHRINK slot=\(slot.rawValue) \(previous)->\(newCount) intent=\(intent)")
        guard intent != .destructive,
              let primary = primaryURL(slot), fm.fileExists(atPath: primary.path),
              let snapshots = snapshotsDirectory else { return }
        let stamp = timestampComponent()
        try? fm.linkItem(at: primary,
                         to: snapshots.appendingPathComponent("\(slot.rawValue)-shrink-\(stamp).json"))
        // gh#235: the checkpoint alone is only PART of the pre-shrink state.
        // Without the log beside it the snapshot silently loses every edit
        // made between the last checkpoint and the shrink — i.e. exactly the
        // recent work a recovery is reached for.
        //
        // COPY, not link, and the difference is the whole value of the
        // snapshot (round-2 A-F4). The checkpoint above is immutable between
        // renames, so a hardlink freezes it. The log is APPENDED IN PLACE: a
        // hardlink shares the inode, so the very record this shrink is about
        // to write — and every record up to the next checkpoint — would grow
        // into this "pre-shrink" file. Replaying it would reproduce the
        // POST-shrink state, i.e. the snapshot would encode precisely the
        // deletion it exists to undo. A copy is bounded by the compaction
        // threshold (≤512 KB) and only ever paid on a >50% shrink.
        if let log = calendarLog, slot == .calendarEvents, log.exists {
            try? fm.copyItem(at: log.fileURL,
                             to: snapshots.appendingPathComponent("\(slot.rawValue)-shrink-\(stamp).log"))
        }
        pruneSnapshots(slot: slot, keeping: 3)
    }

    /// Keeps the newest `limit` SNAPSHOTS, where one snapshot may now be two
    /// files (`.json` + `.log`). Counting filenames would let a checkpoint and
    /// its own log count as two generations and evict the pair before last.
    private func pruneSnapshots(slot: StorageSlot, keeping limit: Int) {
        guard let snapshots = snapshotsDirectory,
              let entries = try? fm.contentsOfDirectory(atPath: snapshots.path) else { return }
        let prefix = "\(slot.rawValue)-shrink-"
        var byStamp: [String: [String]] = [:]
        for name in entries where name.hasPrefix(prefix) {
            let stamp = String(name.dropFirst(prefix.count)).split(separator: ".").dropLast()
                .joined(separator: ".")
            byStamp[stamp, default: []].append(name)
        }
        let stamps = byStamp.keys.sorted()
        guard stamps.count > limit else { return }
        for stamp in stamps.prefix(stamps.count - limit) {
            for name in byStamp[stamp] ?? [] {
                try? fm.removeItem(at: snapshots.appendingPathComponent(name))
            }
        }
    }

    // MARK: - Quarantine

    private func quarantineAside(_ url: URL, slot: StorageSlot, tag: String) -> String? {
        guard let quarantineDirectory else { return nil }
        let name = "\(slot.rawValue)-\(tag)-\(timestampComponent()).json"
        do {
            try fm.moveItem(at: url, to: quarantineDirectory.appendingPathComponent(name))
            return name
        } catch {
            return nil
        }
    }

    private func writeLegacyQuarantine(_ data: Data, slot: StorageSlot) -> String? {
        guard let quarantineDirectory else { return nil }
        let name = "\(slot.rawValue)-legacy-\(timestampComponent()).json"
        do {
            try data.write(to: quarantineDirectory.appendingPathComponent(name), options: [.atomic])
            return name
        } catch {
            return nil
        }
    }

    private func timestampComponent() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }

    // MARK: - Wipe housekeeping

    /// After an intentional wipe there is no reason to keep the pre-wipe
    /// plaintext lying around in `.bak` / quarantine / shrink snapshots.
    /// Idempotent, so it is safe to run on every launch that observes a wiped
    /// envelope — which is how a wipe interrupted halfway still finishes.
    func purgeAuxiliaryCopies(for slot: StorageSlot) {
        if let backup = backupURL(slot) { try? fm.removeItem(at: backup) }
        // gh#235. The log holds event PLAINTEXT — titles, notes, locations —
        // so an erase that left it behind would not be an erase.
        //
        // The emptiness check is not belt-and-braces, it is the second half of
        // a real bug: `EventStore.adopt` re-runs this on EVERY launch that
        // sees a wiped envelope (that is how an interrupted wipe finishes), so
        // a user who wipes and then creates an event would have the live log
        // deleted from under them on the next launch. The first half is
        // `read` folding `wiped` to `checkpoint.wiped && records.isEmpty`;
        // this is the half that holds if anything ever calls this directly.
        if slot == .calendarEvents, calendarLogRecordCount == 0 {
            // A failure here leaves event PLAINTEXT on the disk after an
            // erase, so it is trailed and latched rather than discarded: the
            // latch keeps the delta path off this file and keeps the
            // background edge retrying (round-2 A-F5).
            clearCalendarLog(context: "wipe purge")
        }
        for dir in [quarantineDirectory, snapshotsDirectory] {
            guard let dir, let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in entries where name.hasPrefix(slot.rawValue + "-") {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    /// Hygiene only — correctness must never depend on this succeeding.
    /// `removeObject` goes to cfprefsd, whose durability is the very thing
    /// under investigation; a wipe stays correct because every slot has an
    /// empty envelope ON DISK, and a file always beats legacy.
    func removeLegacyKeys() {
        guard let legacyDefaults else { return }
        for slot in StorageSlot.allCases {
            legacyDefaults.removeObject(forKey: slot.legacyDefaultsKey)
        }
    }

    // MARK: - Domino heartbeat

    private struct DominoHeartbeat: Codable { var lastPush: Double }

    /// The no-op heartbeat. `dominoPushTodosPastHorizon` runs on every
    /// foreground enter and every 900s tick; when nothing needed moving,
    /// stamping the time is still meaningful ("as of now, everything is
    /// aligned") but must not cost a 1.25 MB rewrite. When rows DID move, the
    /// stamp goes in the calendar envelope instead, committed with them.
    /// The loader takes `max` of the two: both are true statements, and the
    /// later one is the stronger. Erring towards the older value under-pushes
    /// (safe, self-correcting); the double-shift that a lost stamp would cause
    /// is silent and permanent, so it must be unreachable.
    func readDominoHeartbeat() -> Date? {
        guard let dominoURL, let data = try? Data(contentsOf: dominoURL),
              let beat = try? JSONDecoder().decode(DominoHeartbeat.self, from: data),
              beat.lastPush > 0 else { return nil }
        return Date(timeIntervalSince1970: beat.lastPush)
    }

    func writeDominoHeartbeat(_ time: Date) throws {
        guard ensureDirectory(), let directoryURL, let dominoURL else {
            throw StorageError.directoryUnavailable("domino")
        }
        let data = try JSONEncoder().encode(DominoHeartbeat(lastPush: time.timeIntervalSince1970))
        let tmp = directoryURL.appendingPathComponent(".tmp-domino-\(UUID().uuidString)")
        try writeProtected(data, to: tmp)
        if let handle = try? FileHandle(forWritingTo: tmp) {
            try? handle.synchronize()
            try? handle.close()
        }
        let renamed = tmp.path.withCString { old in dominoURL.path.withCString { new in rename(old, new) } }
        guard renamed == 0 else {
            let code = errno
            try? fm.removeItem(at: tmp)
            throw StorageError.renameFailed(errno: code)
        }
    }

    func removeDominoHeartbeat() {
        guard let dominoURL else { return }
        try? fm.removeItem(at: dominoURL)
        // The envelope stamp is a different fact in a different file; the wipe
        // that calls this clears it by committing a `wiped` envelope.
    }

    /// The stamp the `.calendarEvents` file on disk currently carries, read
    /// WITHOUT decoding its 1.25 MB of rows.
    ///
    /// Exists for one caller shape: a write that has no stamp of its own. The
    /// restore replay is the live example — it runs before `load()` has
    /// resolved anything, so "what the store thinks the stamp is" does not
    /// exist yet, and committing `nil` would erase the only authoritative copy
    /// (see `SlotEnvelopeHeader.dominoLastPush` for why that silently corrupts
    /// user dates). Every commit refreshes the cache, so the bounded header
    /// read happens at most once per process.
    /// gh#235 changed one thing here: the cold path folds the header stamp
    /// with the delta log's, because a push that landed as a delta carries its
    /// stamp in the RECORD, not in the checkpoint header. Reading the header
    /// alone would hand the restore replay a stamp older than the rows it is
    /// about to commit — and committing a stale stamp is exactly the
    /// re-apply-the-whole-elapsed-delta corruption this function exists to
    /// prevent. `max`, so it can only ever err towards under-pushing, which is
    /// visible and self-correcting.
    ///
    /// The cold path runs at most once per process, and its one cold caller
    /// (the restore replay) runs before `load()` reads anything — i.e. before
    /// any commit can have cleared the log.
    func persistedDominoStamp() -> Date? {
        if let cached = dominoStampOnDisk { return cached }
        var stamp = readHeaderOnly(.calendarEvents)?.dominoLastPush
        // "No information" posture: an unreadable log leaves the header stamp
        // standing, exactly as an unreadable header leaves `nil` standing.
        for record in noteCalendarLogRead(calendarLog?.loadRecords()) ?? [] {
            guard let recorded = record.dominoLastPush else { continue }
            stamp = stamp.map { Swift.max($0, recorded) } ?? recorded
        }
        calendarLog?.clearFault()
        dominoStampOnDisk = .some(stamp)
        return stamp
    }

    /// The header is a single line of string-free JSON — a couple of hundred
    /// bytes — so reading it never has to touch the rows, which is the point.
    /// It still reads until the terminator rather than assuming one chunk is
    /// enough: the caller's fallback for `nil` is "no stamp", and committing
    /// no stamp is precisely the corruption this is here to prevent, so a
    /// header that outgrew a guessed bound must not fail quietly.
    private func readHeaderOnly(_ slot: StorageSlot) -> SlotEnvelopeHeader? {
        guard let primary = primaryURL(slot),
              let handle = try? FileHandle(forReadingFrom: primary) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        while buffer.count < 64 * 1024 {
            guard let chunk = try? handle.read(upToCount: 1024), !chunk.isEmpty else { break }
            buffer.append(chunk)
            if let newline = buffer.firstIndex(of: 0x0A) {
                return try? JSONDecoder().decode(SlotEnvelopeHeader.self,
                                                 from: buffer[buffer.startIndex..<newline])
            }
        }
        return nil
    }

    // MARK: - Pending work (redo markers)

    /// A restore writes five arrays. On one medium they succeeded or failed
    /// together; on five files a kill in the middle leaves a persistent HALF
    /// restore — and the next backup snapshot would then write that half state
    /// back to the cloud, amplifying it. So the merged final state is recorded
    /// first, and replaying it is idempotent (it writes an end state, not a
    /// delta), which makes the half state repairable rather than merely
    /// detectable.
    ///
    /// The name carries a sortable timestamp because `pendingWork` returns
    /// entries in filename order and a bare UUID sorts at random: with two
    /// markers on disk, which one was applied last would have been a coin
    /// toss.
    @discardableResult
    func recordPendingWork(kind: String, payload: Data) throws -> URL {
        guard ensureDirectory(), let pendingDirectory else {
            throw StorageError.directoryUnavailable("pending")
        }
        let name = "\(kind)-\(timestampComponent())-\(UUID().uuidString).json"
        let url = pendingDirectory.appendingPathComponent(name)
        try writeProtected(payload, to: url)
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.synchronize()
            try? handle.close()
        }
        return url
    }

    /// Oldest first. `timestampComponent()` is fixed-width ISO-8601, so
    /// lexicographic order IS write order.
    ///
    /// This guarantees the ORDER, not that acting in it is correct. The
    /// restore replay deliberately consumes this newest-first, because its
    /// markers are successive drafts of one end state rather than independent
    /// jobs — see `EventStore.replayPendingRestoreIfNeeded`.
    func pendingWork(kind: String) -> [(url: URL, payload: Data)] {
        guard let pendingDirectory,
              let entries = try? fm.contentsOfDirectory(atPath: pendingDirectory.path) else { return [] }
        return entries.filter { $0.hasPrefix(kind + "-") }.sorted().compactMap { name in
            let url = pendingDirectory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return (url, data)
        }
    }

    func clearPendingWork(_ url: URL) {
        try? fm.removeItem(at: url)
    }

    /// Drop every marker of a kind. For the wipe: the user asked for the data
    /// to be gone, and a marker is a full copy of five arrays waiting to be
    /// written back.
    func clearAllPendingWork(kind: String) {
        for (url, _) in pendingWork(kind: kind) { clearPendingWork(url) }
    }

    // MARK: - Generations

    /// The generation currently recorded for `slot`. Strictly increasing: only
    /// a real commit advances it (an identical-payload skip does not).
    ///
    /// This is what lets a caller ask the one question a redo marker has to
    /// answer — "has this slot been written since I recorded my intent?" —
    /// without reading 1.25 MB of rows back.
    ///
    /// Reads the in-memory manifest, which `init` has already reconciled
    /// against the primary headers — so a commit whose rename landed but whose
    /// manifest write was lost still counts as committed here.
    func committedSeq(_ slot: StorageSlot) -> UInt64 {
        manifest.slots[slot.rawValue]?.seq ?? 0
    }

    /// The slot primary IS the commit: `commit` renames the data into place
    /// first and only then records the new seq in the manifest, and
    /// `writeManifest` is best-effort on top of that. A death in that gap
    /// leaves a primary whose header generation the manifest has never heard
    /// of — and every consumer of the manifest then reasons from a stale seq:
    /// the restore replay's `== base` staleness test passes for a slot that
    /// HAS moved on (so a stale marker overwrites the newer user edit), and
    /// the next commit re-mints an already-used seq.
    ///
    /// So on construction, before any caller can consult a seq, the manifest
    /// is caught up from the one artifact that cannot lie about a committed
    /// generation: the primary's own header. Bounded header reads only — the
    /// rows (up to 1.25 MB) are never touched.
    ///
    /// Read-only and non-destructive by design. A missing or unreadable
    /// header is NO INFORMATION: the manifest record stands untouched, and
    /// whatever `read` would have done about that file (quarantine, freeze,
    /// backup promotion) still happens exactly as before.
    ///
    /// Two artifacts can prove a committed generation, not one (gh#235): the
    /// primary's header, and — for `.calendarEvents` — the delta log's tail,
    /// since an append advances the generation without touching the header.
    /// Either alone is enough. That matters at one specific corner (round-2
    /// acceptance gap 2): with the primary unreadable and a live log beside
    /// it, reading ONLY the header left `committedSeq` at the manifest's
    /// stale value, so an abandoned restore marker's `committedSeq == base`
    /// staleness test said "this slot has not moved" — and the replay then
    /// overwrote `.destructive`-ly and cleared the log, actively destroying
    /// the one recoverable copy of those edits. So the tail is consulted even
    /// when the header is not there.
    ///
    /// This still never sets `everCommitted` for a slot with NEITHER a
    /// readable header nor a log tail, so it cannot turn a genuinely fresh
    /// slot into `.lostAfterManifest`: a fresh slot has no log, because only
    /// a commit writes one.
    private func reconcileManifestWithPrimaryHeaders() {
        var changed = false
        for slot in StorageSlot.allCases {
            var headerSeq = readHeaderOnly(slot)?.seq
            // Same "no information" posture on the log: an unreadable or
            // implausible tail leaves whatever the header said standing.
            // Reading the whole log is bounded by the compaction threshold
            // and happens once, in `init`, before anything else touches it.
            //
            // Round 3. "No information" is the right posture for the MANIFEST
            // and the wrong one for everything downstream of it, because the
            // thing we have no information about is a file the next commit
            // would DELETE. `loadRecords()`'s three answers are kept apart
            // here rather than collapsed into a `UInt64?` (the old `tailSeq`):
            // `[]`/absent is a store with nothing to lose, a record array
            // proves the generation, and `nil` latches
            // `calendarLogGenerationUnproven` — the one state in which a
            // restore replay's `committedSeq == base` test is answering from
            // a seq that may be stale, and therefore the one state in which
            // `commit` must not clear anything.
            if slot == .calendarEvents, let log = calendarLog {
                if let records = noteCalendarLogRead(log.loadRecords()) {
                    if let tail = records.last?.seq {
                        let plausible = tail < Self.maxPlausibleSeq
                        if plausible, tail > (headerSeq ?? 0) { headerSeq = tail }
                    }
                } else if log.exists {
                    trailError("storage: calendar delta log is present but its generation could not be read"
                               + " (\(log.fault ?? "unknown")); commits to this slot are refused this launch"
                               + " (a wipe excepted) so its records stay recoverable")
                }
            }
            guard let provenSeq = headerSeq else { continue }
            // A decodable header is not yet a BELIEVABLE one. Copying an
            // absurd seq into the manifest is how one damaged integer reaches
            // the mint in `commit` — see `maxPlausibleSeq`. Same posture as an
            // unreadable header: no information, the manifest record stands,
            // and whatever `read` does about the file is untouched.
            guard provenSeq < Self.maxPlausibleSeq else {
                trailError("storage: slot=\(slot.rawValue) primary header seq \(provenSeq) is implausible; ignored (manifest stands)")
                continue
            }
            var record = manifest.slots[slot.rawValue] ?? .init()
            let seqBehind = provenSeq > record.seq
            // A valid primary is proof of a commit even when the manifest
            // write that should have recorded it was lost — without this
            // backfill, the primary vanishing later would present as `.fresh`
            // and get seeded over instead of raising `.lostAfterManifest`.
            let everMissing = !record.everCommitted
            guard seqBehind || everMissing else { continue }
            if seqBehind {
                trail("storage: slot=\(slot.rawValue) manifest seq \(record.seq) behind durable generation \(provenSeq); reconciled")
                record.seq = provenSeq
            }
            record.everCommitted = true
            manifest.slots[slot.rawValue] = record
            changed = true
        }
        // The `loadRecords()` above reads the log to learn its last
        // generation, and a corrupt one sets `fault`. Judging that is `read`'s
        // job (it quarantines and freezes); this pass must leave no verdict
        // behind. What it DOES leave behind is `calendarLogRecordsSeen`, which
        // is not a verdict about the file but a fact about this process.
        calendarLog?.clearFault()
        if changed { writeManifest() }
    }

    // MARK: - Manifest

    private func readManifest() -> StorageManifest {
        guard let manifestURL, let data = try? Data(contentsOf: manifestURL),
              var decoded = try? JSONDecoder().decode(StorageManifest.self, from: data) else {
            return StorageManifest()
        }
        // A manifest that decoded is still on-disk bytes. An implausible seq
        // is no information — zero it and let `reconcileManifestWithPrimary-
        // Headers` (which runs right after this, before any caller can mint)
        // rebuild the true generation from the slot's own header. The record
        // itself is kept: `everCommitted` errs toward freezing over seeding,
        // and dropping it would turn a real loss into seedable freshness.
        for (key, record) in decoded.slots where record.seq >= Self.maxPlausibleSeq {
            trailError("storage: manifest slot=\(key) seq \(record.seq) is implausible; treated as no information")
            decoded.slots[key]?.seq = 0
        }
        return decoded
    }

    private func markCommitted(_ slot: StorageSlot, seq: UInt64) {
        var record = manifest.slots[slot.rawValue] ?? .init()
        record.everCommitted = true
        record.seq = max(record.seq, seq)
        manifest.slots[slot.rawValue] = record
        writeManifest()
    }

    /// Best-effort BUT never silent. Correctness no longer depends on the
    /// manifest being newer than the primaries it describes — `init`
    /// reconciles it from the headers — so a failure here does not fail the
    /// commit that triggered it. It still goes in the trail: a manifest that
    /// keeps failing to write means every launch re-derives generations from
    /// headers, and that pattern should be visible in the forensics, not
    /// discovered from it.
    private func writeManifest() {
        guard let manifestURL, let directoryURL else {
            trailError("storage: manifest not written (directory unavailable)")
            return
        }
        let data: Data
        do {
            data = try JSONEncoder().encode(manifest)
        } catch {
            trailError("storage: manifest encode failed: \(error)")
            return
        }
        let tmp = directoryURL.appendingPathComponent(".tmp-manifest-\(UUID().uuidString)")
        do {
            try writeProtected(data, to: tmp)
        } catch {
            try? fm.removeItem(at: tmp)
            trailError("storage: manifest write failed: \(error)")
            return
        }
        let renamed = tmp.path.withCString { old in manifestURL.path.withCString { new in rename(old, new) } }
        if renamed != 0 {
            let code = errno
            try? fm.removeItem(at: tmp)
            trailError("storage: manifest rename failed errno=\(code)")
        }
    }
}
