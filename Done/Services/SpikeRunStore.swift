//
//  SpikeRunStore.swift
//  Done
//
//  gh#197 SPIKE — append-only local storage for SpikeRun records.
//
//  Pattern ported from DiagnosticTrail.swift (gh#162's proven file-sink
//  instrumentation): written by us, to our own container, readable after a
//  relaunch, crash-safe because a write reaches the kernel before the call
//  returns. Not a straight copy — DiagnosticTrail rotates whole files by
//  byte size because its entries are free-form text with no identity;
//  SpikeRun records have an id and need per-RUN eviction ("cap runs per
//  spike, oldest dropped"), which byte-rotation can't express. So each
//  spike gets its own JSONL file, one line per record, and retention is
//  enforced by rewriting the file (atomic temp+rename, same durability
//  contract DurableEventStorage already uses) once the file crosses the
//  BYTE bound — the byte stat is the only rewrite trigger (Fix Watch
//  R-F3; see `compactIfNeeded`). The count cap no longer triggers a
//  rewrite of its own: readers apply it on load, and the compaction
//  applies it whenever the byte bound fires, so a file may briefly hold
//  more than `maxRunsPerSpike` tiny lines while readers still see at
//  most the cap.
//
//  A run is never captured as a single line. `beginRun` appends an OPEN
//  record (`endedAt == nil`) the instant a scenario is armed; `finishRun`
//  appends a second record with the same `id`, closed. This is what makes
//  interrupted-run detection possible without ever rewriting an existing
//  line: a record whose id has no closing record is a run that is still
//  open — armed by the current process, or orphaned by a past process
//  that died (only the coordinator's armed set tells those apart; see
//  `reconcileInterruptedRuns`). See `SpikeRunLog` in
//  SpikeModel.swift for the (pure) collapse/interrupt/retention rules this
//  store calls into.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Location

enum SpikeRunStorageLocation: Equatable {
    /// `Documents/spike-runs/<spikeID>.jsonl` — reachable later via
    /// `devicectl device copy from`, per the issue's own "no export UI in
    /// v1" call. Redirected to a sibling directory under XCTest for the
    /// same reason `EventStorageLocation.production` is: DoneTests is a
    /// host-app bundle, so an unredirected path would read/write the real
    /// dogfood container during a test run.
    case production
    /// Throwaway directory under `NSTemporaryDirectory()`, one per test.
    case ephemeral(id: UUID)

    var directory: URL {
        switch self {
        case .production:
            let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let name = EventStorageLocation.isRunningUnderXCTest ? "spike-runs-test-host" : "spike-runs"
            return base.appendingPathComponent(name, isDirectory: true)
        case .ephemeral(let id):
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("spike-runs-\(id.uuidString)", isDirectory: true)
        }
    }
}

// MARK: - Store

enum SpikeRunStore {
    /// Hard cap on distinct runs retained per spike, oldest `startedAt`
    /// dropped first. Applies to distinct run ids (post-collapse), not raw
    /// JSONL lines — editing an existing run's note never counts against
    /// it. This is a hard constraint per gh#197 comment #1's disk-fill
    /// incidents, not a tunable nicety.
    static let maxRunsPerSpike = 200
    /// Defensive backstop for the case count-based retention doesn't
    /// reach: repeated note edits on runs already under the cap still
    /// append bytes forever. Same order-of-magnitude reasoning as
    /// `DiagnosticTrail.rotateAtBytes` — compact well before this would
    /// become a real fraction of the device's free space.
    static let compactAtBytes = 256 * 1024
    /// Fix Watch R-F3: a compaction must land with HEADROOM, not at the
    /// threshold. The pre-fix rewrite kept up to `maxRunsPerSpike` runs by
    /// count alone, so once 200 retained runs exceeded `compactAtBytes`
    /// the size guard was true forever and every `finishRun` triggered a
    /// full read-decode-rewrite cycle — steady-state thrash on the main
    /// thread, timed 6s after the very gestures the resident observes.
    /// Compacting down to half the threshold means the file must GROW
    /// back through 128KB of fresh appends before the next rewrite.
    static let compactTargetBytes = compactAtBytes / 2

