//
//  AtomicValueFile.swift
//  Done
//
//  One `Codable` value, one file, committed the way `DurableEventStorage`
//  commits a slot.
//
//  WHY THIS EXISTS
//  ---------------
//  `DurableEventStorage` proved the commit mechanics that stop a swipe-kill
//  from eating a save: temp file → fsync → size check → hardlink the backup →
//  `rename(2)`. Those mechanics are about BYTES, not about events, but they
//  were written inside a class that owns eight slots, a manifest, a shrink
//  guard and a Domino stamp. Every other blob still on `UserDefaults` — event
//  type templates, deleted-type color history — needs the bytes half and none
//  of the rest.
//
//  Copying the mechanics per consumer is how they drift; handing every
//  consumer a second `DurableEventStorage` over the same directory is worse
//  (two objects separately caching and rewriting one manifest can lose
//  generation updates, and `sweepUnknownEntries` deletes anything off its
//  whitelist). So the mechanics are extracted here, verbatim, and each
//  consumer keeps its own directory and its own files.
//
//  WHAT THIS DELIBERATELY DOES NOT HAVE
//  ------------------------------------
//  No manifest and no generation counter. A single-file store has no
//  cross-file atomicity to coordinate — which is precisely what makes the
//  "two instances lose generations" hazard structurally unreachable here
//  rather than merely unlikely.
//
//  WHAT IT DOES NEED FROM ONE, THOUGH
//  ----------------------------------
//  The manifest was carrying one fact that has nothing to do with generations:
//  `everCommitted`. Without it "never written" and "written and then lost" are
//  the same observation — and they must produce opposite answers, because one
//  may be seeded over and the other may not. That is not a hypothetical here:
//  a corrupt primary is MOVED into `quarantine/` by this very file, so the
//  freeze it raises would last exactly one process lifetime and the next
//  launch would serve a default over the user's damaged data and mirror it to
//  the cloud — the disaster the freeze exists to prevent, one relaunch later.
//
//  So there is a zero-byte witness, `<stem>.committed`, written the first time
//  bytes are proven good (a successful commit, or a successful read of a file
//  someone else committed). It carries no state, so it cannot go stale and
//  cannot be raced: its existence is the whole message. Anything under
//  `quarantine/` bearing this file's stem counts as the same proof, which is
//  what covers a store that was committed by an older build and corrupted
//  before this one ever got to write the witness.
//
//  FILE FORMAT
//  -----------
//  The encoded value, and nothing else. Unlike a slot file there is no header
//  to frame off, because there is no seq, no wipe flag and no Domino stamp to
//  carry — and a format with nothing in it is a format that cannot go stale.
//

import Foundation
import CryptoKit
import os

private let valueFileLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Done",
    category: "Persistence"
)

private func valueTrail(_ message: String) {
    valueFileLogger.log("\(message, privacy: .public)")
    DiagnosticTrail.record("Persistence", message)
}

private func valueTrailError(_ message: String) {
    valueFileLogger.error("\(message, privacy: .public)")
    DiagnosticTrail.record("Persistence", "ERROR " + message)
}

/// `.sortedKeys` for the same load-bearing reason as `DurableEventStorage`'s
/// encoder: without it two encodes of the same value can differ byte-wise
/// within one process, and the identical-payload skip below would never fire.
private let valueEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}()

@MainActor
final class AtomicValueFile<Value: Codable> {
    /// What a read found. Mirrors `SlotRead` case for case, minus the
    /// envelope: `.fresh` is the ONLY state a caller may seed over.
    enum Outcome {
        /// Directory readable, no primary, no backup, no legacy bytes.
        case fresh
        case loaded(Value, StorageProvenance)
        case unreadable(SlotFault)
    }

    /// What the legacy `UserDefaults` key held, as the caller decoded it.
    ///
    /// The shape lives with the caller because it varies (the templates key is
    /// `Data` in either of two historical encodings; the color-history key is
    /// a plist dictionary), while what happens NEXT — commit, verify, never
    /// touch the legacy key again — must not.
    enum LegacyValue {
        /// No legacy bytes at all. The caller's own defaults apply.
        case absent
        /// Legacy bytes decoded cleanly. Migrate them.
        case present(Value)
        /// Legacy bytes exist and could not be decoded. Quarantine and FREEZE:
        /// serving a default over damaged data is how the default gets synced
        /// up as if the user had chosen it.
        case damaged(detail: String, raw: Data?)
    }

