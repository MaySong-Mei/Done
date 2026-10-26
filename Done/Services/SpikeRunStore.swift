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
import UIKit

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
    // All three live INSIDE `location.directory`, so `wipe()` — already on
    // the erase list (`EraseWiringQATests`) — takes them with the records
    // and no second erase entry is needed (A·#23 / B·F12). Each is marked
    // excluded from backup: the records are deliberately backed up (the
    // deck says so), these are device-local bookkeeping that would be
    // wrong on a restored phone (a restored cursor says "uploaded" about
    // a server that never saw this install's rows).

    static let installIDFileName = ".install-id"
    static let uploadCursorFileName = ".upload-cursor.json"
    static let lastUploadSampleFileName = ".last-upload-sample.json"

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
    /// (gh#273 §7.5): the upload cursor, the install id and the last
    /// request sample — so the next install is a stranger to the server.
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

    static func loadRuns(spikeID: String, location: SpikeRunStorageLocation = .production, applyRetention: Bool = true) -> [SpikeRun] {
        let url = fileURL(spikeID: spikeID, location: location)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let text = String(decoding: data, as: UTF8.self)
        let records: [SpikeRun] = text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            // Never traps on a bad line (partial write from a kill mid-append,
            // or a future/older schema): skip it, do not crash the reader.
            guard let lineData = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(SpikeRun.self, from: lineData)
        }
        let collapsed = SpikeRunLog.collapse(records)
        return applyRetention ? SpikeRunLog.applyRetention(collapsed, cap: maxRunsPerSpike) : collapsed
    }

    static func latestRuns(spikeID: String, limit: Int, location: SpikeRunStorageLocation = .production) -> [SpikeRun] {
        Array(loadRuns(spikeID: spikeID, location: location).sorted { $0.startedAt > $1.startedAt }.prefix(limit))
    }

    // MARK: Writing internals

    /// Highest `revision` this process has appended per (directory, run
    /// id). The first append of an id in a process reads the file once to
    /// find what is already there; every later append for that id is a
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
            // Collapse keeps the LATEST line per id, and revisions only ever
            // go up in append order, so the latest line's revision is the max.
            current = loadRuns(spikeID: spikeID, location: location, applyRetention: false)
                .first { $0.id == id }?.revision ?? 0
        }
        let next = current + 1
        revisionCache[key] = next
        return next
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
        guard let handle = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? handle.close() }
        do {
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
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
            osVersion: UIDevice.current.systemVersion,
            timeZoneIdentifier: TimeZone.current.identifier,
            localeIdentifier: Locale.current.identifier,
            buildConfiguration: buildConfiguration
        )
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
