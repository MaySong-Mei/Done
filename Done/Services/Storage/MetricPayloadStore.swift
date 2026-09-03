//
//  MetricPayloadStore.swift
//  Done
//
//  Bounded on-disk retention for raw MetricKit payload JSON (gh#219).
//
//  The previous write site dropped one timestamped file per payload into
//  `Documents/Diagnostics/` with no rotation and no cap. Metric payloads
//  arrive ~daily, but diagnostic payloads (crashes, hangs, CPU exceptions)
//  arrive near-real-time — and Documents rides device *and iCloud* backup,
//  so an unbounded pile there spends the owner's iCloud quota. This store
//  keeps the same forensics in Application Support — which iOS backs up
//  exactly like Documents (only Caches/tmp and isExcludedFromBackup items
//  are skipped), and deliberately so: backed-up forensics are retrievable
//  later. What changes is the bound: two caps (2 MB / 40 files), evicting
//  oldest-first, so the quota cost is bounded instead of unbounded.
//
//  Deliberately NOT deleted: these files are the owner's crash/hang
//  forensics for the CALayer-rewrite rollout. Bounding is uncontroversial;
//  removing the capability is a product call gh#219 explicitly defers.
//

import Foundation
import os

/// Bounded store of MetricKit payload JSON files, oldest evicted first.
///
/// Lives in `Application Support/Diagnostics/MetricKit/` — a subdirectory of
/// the `DiagnosticTrail` directory rather than the directory itself, because
/// rotation here deletes the oldest *files* in its directory wholesale and
/// must never be able to reach `trail.log` / `trail.1.log`. Owning the whole
/// directory keeps the caps a property of the directory, not of a filename
/// filter.
///
/// Every entry point is non-throwing by signature: this is called from inside
/// the MetricKit delivery callback, and a diagnostics sink that can throw or
/// trap in the middle of crash reporting is worse than no sink. Failures
/// degrade to a line in `log` and a `nil`/skipped result.
nonisolated final class MetricPayloadStore {
    struct Caps {
        /// Total bytes retained across all payload files. At-cap is legal;
        /// one byte over evicts.
        var maxTotalBytes: Int = 2 * 1024 * 1024
        /// Number of payload files retained. At-cap is legal; one more evicts.
        var maxFileCount: Int = 40
    }

    let directory: URL
    let legacyDirectory: URL
    let caps: Caps
    let migrationFlagKey: String

    private let defaults: UserDefaults
    private let log: (String) -> Void
    private let lock = NSLock()
    private let fm = FileManager.default

    /// Production locations: new store under Application Support, legacy
    /// pile under Documents (the pre-gh#219 write site).
    static func standard() -> MetricPayloadStore {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "Done",
            category: "Metrics"
        )
        return MetricPayloadStore(
            directory: appSupport
                .appendingPathComponent("Diagnostics", isDirectory: true)
                .appendingPathComponent("MetricKit", isDirectory: true),
            legacyDirectory: docs.appendingPathComponent("Diagnostics", isDirectory: true),
            log: { logger.error("\($0, privacy: .public)") }
        )
    }

    init(
        directory: URL,
        legacyDirectory: URL,
        caps: Caps = Caps(),
        defaults: UserDefaults = .standard,
        migrationFlagKey: String = "MetricPayloadStore.migratedDocumentsDiagnostics.v1",
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.directory = directory
        self.legacyDirectory = legacyDirectory
        self.caps = caps
        self.defaults = defaults
        self.migrationFlagKey = migrationFlagKey
        self.log = log
    }

    // MARK: - Writing

    /// Persist one payload's raw JSON, then re-apply the caps.
    ///
    /// Runs the one-time legacy migration first, so migration happens at the
    /// write site — before the first new file lands — with no separate launch
    /// hook to forget. Returns the written file's URL, or `nil` if the write
    /// failed (failure is logged, never thrown). A payload that alone
    /// violates the caps is a write failure too: it is rejected up front and
    /// the existing files are left untouched.
    @discardableResult
    func persist(_ data: Data, kind: String, now: Date = Date()) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        migrateLegacyIfNeededLocked()
        // A payload that alone violates the caps can never be retained.
        // Handing it to rotation would make the newest-first prefix EMPTY —
        // evicting every existing forensic file to make room for a file that
        // is then evicted too, while `persist` returns the deleted file's
        // URL as if it succeeded. That is a write failure, not a rotation
        // matter: reject here, leave the store untouched, say so in the log.
        guard data.count <= caps.maxTotalBytes, caps.maxFileCount >= 1 else {
            log("MetricPayloadStore: rejected \(kind) payload: \(data.count) bytes alone violates caps (maxTotalBytes=\(caps.maxTotalBytes), maxFileCount=\(caps.maxFileCount)); nothing written, existing files untouched")
            return nil
        }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = availableURLLocked(kind: kind, now: now)
            try data.write(to: url, options: [.atomic])
            // Stamp the age explicitly rather than trusting write-time
            // granularity: eviction order is decided by this date.
            try? fm.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
            rotateLocked()
            return url
        } catch {
            log("MetricPayloadStore: failed to persist \(kind) payload: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Rotation

    /// One payload file on disk, as rotation sees it.
    private struct Entry {
        var url: URL
        var bytes: Int
        var age: Date
    }

    /// Regular files in `dir`, newest first. Ties on modification date break
    /// by filename, greater-name-first; two same-second payloads share a
    /// timestamp stamp and are age-equivalent, so either order is acceptable
    /// there — the tiebreak only has to be deterministic.
    ///
    /// The deterministic contract for a same-second burst (pinned by QA's
    /// `testSameSecondBurstEvictionTiebreakIsDeterministic`): the burst's
    /// files are `kind-<stamp>.json`, `…-2.json`, `…-3.json`, …, and the
    /// greater-name-first Unicode comparison INVERTS write order — `.`
    /// (0x2E) sorts after `-` (0x2D), so the base-named file (written FIRST)
    /// ranks newest, and among the suffixed files the plain string compare
    /// ranks `-3` over `-2` (and `-9` over `-10`). Under eviction pressure
    /// the first same-second victim is therefore `-2` (written second), not
    /// the oldest-written file. Age-equivalent per the contract above;
    /// determinism, not write order, is the load-bearing property.
    private func entriesNewestFirst(in dir: URL) -> [Entry] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys)) else {
            return []
        }
        let entries: [Entry] = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return Entry(
                url: url,
                bytes: values.fileSize ?? 0,
                age: values.contentModificationDate ?? .distantPast
            )
        }
        return entries.sorted { a, b in
            if a.age != b.age { return a.age > b.age }
            return a.url.lastPathComponent > b.url.lastPathComponent
        }
    }

    /// Keep the newest-first *prefix* that satisfies both caps; delete every
    /// file past the first cap violation, oldest last to go — so under any
    /// partial failure the survivors are still the newest ones.
    /// Caller must hold `lock`.
    private func rotateLocked() {
        let entries = entriesNewestFirst(in: directory)
        var keptBytes = 0
        var keptCount = 0
        var evicted: [Entry] = []
        for entry in entries {
            if evicted.isEmpty,
               keptCount + 1 <= caps.maxFileCount,
               keptBytes + entry.bytes <= caps.maxTotalBytes {
                keptCount += 1
                keptBytes += entry.bytes
            } else {
                evicted.append(entry)
            }
        }
        for entry in evicted.reversed() { // oldest deleted first
            do {
                try fm.removeItem(at: entry.url)
            } catch {
                log("MetricPayloadStore: failed to evict \(entry.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// `kind-<ISO8601 stamp>.json`, suffixed `-2`, `-3`, … if two payloads of
    /// one kind land within the same second (the old write site silently
    /// overwrote on that collision). Caller must hold `lock`.
    private func availableURLLocked(kind: String, now: Date) -> URL {
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let base = "\(kind)-\(stamp)"
        var candidate = directory.appendingPathComponent("\(base).json")
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(counter).json")
            counter += 1
        }
        return candidate
    }

    // MARK: - Legacy migration (gh#219)

    /// One-time move of the unbounded `Documents/Diagnostics/` pile into this
    /// store: newest legacy files come across up to whatever room the caps
    /// leave, everything else — including the legacy directory itself — is
    /// deleted. The flag is set on SUCCESS only (vacuous success — no legacy
    /// directory — counts): a migration that throws leaves the flag clear
    /// and retries at the next write. The failure most likely here is
    /// disk-full, which correlates exactly with having the huge legacy pile
    /// this fix exists to remove — a flag-on-attempt would strand that pile
    /// forever. Retries are safe: writes arrive ~daily, each failure is
    /// caught and logged, `moveItem` is atomic, and files already moved have
    /// left the legacy directory, so a retry only ever chews the remainder.
    /// After the flag is set, a second run is a no-op even if the legacy
    /// path later reappears (the straddle-heal precedent).
    /// Caller must hold `lock`.
    private func migrateLegacyIfNeededLocked() {
        guard !defaults.bool(forKey: migrationFlagKey) else { return }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: legacyDirectory.path, isDirectory: &isDir), isDir.boolValue else {
            defaults.set(true, forKey: migrationFlagKey)
            return
        }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let existing = entriesNewestFirst(in: directory)
            var keptBytes = existing.reduce(0) { $0 + $1.bytes }
            var keptCount = existing.count
            var admitting = true
            for entry in entriesNewestFirst(in: legacyDirectory) {
                let destination = directory.appendingPathComponent(entry.url.lastPathComponent)
                if fm.fileExists(atPath: destination.path) {
                    // Name collision with a store resident (reachable only on
                    // a flag-cleared re-run against a populated store). A
                    // collision is not a cap violation: the resident wins,
                    // only this legacy copy is dropped, and admission
                    // continues for the older files behind it.
                    try fm.removeItem(at: entry.url)
                    continue
                }
                if admitting,
                   keptCount + 1 <= caps.maxFileCount,
                   keptBytes + entry.bytes <= caps.maxTotalBytes {
                    try fm.moveItem(at: entry.url, to: destination)
                    keptCount += 1
                    keptBytes += entry.bytes
                } else {
                    // Newest-first prefix, same rule as rotation: the first
                    // legacy file that does not FIT ends admission for all
                    // older ones behind it.
                    admitting = false
                    try fm.removeItem(at: entry.url)
                }
            }
            try fm.removeItem(at: legacyDirectory)
            defaults.set(true, forKey: migrationFlagKey)
        } catch {
            // No flag: the next write retries the migration.
            log("MetricPayloadStore: legacy Documents/Diagnostics migration failed (will retry on next write): \(error.localizedDescription)")
        }
    }
}