    private static func fileURL(spikeID: String, location: SpikeRunStorageLocation) -> URL {
        location.directory.appendingPathComponent("\(spikeID).jsonl")
    }

    /// Every spike id with a record file in this location — what the
    /// telemetry uploader walks. Dotfiles (the install id, cursor and
    /// sample below) are not record files and never appear here.
    static func spikeIDsOnDisk(location: SpikeRunStorageLocation = .production) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: location.directory.path) else { return [] }
        return names
            .filter { $0.hasSuffix(".jsonl") && !$0.hasPrefix(".") }
            .map { String($0.dropLast(".jsonl".count)) }
            .sorted()
    }

    // MARK: Telemetry side files (gh#273 §7.2 / §7.5)
    //
    // All four live INSIDE `location.directory`, so `wipe()` — already on
    // the erase list (`EraseWiringQATests`) — takes them with the records
    // and no second erase entry is needed (A·#23 / B·F12). Each is marked
    // excluded from backup: the records are deliberately backed up (the
    // deck says so), these are device-local bookkeeping that would be
    // wrong on a restored phone (a restored cursor says "uploaded" about
    // a server that never saw this install's rows).

    static let installIDFileName = ".install-id"
    static let uploadCursorFileName = ".upload-cursor.json"
    static let lastUploadSampleFileName = ".last-upload-sample.json"
    static let lastUploadStatusFileName = ".last-upload-status.json"

    static func installIDURL(location: SpikeRunStorageLocation = .production) -> URL {
        location.directory.appendingPathComponent(installIDFileName)
    }

    static func uploadCursorURL(location: SpikeRunStorageLocation = .production) -> URL {
        location.directory.appendingPathComponent(uploadCursorFileName)
    }

    static func lastUploadSampleURL(location: SpikeRunStorageLocation = .production) -> URL {
        location.directory.appendingPathComponent(lastUploadSampleFileName)
    }

    /// This install's random id: read if present, minted and written on
    /// first use. Not `identifierForVendor` (design §4.1). A file that
    /// fails to parse is replaced — a new id is the honest answer to a
    /// corrupt one.
    static func installID(location: SpikeRunStorageLocation = .production) -> UUID {
        let url = installIDURL(location: location)
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let id = UUID(uuidString: text) {
            return id
        }
        let minted = UUID()
        writeSideFile(Data(minted.uuidString.utf8), to: url)
        return minted
    }

    /// The upload cursor as last persisted. Missing, unreadable or corrupt
    /// → EMPTY (everything pending), never "all uploaded" (design §7.2).
    static func loadUploadCursor(location: SpikeRunStorageLocation = .production) -> UploadCursor {
        guard let data = try? Data(contentsOf: uploadCursorURL(location: location)),
              let cursor = try? JSONDecoder().decode(UploadCursor.self, from: data) else {
            return UploadCursor()
        }
        return cursor
    }

    @discardableResult
    static func saveUploadCursor(_ cursor: UploadCursor, location: SpikeRunStorageLocation = .production) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(cursor) else { return false }
        return writeSideFile(data, to: uploadCursorURL(location: location))
    }

    @discardableResult
    static func saveLastUploadSample(_ json: Data, location: SpikeRunStorageLocation = .production) -> Bool {
        writeSideFile(json, to: lastUploadSampleURL(location: location))
    }

    static func loadLastUploadSample(location: SpikeRunStorageLocation = .production) -> Data? {
        try? Data(contentsOf: lastUploadSampleURL(location: location))
    }

    static func lastUploadStatusURL(location: SpikeRunStorageLocation = .production) -> URL {
        location.directory.appendingPathComponent(lastUploadStatusFileName)
    }

    /// The status row's "last upload · rows" (QA: it read "never uploaded"
    /// after every relaunch). Missing or unreadable → nil.
    @discardableResult
    static func saveLastUploadStatus(_ status: TelemetryUploadStatus, location: SpikeRunStorageLocation = .production) -> Bool {
        guard let data = try? JSONEncoder().encode(status) else { return false }
        return writeSideFile(data, to: lastUploadStatusURL(location: location))
    }

    static func loadLastUploadStatus(location: SpikeRunStorageLocation = .production) -> TelemetryUploadStatus? {
        guard let data = try? Data(contentsOf: lastUploadStatusURL(location: location)) else { return nil }
        return try? JSONDecoder().decode(TelemetryUploadStatus.self, from: data)
    }

    @discardableResult
    private static func writeSideFile(_ data: Data, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var marked = url
            try? marked.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }

    // MARK: Writing

    /// Take every run record, for "erase all local data" (gh#263).
    ///
    /// The records carry user-entered notes (`setNote` below) and live in
    /// `Documents/spike-runs/`. `FixWatchView`'s own interface text tells the
    /// user the data is "随设备备份" — backed up with the device — so an erase
    /// that skipped it left user writing in a backed-up location.
    ///
    /// Also takes the telemetry side files kept in the same directory
    /// (gh#273 §7.5): the upload cursor, the install id, the last request
    /// sample and the last upload's status — so the next install is a
    /// stranger to the server.
    ///
    /// A missing directory is success.
    static func wipe(location: SpikeRunStorageLocation = .production) {
        try? FileManager.default.removeItem(at: location.directory)
        let prefix = location.directory.path + "/"
        for key in revisionCache.keys where key.hasPrefix(prefix) {
            revisionCache[key] = nil
        }
    }

    /// Who a record belongs to, as the WRITER says it (gh#273 review P1-1).
    /// `Optional` alone cannot say "the owner is nil and I mean it" — the
    /// center's close-out of a signed-out stretch and a manual runner's
    /// "I don't know, ask the session" were the same nil, and the store
    /// stamped the next account over the signed-out counts.
    enum OwnerStamp {
        /// The writer knows nothing about sessions (manual spike runners):
        /// a nil `ownerUID` is filled from `ownerProvider`; a non-nil one is
        /// the writer's and kept.
        case fromProvider
        /// The writer has decided — nil included (a signed-out record stays
        /// signed-out). The center always writes this.
        case explicit(String?)
    }

    @discardableResult
    static func beginRun(_ run: SpikeRun, owner: OwnerStamp = .fromProvider, location: SpikeRunStorageLocation = .production) -> Bool {
        precondition(run.endedAt == nil, "beginRun requires an open record (endedAt == nil)")
        return appendLine(run, spikeID: run.spikeID, owner: owner, location: location)
    }

    @discardableResult
    static func finishRun(_ run: SpikeRun, owner: OwnerStamp = .fromProvider, location: SpikeRunStorageLocation = .production) -> Bool {
        precondition(run.endedAt != nil, "finishRun requires a closed record (endedAt set)")
        let wrote = appendLine(run, spikeID: run.spikeID, owner: owner, location: location)
        compactIfNeeded(spikeID: run.spikeID, location: location)
        return wrote
    }

    /// Re-appends a run with an edited note. Legal on open or closed runs
    /// — a note is a human observation, not part of the measurement, so
    /// there is no reason to require the run be finished first. The record
    /// keeps the owner it already has, nil included: a note typed after
    /// signing in must not hand a signed-out run to the new account (final
    /// review P2-1 — "nil never uploads" would otherwise have a side door).
    @discardableResult
    static func setNote(_ note: String, forRunID id: UUID, spikeID: String, location: SpikeRunStorageLocation = .production) -> Bool {
        var runs = loadRuns(spikeID: spikeID, location: location, applyRetention: false)
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return false }
        runs[index].note = note
        let wrote = appendLine(runs[index], spikeID: spikeID, owner: .explicit(runs[index].ownerUID), location: location)
        // Repeated edits to the SAME run id don't grow the distinct-run
        // count the count-based cap watches, only the file's duplicate-line
        // bloat — that's exactly what the byte-size backstop exists for, so
        // this call site needs it too, not just `finishRun`'s.
        compactIfNeeded(spikeID: spikeID, location: location)
        return wrote
    }

    /// Closes every ORPHANED open run across the given spikes — runs left
    /// open by a PAST process that died (crash, force-quit, the OS
    /// reclaiming the app while backgrounded). Backgrounding alone
    /// orphans nothing: armed runs deliberately survive it (see
    /// `SpikeSessionCoordinator`'s lifetime policy) — process death is
    /// the only orphan source. One append per orphaned run; never rewrites
    /// an existing line. Safe to call repeatedly — a run already closed
    /// has no effect here.
    ///
    /// `excludingRunIDs` names the runs the CURRENT process has armed
    /// right now (`SpikeSessionCoordinator.armedRunIDs`): under parallel
    /// arming, any caller can run while runs are legitimately open in
    /// this process, and an open record is an orphan only when no live
    /// runner owns it. Closing an armed run's open record here would
    /// corrupt that run mid-measurement.
    static func reconcileInterruptedRuns(spikeIDs: [String], closedAt: Date = Date(), excludingRunIDs: Set<UUID> = [], location: SpikeRunStorageLocation = .production) {
        for spikeID in spikeIDs {
            let collapsed = loadRuns(spikeID: spikeID, location: location, applyRetention: false)
            let open = SpikeRunLog.openRuns(in: collapsed).filter { !excludingRunIDs.contains($0.id) }
            guard !open.isEmpty else { continue }
            for closed in SpikeRunLog.closeAsInterrupted(open, closedAt: closedAt) {
                // Closing an orphan must not re-attribute it: it keeps the
                // owner its open record carried, nil included.
                appendLine(closed, spikeID: spikeID, owner: .explicit(closed.ownerUID), location: location)
            }
        }
    }

    /// Convenience for launch-style call sites: reconcile every spike the
    /// compile-time registry knows about. Any call site that can re-fire
    /// while this process is alive (scene disconnect/reconnect replays
    /// `.onAppear` without a relaunch) must pass the coordinator's armed
    /// set as `excludingRunIDs` — a live armed run's write-ahead record is
    /// not an orphan, and closing it here would corrupt the run
    /// mid-measurement.
    static func reconcileAllRegisteredSpikesAtLaunch(closedAt: Date = Date(), excludingRunIDs: Set<UUID> = []) {
        reconcileInterruptedRuns(spikeIDs: SpikeRegistry.all.map(\.id), closedAt: closedAt, excludingRunIDs: excludingRunIDs)
    }

    // MARK: Reading

    /// Whole-file decodes this process has run (`loadRuns`, which is
    /// main-actor). Tests pin the paths that must not run one; nothing in the
    /// app reads it.
    private(set) static var wholeFileReads = 0

    static func loadRuns(spikeID: String, location: SpikeRunStorageLocation = .production, applyRetention: Bool = true) -> [SpikeRun] {
        wholeFileReads += 1
        let url = fileURL(spikeID: spikeID, location: location)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let collapsed = SpikeRunLog.collapse(SpikeRunFileScan.records(in: data))
        return applyRetention ? SpikeRunLog.applyRetention(collapsed, cap: maxRunsPerSpike) : collapsed
    }

    static func latestRuns(spikeID: String, limit: Int, location: SpikeRunStorageLocation = .production) -> [SpikeRun] {
        Array(loadRuns(spikeID: spikeID, location: location).sorted { $0.startedAt > $1.startedAt }.prefix(limit))
    }

    // MARK: Writing internals

    /// Highest `revision` this process has appended per (directory, run
    /// id). The first append of an id in a process looks the id up on disk
    /// once (`latestRevisionOnDisk`); every later append for that id is a
    /// cache hit. That keeps the per-flush cost at "one append + one stat"
    /// (R-F3) while making `revision` strictly monotonic across relaunches:
    /// the upload cursor and the server guard order by it (design §7.2),
    /// and a revision that could repeat would let a stale resend win.
    private static var revisionCache: [String: Int] = [:]

    private static func revisionCacheKey(_ id: UUID, location: SpikeRunStorageLocation) -> String {
        location.directory.path + "/" + id.uuidString
    }

    private static func nextRevision(for id: UUID, spikeID: String, location: SpikeRunStorageLocation) -> Int {
        let key = revisionCacheKey(id, location: location)
        let current: Int
        if let cached = revisionCache[key] {
            current = cached
        } else {
            current = latestRevisionOnDisk(of: id, spikeID: spikeID, location: location)
        }
        let next = current + 1
        revisionCache[key] = next
        return next
    }

    /// The revision on `id`'s latest line on disk. Collapse keeps the LATEST
    /// line per id, and revisions only ever go up in append order, so that
    /// line's revision is the max. Found by searching the file's bytes for
    /// the id rather than decoding every line (red-team R3): a fresh id —
    /// every window close, every newly minted day — decodes nothing, and the
    /// day's own id decodes the line it is on. Whatever the scan cannot
    /// decide, the full read decides, exactly as before.
    private static func latestRevisionOnDisk(of id: UUID, spikeID: String, location: SpikeRunStorageLocation) -> Int {
        var decodedLines = 0
        switch SpikeRunFileScan.latestLine(of: id, in: fileURL(spikeID: spikeID, location: location),
                                           decodedLines: &decodedLines) {
        case .found(let run):
            return run.revision ?? 0
        case .absent:
            return 0
        case .undetermined:
            return loadRuns(spikeID: spikeID, location: location, applyRetention: false)
                .first { $0.id == id }?.revision ?? 0
        }
    }

    /// The account signed in right now, for records whose writer did not
    /// stamp one (manual spike runs — `Spike195DetailPerf`, `Spike201EffortTap`
    /// — know nothing about sessions). Installed by `TelemetryUploader.
    /// activate()` in the app; nil under XCTest unless a test sets it, and
    /// a test that does must reset it (process-global).
    static var ownerProvider: (() -> String?)?

    /// The one choke point every record passes through on its way to disk.
    /// Stamps the store-owned envelope fields (gh#273 §4.1): the monotonic
    /// `revision` for this id (always overwritten), this install's id, and
    /// the owner as `OwnerStamp` says — the provider's for a writer that
    /// left it open, the writer's own value (nil included) when explicit.
    @discardableResult
    private static func appendLine(_ run: SpikeRun, spikeID: String, owner: OwnerStamp, location: SpikeRunStorageLocation) -> Bool {
        var stamped = run
        stamped.revision = nextRevision(for: run.id, spikeID: spikeID, location: location)
        if stamped.installID == nil {
            stamped.installID = installID(location: location)
        }
        switch owner {
        case .explicit(let uid):
            stamped.ownerUID = uid
        case .fromProvider:
            if stamped.ownerUID == nil {
                stamped.ownerUID = ownerProvider?()
            }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(stamped) else { return false }
        data.append(0x0A)

        let directory = location.directory
        let url = fileURL(spikeID: spikeID, location: location)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return false
        }
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil) else { return false }
        }
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            if end > 0 && !Self.endsWithNewline(handle.fileDescriptor, size: end) {
                // A torn last line (a kill mid-append) would otherwise glue
                // onto this one and both would be lost to every reader. A
                // newline of our own first closes it off; when the last byte
                // cannot be read, the newline is written anyway — a blank
                // line is skipped by every reader, old builds included.
                data.insert(0x0A, at: data.startIndex)
            }
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    private static func endsWithNewline(_ fd: Int32, size: UInt64) -> Bool {
        var last: UInt8 = 0
        return pread(fd, &last, 1, off_t(size - 1)) == 1 && last == 0x0A
    }

    /// Fix Watch R-F3: the byte-size STAT comes first and gates everything
    /// — the pre-fix shape called `loadRuns` (full read + per-line JSON
    /// decode) unconditionally on every `finishRun` just to evaluate its
    /// own guard. Consequence accepted deliberately: the count cap no
    /// longer triggers a rewrite on its own. A file can carry more than
    /// `maxRunsPerSpike` tiny lines until it crosses `compactAtBytes`;
    /// readers still see at most the cap (`loadRuns` applies retention),
    /// and the byte threshold bounds the file regardless.
    private static func compactIfNeeded(spikeID: String, location: SpikeRunStorageLocation) {
        let url = fileURL(spikeID: spikeID, location: location)
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        guard size >= compactAtBytes else { return }
        let collapsed = loadRuns(spikeID: spikeID, location: location, applyRetention: false)
        let capped = SpikeRunLog.applyRetention(collapsed, cap: maxRunsPerSpike)
        rewrite(trimToByteBudget(capped), spikeID: spikeID, location: location)
    }

    /// Keeps the NEWEST runs whose encoded lines fit `compactTargetBytes`.
    /// Never returns an empty set for a non-empty input: if a single run
    /// alone exceeds the whole budget the newest one is kept anyway —
    /// retention exists to bound the file, not to silently wipe the most
    /// recent measurement.
    private static func trimToByteBudget(_ runs: [SpikeRun]) -> [SpikeRun] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var remaining = compactTargetBytes
        var kept: [SpikeRun] = []
        for run in runs.sorted(by: { $0.startedAt > $1.startedAt }) {
            guard let line = try? encoder.encode(run) else { continue }
            let cost = line.count + 1 // trailing newline
            if cost > remaining { break }
            remaining -= cost
            kept.append(run)
        }
        if kept.isEmpty, let newest = runs.max(by: { $0.startedAt < $1.startedAt }) {
            kept = [newest]
        }
        return kept
    }

    /// Atomic replace: write the compacted set to a temp file, then rename
    /// over the live one. A kill mid-write leaves the ORIGINAL file
    /// intact — `replaceItemAt` only takes effect once the new file is
    /// fully on disk.
    private static func rewrite(_ runs: [SpikeRun], spikeID: String, location: SpikeRunStorageLocation) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var payload = Data()
        for run in runs.sorted(by: { $0.startedAt < $1.startedAt }) {
            guard let line = try? encoder.encode(run) else { continue }
            payload.append(line)
            payload.append(0x0A)
        }
        let url = fileURL(spikeID: spikeID, location: location)
        let tempURL = url.appendingPathExtension("tmp")
        do {
            try payload.write(to: tempURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }
}