    let directory: URL
    let filename: String

    /// Set when the value could not be read. While it stands every write is
    /// refused — the in-memory value is not a faithful copy of the file, so
    /// writing it destroys the file.
    private(set) var fault: SlotFault?
    /// Set when a legacy blob decoded fine but the readback of the file we
    /// wrote from it did not verify. The content is proven good, so the value
    /// is served and the next ordinary commit retries the write; deliberately
    /// NOT a freeze.
    private(set) var migrationPending = false

    private var lastCommittedDigest: Data?
    private var directoryFault: SlotFault?
    /// Simulators and some sandboxes reject the data-protection attribute.
    /// Losing protection must never lose a write.
    private var fileProtectionSupported = true

    private let fm = FileManager.default

    init(directory: URL, filename: String) {
        self.directory = directory
        self.filename = filename
        _ = ensureDirectory()
        sweepOwnTemporaries()
    }

    // MARK: - Paths

    private var primaryURL: URL { directory.appendingPathComponent(filename) }
    private var backupURL: URL { directory.appendingPathComponent(backupName) }
    private var witnessURL: URL { directory.appendingPathComponent(witnessName) }
    private var quarantineDirectory: URL { directory.appendingPathComponent("quarantine", isDirectory: true) }

    private var stem: String {
        filename.hasSuffix(".json") ? String(filename.dropLast(5)) : filename
    }
    private var backupName: String { stem + ".bak" }
    private var witnessName: String { stem + ".committed" }
    private var temporaryPrefix: String { ".tmp-\(stem)-" }

    // MARK: - Directory

    @discardableResult
    private func ensureDirectory() -> Bool {
        if directoryFault == nil,
           fm.fileExists(atPath: directory.path),
           fm.fileExists(atPath: quarantineDirectory.path) {
            return true
        }
        do {
            for dir in [directory, quarantineDirectory] where !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            if fileProtectionSupported {
                do {
                    try fm.setAttributes(
                        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                        ofItemAtPath: directory.path
                    )
                } catch {
                    // Never `.complete`: unreadable before first unlock, and an
                    // unreadable file presents to the user as a fault.
                    fileProtectionSupported = false
                    valueTrail("valuefile: \(filename) protection attribute unavailable, continuing without")
                }
            }
            directoryFault = nil
            return true
        } catch {
            directoryFault = .directoryUnavailable(detail: String(describing: error))
            valueTrailError("valuefile: \(filename) directory unavailable: \(error)")
            return false
        }
    }

    /// Only our own `.tmp-<stem>-*` debris, left by a commit killed between the
    /// write and the rename. Scoped to this file's prefix on purpose: the
    /// directory is shared with sibling `AtomicValueFile`s, and a whitelist
    /// sweep like `DurableEventStorage`'s would have each one delete the
    /// others' files.
    private func sweepOwnTemporaries() {
        guard let entries = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        var swept = 0
        for entry in entries where entry.hasPrefix(temporaryPrefix) {
            try? fm.removeItem(at: directory.appendingPathComponent(entry))
            swept += 1
        }
        if swept > 0 { valueTrail("valuefile: \(filename) swept \(swept) stray temp file(s)") }
    }

    // MARK: - Proof of a prior commit

    /// Durable proof that this file has held a committed value.
    ///
    /// Independent traces, because they cover different histories:
    ///
    /// * the witness, dropped the first time this process proves bytes good —
    ///   covers "both copies vanished out of band", including a `.bak` that
    ///   was never created because only one commit ever happened;
    /// * a file still standing at either name. The ONLY thing that ever puts
    ///   one there is `rename(2)` at the commit point (primary) or a hardlink
    ///   off an already-committed primary (backup). `read()` never reaches
    ///   this leg — it asks the question only once both are provably absent —
    ///   but `wipe()` asks it while they are still there, and a primary this
    ///   build has not managed to READ yet (a transient `.io`, e.g. a launch
    ///   before the first unlock) has left no other trace;
    /// * anything in `quarantine/` bearing this stem — covers the store that
    ///   was committed by an EARLIER build (so no witness exists) and then
    ///   corrupted, where the corrupt primary was moved aside by `read()`
    ///   itself. Without this leg the freeze would evaporate on the relaunch
    ///   after the one that raised it.
    ///
    /// None can be true of a store that was never written, which is the only
    /// property `.fresh` needs from it.
    private var hasProofOfPriorCommit: Bool {
        if fm.fileExists(atPath: witnessURL.path) { return true }
        if fm.fileExists(atPath: primaryURL.path) { return true }
        if fm.fileExists(atPath: backupURL.path) { return true }
        guard let entries = try? fm.contentsOfDirectory(atPath: quarantineDirectory.path) else {
            return false
        }
        return entries.contains { $0.hasPrefix(stem + "-") }
    }

