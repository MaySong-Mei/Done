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

    var isTransient: Bool {
        switch self {
        case .ioError, .directoryUnavailable: return true
        case .decodeFailed, .lostAfterManifest: return false
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
}

struct CommitReceipt {
    var slot: StorageSlot
    var seq: UInt64
    var rowCount: Int
    var bytes: Int
    var onDiskBytes: Int
    var encodeMs: Int
    var writeMs: Int
    var syncMs: Int
    /// The payload was byte-identical to the last committed one; nothing was
    /// written and `seq` did not advance.
    var skipped: Bool = false
}

enum StorageError: Error {
    case directoryUnavailable(String)
    case shortWrite(expected: Int, actual: Int)
    case renameFailed(errno: Int32)
    case slotFrozen(StorageSlot)
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
    let location: EventStorageLocation
    /// Migration source only. Never written to.
    let legacyDefaults: UserDefaults?

    private(set) var directoryURL: URL?
    private(set) var faults: [StorageSlot: SlotFault] = [:]
    private(set) var manifest = StorageManifest()
    /// Set when a legacy blob decoded fine but the readback of the file we
    /// wrote from it did not verify. The session serves the (proven-good)
    /// legacy content and the next ordinary save retries the file write.
    private(set) var migrationPendingSlots: Set<StorageSlot> = []

    private var lastCommittedDigest: [StorageSlot: Data] = [:]
    private var lastKnownCount: [StorageSlot: Int] = [:]
    private var directoryFault: SlotFault?
    /// Simulators and some sandboxes reject the data-protection attribute.
    /// Losing protection must never lose a write, so the first rejection
    /// downgrades for the process lifetime and says so in the trail.
    private var fileProtectionSupported = true

    private let fm = FileManager.default

    init(location: EventStorageLocation, legacyDefaults: UserDefaults?) {
        self.location = location
        self.legacyDefaults = legacyDefaults
        do {
            directoryURL = try location.directoryURL()
        } catch {
            directoryFault = .directoryUnavailable(detail: String(describing: error))
        }
        _ = ensureDirectory()
        sweepUnknownEntries()
        manifest = readManifest()
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

        // (a) primary present
        if let primary = primaryURL(slot), fm.fileExists(atPath: primary.path) {
            switch readEnvelope(at: primary, as: Row.self) {
            case .success(let envelope):
                lastKnownCount[slot] = envelope.rows.count
                trail("storage: slot=\(slot.rawValue) read primary seq=\(envelope.header.seq) count=\(envelope.rows.count)")
                return .loaded(envelope, .primary)
            case .io(let detail):
                // Not one byte moves. Renaming a file that is merely
                // unreadable-right-now turns a transient failure into a
                // permanent loss.
                raise(.ioError(detail: detail), on: slot)
                return .unreadable(.ioError(detail: detail))
            case .decode(let detail):
                let quarantined = quarantineAside(primary, slot: slot, tag: "corrupt")
                trailError("storage: slot=\(slot.rawValue) primary corrupt, quarantined as \(quarantined ?? "<failed>")")
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
        guard ensureDirectory(), let directoryURL, let primary = primaryURL(slot) else {
            throw StorageError.directoryUnavailable(String(describing: directoryFault))
        }

        let encodeStart = Date()
        let rowsData = try rowEncoder.encode(rows)
        let encodeMs = Int(Date().timeIntervalSince(encodeStart) * 1000)

        let digest = payloadDigest(rowsData, wiped: wiped, dominoLastPush: dominoLastPush)
        if lastCommittedDigest[slot] == digest {
            return CommitReceipt(slot: slot, seq: manifest.slots[slot.rawValue]?.seq ?? 0,
                                 rowCount: rows.count, bytes: rowsData.count, onDiskBytes: 0,
                                 encodeMs: encodeMs, writeMs: 0, syncMs: 0, skipped: true)
        }

        applyShrinkGuard(slot: slot, newCount: rows.count, intent: intent)

        let seq = (manifest.slots[slot.rawValue]?.seq ?? 0) + 1
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
        markCommitted(slot, seq: seq)

        return CommitReceipt(slot: slot, seq: seq, rowCount: rows.count, bytes: rowsData.count,
                             onDiskBytes: onDisk, encodeMs: encodeMs, writeMs: writeMs, syncMs: syncMs)
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
        guard intent == .normal,
              let primary = primaryURL(slot), fm.fileExists(atPath: primary.path),
              let snapshots = snapshotsDirectory else { return }
        let name = "\(slot.rawValue)-shrink-\(timestampComponent()).json"
        try? fm.linkItem(at: primary, to: snapshots.appendingPathComponent(name))
        pruneSnapshots(slot: slot, keeping: 3)
    }

    private func pruneSnapshots(slot: StorageSlot, keeping limit: Int) {
        guard let snapshots = snapshotsDirectory,
              let entries = try? fm.contentsOfDirectory(atPath: snapshots.path) else { return }
        let mine = entries.filter { $0.hasPrefix("\(slot.rawValue)-shrink-") }.sorted()
        guard mine.count > limit else { return }
        for name in mine.prefix(mine.count - limit) {
            try? fm.removeItem(at: snapshots.appendingPathComponent(name))
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
    }

    // MARK: - Pending work (redo markers)

    /// A restore writes five arrays. On one medium they succeeded or failed
    /// together; on five files a kill in the middle leaves a persistent HALF
    /// restore — and the next backup snapshot would then write that half state
    /// back to the cloud, amplifying it. So the merged final state is recorded
    /// first, and replaying it is idempotent (it writes an end state, not a
    /// delta), which makes the half state repairable rather than merely
    /// detectable.
    @discardableResult
    func recordPendingWork(kind: String, payload: Data) throws -> URL {
        guard ensureDirectory(), let pendingDirectory else {
            throw StorageError.directoryUnavailable("pending")
        }
        let url = pendingDirectory.appendingPathComponent("\(kind)-\(UUID().uuidString).json")
        try writeProtected(payload, to: url)
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.synchronize()
            try? handle.close()
        }
        return url
    }

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

    // MARK: - Manifest

    private func readManifest() -> StorageManifest {
        guard let manifestURL, let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode(StorageManifest.self, from: data) else {
            return StorageManifest()
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

    private func writeManifest() {
        guard let manifestURL, let directoryURL,
              let data = try? JSONEncoder().encode(manifest) else { return }
        let tmp = directoryURL.appendingPathComponent(".tmp-manifest-\(UUID().uuidString)")
        guard (try? writeProtected(data, to: tmp)) != nil else { return }
        let renamed = tmp.path.withCString { old in manifestURL.path.withCString { new in rename(old, new) } }
        if renamed != 0 { try? fm.removeItem(at: tmp) }
    }
}