// MARK: - Reading a few lines, not the file

/// Reads of one spike file that decode only the lines they need, for the
/// main-thread paths whose cost must not grow with the file. Byte-level:
/// lines are split on the `\n` byte, which is the store's own framing.
/// `pread` throughout, never `mmap` — a file truncated in place under a
/// mapping faults the reader.
nonisolated enum SpikeRunFileScan {
    /// Every record in a file's bytes, in append order — the one decode
    /// `loadRuns` runs, here so a read off the main thread runs the same one.
    /// Never traps on a bad line (partial write from a kill mid-append, or a
    /// future/older schema): skips it.
    static func records(in data: Data) -> [SpikeRun] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let lineData = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(SpikeRun.self, from: lineData)
        }
    }

    /// How much of the file one search step reads.
    static let searchChunkBytes = 64 * 1024
    /// How much one step of finding a line's ends reads.
    private static let lineChunkBytes = 4 * 1024

    enum Latest: Equatable {
        /// The latest line whose top-level id is the one asked for — the
        /// record `loadRuns`'s collapse keeps for it.
        case found(SpikeRun)
        /// No line can decode to that id: its text is nowhere in the file.
        case absent
        /// The scan could not decide (a read failed, or a line holding the
        /// id's text does not decode); the caller asks the full read.
        case undetermined
    }

    /// The id's latest line, found by searching backwards from the end of
    /// the file for the id's 36 characters and decoding ONLY lines that hold
    /// them, newest first.
    ///
    /// Why the first verified line is the answer: every line that decodes to
    /// this id holds its text (a UUID's characters are never escaped by any
    /// writer, and the match ignores letter case, which `JSONDecoder` also
    /// ignores — production writes upper case, fixtures and copied-in files
    /// may not), so no later line of this id can have been passed over.
    ///
    /// A candidate that decodes to ANOTHER id (the text in a note, an
    /// install id) is rejected and the search resumes before the START of its
    /// line, not before the hit: any other hit inside that line is the same
    /// line, so a note repeating the id costs one decode, not one per copy.
    /// A candidate that does not decode at all is the full read's call —
    /// `loadRuns` skips it, but this scan does not try to be `loadRuns`.
    ///
    /// `decodedLines` counts the decodes this call ran.
    static func latestLine(of id: UUID, in url: URL, decodedLines: inout Int) -> Latest {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT ? .absent : .undetermined }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .undetermined }
        let size = Int(info.st_size)
        let needle = Array(id.uuidString.lowercased().utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var end = size
        while true {
            let hit: Int
            switch lastOccurrence(of: needle, before: end, fd: fd) {
            case .readFailed: return .undetermined
            case .none: return .absent
            case .at(let offset): hit = offset
            }
            guard let start = lineStart(before: hit, fd: fd),
                  let stop = lineEnd(from: hit + needle.count, size: size, fd: fd),
                  let line = readBytes(fd, start..<stop) else { return .undetermined }
            decodedLines += 1
            guard let run = try? decoder.decode(SpikeRun.self, from: line) else { return .undetermined }
            if run.id == id { return .found(run) }
            end = start
        }
    }

    // MARK: Search

    private enum Occurrence {
        case at(Int)
        case none
        case readFailed
    }

    /// The start of the last occurrence of `needle` (a lower-case UUID
    /// string) lying wholly inside `[0, end)`, in any letter case. Reads
    /// backwards a chunk at a time; consecutive chunks overlap by one byte
    /// less than the needle, so an occurrence across a chunk edge is seen
    /// exactly once. Candidates are found by `memchr` for the needle's first
    /// `-`, which no letter case changes.
    private static func lastOccurrence(of needle: [UInt8], before end: Int, fd: Int32) -> Occurrence {
        let length = needle.count
        guard let anchor = needle.firstIndex(of: UInt8(ascii: "-")) else { return .none }
        var high = end
        while high >= length {
            let low = max(0, high - searchChunkBytes)
            guard let chunk = readBytes(fd, low..<high) else { return .readFailed }
            var last: Int?
            chunk.withUnsafeBytes { raw in
                guard let base = raw.baseAddress, raw.count >= length else { return }
                let bytes = raw.bindMemory(to: UInt8.self)
                // An anchor at `q` starts a candidate at `q - anchor`, which
                // must fit wholly in the chunk.
                let lastAnchor = raw.count - length + anchor
                var q = anchor
                while q <= lastAnchor {
                    guard let found = memchr(base + q, Int32(UInt8(ascii: "-")), lastAnchor - q + 1) else { break }
                    let at = base.distance(to: UnsafeRawPointer(found))
                    if matches(needle, in: bytes, at: at - anchor) { last = at - anchor }
                    q = at + 1
                }
            }
            if let last { return .at(low + last) }
            if low == 0 { return .none }
            high = low + length - 1
        }
        return .none
    }

    /// Byte compare that folds `A`–`F` to lower case — the only letters a
    /// UUID string holds.
    private static func matches(_ needle: [UInt8], in bytes: UnsafeBufferPointer<UInt8>, at start: Int) -> Bool {
        for index in 0..<needle.count {
            var byte = bytes[start + index]
            if byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "F") { byte |= 0x20 }
            if byte != needle[index] { return false }
        }
        return true
    }

    // MARK: Lines

    /// One past the nearest `\n` before `offset`, or the file's start.
    private static func lineStart(before offset: Int, fd: Int32) -> Int? {
        var high = offset
        while high > 0 {
            let low = max(0, high - lineChunkBytes)
            guard let chunk = readBytes(fd, low..<high) else { return nil }
            if let newline = chunk.lastIndex(of: 0x0A) { return low + newline + 1 }
            high = low
        }
        return 0
    }

    /// The nearest `\n` at or after `offset`, or the file's end — an
    /// unterminated last line is a line, as it is to `loadRuns`.
    private static func lineEnd(from offset: Int, size: Int, fd: Int32) -> Int? {
        var low = offset
        while low < size {
            let high = min(size, low + lineChunkBytes)
            guard let chunk = readBytes(fd, low..<high) else { return nil }
            if let newline = chunk.firstIndex(of: 0x0A) { return low + newline }
            low = high
        }
        return size
    }

    /// Exactly the bytes in `range`, or nil — a short read means the file
    /// changed under the scan, which it does not try to reason about.
    private static func readBytes(_ fd: Int32, _ range: Range<Int>) -> Data? {
        var data = Data(count: range.count)
        let complete = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return range.isEmpty }
            var offset = 0
            while offset < buffer.count {
                let n = pread(fd, base + offset, buffer.count - offset, off_t(range.lowerBound + offset))
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if n == 0 { return false }
                offset += n
            }
            return true
        }
        return complete ? data : nil
    }
}