    /// Zero bytes on purpose: the witness says "this store has been written",
    /// a fact that only ever becomes MORE true, so there is no content to
    /// keep current and no torn-write to worry about. Written best-effort —
    /// failing a commit over the witness would trade a real guarantee for a
    /// defensive one — and never fsynced, because a witness lost to power
    /// failure leaves the file itself lost too, which is the same launch.
    private func recordProofOfCommit() {
        guard !fm.fileExists(atPath: witnessURL.path) else { return }
        guard ensureDirectory() else { return }
        do {
            try writeProtected(Data(), to: witnessURL)
        } catch {
            valueTrailError("valuefile: \(filename) could not write the commit witness: \(error)")
        }
    }

    // MARK: - Faults

    /// Only ever called from inside a user-confirmed restore or an explicit
    /// wipe. Automatic paths must never unfreeze: a frozen file presents as a
    /// default value, and an automatic unfreeze would let the next ordinary
    /// commit write that default down over the user's data.
    func clearFault() {
        fault = nil
        migrationPending = false
    }

    private func raise(_ newFault: SlotFault) {
        fault = newFault
        valueTrailError("valuefile: \(filename) FROZEN \(newFault)")
    }

    // MARK: - Reading

    func read(legacy: () -> LegacyValue = { .absent }) -> Outcome {
        guard ensureDirectory() else {
            let unavailable = directoryFault ?? .directoryUnavailable(detail: "unknown")
            raise(unavailable)
            // With the directory unreadable nothing can be proven absent, so
            // `.fresh` is unreachable by construction. Legacy still serves the
            // user their content; every write stays refused.
            if case .present(let value) = legacy() {
                valueTrail("valuefile: \(filename) read from legacy (directory unavailable)")
                return .loaded(value, .legacyMigrated)
            }
            return .unreadable(unavailable)
        }

        // (a) primary present
        if fm.fileExists(atPath: primaryURL.path) {
            switch decode(at: primaryURL) {
            case .success(let value, let data):
                lastCommittedDigest = digest(data)
                // These bytes are proof enough — whoever wrote them committed
                // them. This is what gives a store written by an older build
                // a witness on its first launch under this one.
                recordProofOfCommit()
                valueTrail("valuefile: \(filename) read primary bytes=\(data.count)")
                return .loaded(value, .primary)
            case .io(let detail):
                // Not one byte moves. Renaming a file that is merely
                // unreadable-right-now turns a transient failure into a
                // permanent loss.
                raise(.ioError(detail: detail))
                return .unreadable(.ioError(detail: detail))
            case .decode(let detail):
                let quarantined = quarantineAside(primaryURL, tag: "corrupt")
                valueTrailError("valuefile: \(filename) primary corrupt, quarantined as \(quarantined ?? "<failed>")")
                if let promoted = promoteBackup() {
                    return .loaded(promoted, .backup)
                }
                let decodeFault = SlotFault.decodeFailed(detail: detail, quarantinedAs: quarantined)
                raise(decodeFault)
                return .unreadable(decodeFault)
            }
        }

        // (b) primary absent, backup present
        if fm.fileExists(atPath: backupURL.path) {
            if let promoted = promoteBackup() {
                return .loaded(promoted, .backup)
            }
            let backupFault = SlotFault.decodeFailed(detail: "backup unusable", quarantinedAs: nil)
            raise(backupFault)
            return .unreadable(backupFault)
        }

        // (c) neither exists. Before legacy is even consulted: was there ever
        // anything here? `DurableEventStorage` asks its manifest the same
        // question and raises `.lostAfterManifest`; this file asks its
        // witness. Getting it wrong is not a small error — a store that was
        // written and then lost looks EXACTLY like a first launch, so `.fresh`
        // would serve a default, the caller would stop suppressing sync, and
        // `diffSync` (a mirror) would delete the user's real cloud rows. With
        // a legacy blob still present it is quieter and worse: the pre-
        // migration snapshot comes back looking legitimate, and every edit
        // made since is rolled back locally and then in the cloud.
        if hasProofOfPriorCommit {
            raise(.lostAfterCommit)
            return .unreadable(.lostAfterCommit)
        }

        // Provably never written — legacy is the only place left to look.
        switch legacy() {
        case .absent:
            return .fresh
        case .damaged(let detail, let raw):
            // Bytes exist and are unreadable: keep them for forensics and
            // freeze. Serving the built-in default here would look exactly
            // like a legitimate first launch, and sync would mirror it up.
            let name = raw.flatMap { writeLegacyQuarantine($0) }
            let damagedFault = SlotFault.decodeFailed(detail: detail, quarantinedAs: name)
            raise(damagedFault)
            return .unreadable(damagedFault)
        case .present(let value):
            // Legacy is never mutated here — not updated, not deleted. Every
            // kill point during this leaves either (legacy only) or (legacy +
            // a complete file), both correct on the next launch. Once the file
            // exists the legacy key is dead data and is never read again.
            do {
                try commit(value)
                if verifyReadback() {
                    valueTrail("valuefile: \(filename) MIGRATED from legacy")
                    return .loaded(value, .legacyMigrated)
                }
                migrationPending = true
                valueTrailError("valuefile: \(filename) migration readback failed; serving legacy content, will retry on next commit")
            } catch {
                migrationPending = true
                valueTrailError("valuefile: \(filename) migration write failed: \(error); serving legacy content")
            }
            // The CONTENT is proven good (it decoded), so writing it later is
            // safe and this is deliberately NOT a freeze.
            return .loaded(value, .legacyMigrated)
        }
    }

