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

    // MARK: Writing

    @discardableResult
    static func beginRun(_ run: SpikeRun, location: SpikeRunStorageLocation = .production) -> Bool {
        precondition(run.endedAt == nil, "beginRun requires an open record (endedAt == nil)")
        return appendLine(run, spikeID: run.spikeID, location: location)
    }

    @discardableResult
    static func finishRun(_ run: SpikeRun, location: SpikeRunStorageLocation = .production) -> Bool {
        precondition(run.endedAt != nil, "finishRun requires a closed record (endedAt set)")
        let wrote = appendLine(run, spikeID: run.spikeID, location: location)
        compactIfNeeded(spikeID: run.spikeID, location: location)
        return wrote
    }

    /// Re-appends a run with an edited note. Legal on open or closed runs
    /// — a note is a human observation, not part of the measurement, so
    /// there is no reason to require the run be finished first.
    @discardableResult
    static func setNote(_ note: String, forRunID id: UUID, spikeID: String, location: SpikeRunStorageLocation = .production) -> Bool {
        var runs = loadRuns(spikeID: spikeID, location: location, applyRetention: false)
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return false }
        runs[index].note = note
        let wrote = appendLine(runs[index], spikeID: spikeID, location: location)
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
                appendLine(closed, spikeID: spikeID, location: location)
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

    @discardableResult
    private static func appendLine(_ run: SpikeRun, spikeID: String, location: SpikeRunStorageLocation) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(run) else { return false }
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