// MARK: - Run context (device / build stamping)

enum SpikeRunContext {
    struct Stamp {
        let appVersion: String
        let appBuild: String
        let appCommit: String?
        let deviceModel: String
        let osVersion: String
        let timeZoneIdentifier: String
        let localeIdentifier: String
        /// "debug" or "release", decided at compile time (Fix Watch
        /// R-F4). Recorded because the two populations differ ~2× on
        /// commit timings and cannot be separated after the fact.
        let buildConfiguration: String
    }

    /// Compile-time truth, not a runtime guess.
    static var buildConfiguration: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    /// Captured fresh per run rather than cached: device/OS are fixed for
    /// the process, but time zone and locale can change while backgrounded
    /// (Settings app), and a stale stamp would silently mislabel a
    /// tz-sensitive measurement — the exact failure mode gh#197 comment #1
    /// calls out.
    static func stamp() -> Stamp {
        let info = Bundle.main.infoDictionary
        return Stamp(
            appVersion: (info?["CFBundleShortVersionString"] as? String) ?? "?",
            appBuild: (info?["CFBundleVersion"] as? String) ?? "?",
            // No build-phase commit stamping exists yet (see the harness
            // report's decision points) — reads a key that is simply
            // absent today so this stays nil rather than lying.
            appCommit: info?["DoneGitCommitSHA"] as? String,
            deviceModel: hardwareModelIdentifier(),
            osVersion: osVersionString(),
            timeZoneIdentifier: TimeZone.current.identifier,
            localeIdentifier: Locale.current.identifier,
            buildConfiguration: buildConfiguration
        )
    }

    private static func osVersionString() -> String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #endif
    }

    /// `UIDevice.current.model` only ever returns the generic "iPhone" on
    /// iOS — the specific hardware identifier (e.g. "iPhone15,3") comes
    /// from `uname`.
    private static func hardwareModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        return machineMirror.children.reduce(into: "") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            identifier += String(UnicodeScalar(UInt8(value)))
        }
    }
}