    private enum DecodeResult {
        case success(Value, Data)
        case io(String)
        case decode(String)
    }

    private func decode(at url: URL) -> DecodeResult {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [])
        } catch {
            return .io(String(describing: error))
        }
        do {
            return .success(try JSONDecoder().decode(Value.self, from: data), data)
        } catch {
            return .decode(String(describing: error))
        }
    }

    private func promoteBackup() -> Value? {
        guard fm.fileExists(atPath: backupURL.path),
              case .success(let value, _) = decode(at: backupURL) else { return nil }
        // A readable `.bak` is proof of a prior commit in its own right, and
        // it must be recorded BEFORE the write-back below — which can fail,
        // leaving the next launch with a `.bak` it may also fail to promote.
        recordProofOfCommit()
        // Put the good copy back under the primary name immediately: leaving
        // the store running off a `.bak` means the next launch finds "primary
        // absent" again and re-derives the recovery every time.
        do {
            try commit(value)
            valueTrail("valuefile: \(filename) RECOVERED from backup")
        } catch {
            valueTrailError("valuefile: \(filename) backup recovered but could not be written back: \(error)")
        }
        return value
    }

    private func verifyReadback() -> Bool {
        if case .success = decode(at: primaryURL) { return true }
        return false
    }

    // MARK: - Writing

    /// `intent` carries the caller's meaning, not a branch in the mechanics:
    /// a single value has no row count, so `DurableEventStorage`'s shrink
    /// guard has no analogue here and nothing is snapshotted. It is recorded
    /// so a trail can still answer "was that erasure asked for?".
    @discardableResult
    func commit(_ value: Value, intent: WriteIntent = .normal) throws -> Int {
        // Enforced HERE rather than only at the call site, so "forgot to ask"
        // is impossible — including for the writes this class issues itself
        // (migration, backup promotion, both of which run before any fault
        // could have been raised).
        guard fault == nil else { throw StorageError.valueFileFrozen(name: filename) }
        guard ensureDirectory() else {
            throw StorageError.directoryUnavailable(String(describing: directoryFault))
        }

        let data = try valueEncoder.encode(value)
        let payloadDigest = digest(data)
        if lastCommittedDigest == payloadDigest { return 0 }

        let tmp = directory.appendingPathComponent("\(temporaryPrefix)\(UUID().uuidString)")
        do {
            try writeProtected(data, to: tmp)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }

        do {
            let handle = try FileHandle(forWritingTo: tmp)
            try handle.synchronize()
            try handle.close()
        } catch {
            // fsync is the power-loss insurance, not the process-death fix.
            // Failing the commit over it would trade a real guarantee for a
            // speculative one.
            valueTrailError("valuefile: \(filename) fsync failed (continuing): \(error)")
        }

        let onDisk = ((try? fm.attributesOfItem(atPath: tmp.path))?[.size] as? NSNumber)?.intValue ?? -1
        guard onDisk == data.count else {
            try? fm.removeItem(at: tmp)
            throw StorageError.shortWrite(expected: data.count, actual: onDisk)
        }

        // Refresh `.bak` by HARDLINK, not by moving the primary aside: a move
        // leaves a window where the primary does not exist, and "primary does
        // not exist" is exactly the state that triggers the migration
        // decision. A link only ever makes the BACKUP briefly absent. Skipped
        // when the primary is missing, or a recovery-from-backup commit would
        // delete the very backup it is recovering from.
        if fm.fileExists(atPath: primaryURL.path) {
            try? fm.removeItem(at: backupURL)
            try? fm.linkItem(at: primaryURL, to: backupURL)
        }

        // The commit point.
        let renamed = tmp.path.withCString { old in
            primaryURL.path.withCString { new in rename(old, new) }
        }
        guard renamed == 0 else {
            let code = errno
            try? fm.removeItem(at: tmp)
            throw StorageError.renameFailed(errno: code)
        }

        lastCommittedDigest = payloadDigest
        migrationPending = false
        recordProofOfCommit()
        if intent == .destructive {
            valueTrail("valuefile: \(filename) committed \(data.count)B (destructive)")
        }
        return data.count
    }

    private func digest(_ data: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: data)
        return Data(hasher.finalize())
    }

    private func writeProtected(_ data: Data, to url: URL) throws {
        if fileProtectionSupported {
            do {
                try data.write(to: url, options: [.completeFileProtectionUntilFirstUserAuthentication])
                return
            } catch {
                fileProtectionSupported = false
                valueTrail("valuefile: \(filename) write with protection class failed, retrying without: \(error)")
            }
        }
        try data.write(to: url, options: [])
    }

    // MARK: - Wipe

    /// Erase every copy of this value. Clears the fault first for the same
    /// reason `EventStore.clearAllLocalData` does: a frozen file must still be
    /// erasable — the user asked for the data to be gone, and a file we could
    /// not READ is one we can still empty.
    func wipe() {
        clearFault()
        lastCommittedDigest = nil
        // BEFORE a single byte is removed, because removing them is what
        // destroys the evidence. Saying "the witness survives a wipe" is only
        // half a guarantee: for the two stores whose proof is NOT the witness —
        // committed by a pre-witness build and corrupted (proof: the quarantine
        // trace, deleted three lines down), or committed by a pre-witness build
        // and not yet successfully read (proof: the primary itself, deleted two
        // lines down) — a wipe used to leave a directory with no proof at all.
        // `wipeToDefaults()` commits straight after and would write a witness
        // then, but a kill in between is a directory that looks never-written
        // while the legacy blob is still in `UserDefaults` (it is cleared only
        // after the reset returns), and the next launch calls that a first run
        // and re-migrates exactly what the user asked to erase. So the proof is
        // promoted to the one form nothing here deletes.
        if hasProofOfPriorCommit { recordProofOfCommit() }
        try? fm.removeItem(at: primaryURL)
        purgeAuxiliaryCopies()
    }

    /// After an intentional overwrite there is no reason to keep the pre-wipe
    /// plaintext lying around in `.bak` or `quarantine/`.
    ///
    /// The witness deliberately survives — `wipe()` has just made sure there IS
    /// one. It holds no user bytes, and "this store has been written" is not
    /// something a wipe makes untrue, while dropping it would leave the next
    /// launch reading an empty directory as a first run.
    private func purgeAuxiliaryCopies() {
        try? fm.removeItem(at: backupURL)
        guard let entries = try? fm.contentsOfDirectory(atPath: quarantineDirectory.path) else { return }
        for name in entries where name.hasPrefix(stem + "-") {
            try? fm.removeItem(at: quarantineDirectory.appendingPathComponent(name))
        }
    }

    // MARK: - Quarantine

    private func quarantineAside(_ url: URL, tag: String) -> String? {
        guard ensureDirectory() else { return nil }
        let name = "\(stem)-\(tag)-\(timestampComponent()).json"
        do {
            try fm.moveItem(at: url, to: quarantineDirectory.appendingPathComponent(name))
            return name
        } catch {
            return nil
        }
    }

    private func writeLegacyQuarantine(_ data: Data) -> String? {
        guard ensureDirectory() else { return nil }
        let name = "\(stem)-legacy-\(timestampComponent()).json"
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
}
