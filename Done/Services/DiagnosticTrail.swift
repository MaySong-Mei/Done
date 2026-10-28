//
//  DiagnosticTrail.swift
//  Done
//
//  An append-only diagnostic record that outlives the process that wrote it.
//
//  `os_log` is the right sink for live debugging, but it cannot answer the one
//  question this trail exists for. On iOS a third-party app can only read back
//  `OSLogStore(scope: .currentProcessIdentifier)` — its own *running* process.
//  Reading a previous process's entries needs the
//  `com.apple.logging.local-store` entitlement, which Apple does not issue to
//  third-party apps. So after a force-quit the relaunched app is blind to
//  everything the dead process logged, and "did the write the app reported
//  before it died actually survive?" is exactly a question you answer by
//  comparing the last lines of the previous run against the first lines of
//  this one.
//
//  Hence: written by us, to our own container, readable after a relaunch, and
//  exportable from inside the app so diagnosing a device does not require a
//  cable and a Mac running Console.
//
//  Durability: entries are appended synchronously — `write(2)` hands the bytes
//  to the kernel before `record` returns, so a SIGKILL (force-quit, jetsam)
//  cannot take them back. This is deliberately NOT deferred to a background
//  queue: a queued entry dies with the process, and the process dying is the
//  event we are trying to record. It is not proof against power loss; there is
//  no `fsync` here, because the failure mode being investigated is process
//  death, not device death.
//

import Foundation

/// Append-only, size-bounded diagnostic record stored in Application Support.
///
/// Two files are kept rather than a true ring: appending to a real ring means
/// rewriting a header on every entry, and a torn header loses the whole
/// buffer. Rotating whole files is crash-safe by construction — the worst a
/// kill during rotation can do is leave both files intact.
nonisolated enum DiagnosticTrail {
    /// Rotate once the live file passes this. Two files means the retained
    /// history is between one and two times this figure.
    static let rotateAtBytes = 192 * 1024

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var liveByteCount = 0
    nonisolated(unsafe) private static var didWriteSessionBanner = false
    nonisolated(unsafe) private static var clears = 0
    /// Stable for the lifetime of the process, so entries from different runs
    /// interleaved in one file can still be told apart.
    nonisolated(unsafe) private static var sessionID = String(UUID().uuidString.prefix(8))

    // MARK: - Locations

    /// Redirected under XCTest, for the same reason
    /// `EventStorageLocation.production` is: `DoneTests` runs inside Done.app,
    /// in Done.app's container, so an un-redirected path here is the dogfood
    /// user's own trail. And this facility is PURGE-CAPABLE — `clear()` is
    /// wired into the erase, `EventStore.clearAllLocalData` calls it as its
    /// last statement, and a dozen-odd tests drive one or the other. Running
    /// the suite on a device therefore used to destroy the real trail.
    ///
    /// That is worse than it sounds for this particular file: the trail exists
    /// to answer "did the write the app reported before it died actually
    /// survive?", which is answered by comparing a DEAD process's last lines
    /// against this one's first. There is no second copy to fall back on and
    /// no way to reconstruct it after the fact — the entitlement needed to
    /// read the system log store back is one Apple does not issue to us (see
    /// the file header). A test run was silently erasing the only record of
    /// the bug the run might be investigating.
    ///
    /// Redirect rather than refuse (which is what the shared asset directory
    /// got): the tests here legitimately exercise writing, rotation and
    /// clearing, and they can have all three against their own files. Nothing
    /// resolves a stored path against this directory, so moving it costs
    /// nothing.
    private static var directoryName: String {
        EventStorageLocation.isRunningUnderXCTest ? "Diagnostics-TestHost" : "Diagnostics"
    }

    /// Internal, not private: `MetricPayloadStore` puts its own rotation
    /// directory one level INSIDE this one and stakes its safety argument on
    /// that containment (rotation there deletes the oldest files in its own
    /// directory wholesale and must never be able to reach `trail.log`). It
    /// derives its parent from here rather than re-spelling the name, so the
    /// redirect moves both or neither — a second literal is how the two drift
    /// apart and the containment quietly stops holding.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    static var liveURL: URL { directory.appendingPathComponent("trail.log") }
    static var rotatedURL: URL { directory.appendingPathComponent("trail.1.log") }

    // MARK: - Writing

    /// Append one entry. Safe to call from any thread and from any point in the
    /// app's lifetime, including while it is being torn down.
    ///
    /// Never throws and never traps: a diagnostic facility that can crash the
    /// app is worse than no diagnostic facility. Failures degrade to "the line
    /// is missing", which the reader can see.
    static func record(_ category: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        if !didWriteSessionBanner {
            didWriteSessionBanner = true
            appendLocked(line: sessionBannerLine())
        }
        appendLocked(line: "\(timestamp()) [\(sessionID)] \(category) \(message)")
    }

    private static func sessionBannerLine() -> String {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        return "\(timestamp()) [\(sessionID)] session ==== LAUNCH v\(version) (\(build)) ===="
    }

    /// Caller must hold `lock`.
    private static func appendLocked(line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        // Costs one `stat` per entry, and it is not optional. Unlinking a file
        // does not invalidate an open descriptor on POSIX — the inode survives
        // with no name, so `write` keeps succeeding and keeps throwing nothing
        // while every byte goes somewhere unreachable. Without this check a
        // trail whose file was removed underneath us (container reset, a clear
        // from elsewhere) would look perfectly healthy and be empty at exactly
        // the moment it was needed. The entry volume here is a handful per
        // user action, so the syscall is affordable.
        if handle != nil, !FileManager.default.fileExists(atPath: liveURL.path) {
            try? handle?.close()
            handle = nil
        }
        if handle == nil { openLocked() }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            liveByteCount += data.count
            if liveByteCount >= rotateAtBytes { rotateLocked() }
        } catch {
            // Drop the handle so the next entry reopens rather than silently
            // discarding everything from here on.
            self.handle = nil
        }
    }

    /// Caller must hold `lock`.
    private static func openLocked() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: liveURL.path) {
            fm.createFile(atPath: liveURL.path, contents: nil)
        }
        guard let opened = try? FileHandle(forWritingTo: liveURL) else { return }
        liveByteCount = (try? opened.seekToEnd()).map(Int.init) ?? 0
        handle = opened
    }

    /// Caller must hold `lock`.
    private static func rotateLocked() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: rotatedURL)
        try? fm.moveItem(at: liveURL, to: rotatedURL)
        liveByteCount = 0
        // Reopened lazily by the next entry.
    }

    // MARK: - Reading

    /// Oldest-first concatenation of what is retained, ready to be read by a
    /// human or attached to a bug report.
    static func combinedText() -> String {
        lock.lock()
        // Flush our own buffered state before reading — `FileHandle.write`
        // already reached the kernel, but the handle keeps its own offset and
        // a reader opening the same path needs the writes visible.
        try? handle?.synchronize()
        lock.unlock()
        let older = (try? String(contentsOf: rotatedURL, encoding: .utf8)) ?? ""
        let newer = (try? String(contentsOf: liveURL, encoding: .utf8)) ?? ""
        return older + newer
    }

    /// Bytes currently retained across both files.
    static var retainedByteCount: Int {
        let fm = FileManager.default
        let sizes = [rotatedURL, liveURL].map { url -> Int in
            ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        }
        return sizes.reduce(0, +)
    }

    /// The fixed path `exportFile()` writes to. Named so `clear()` can remove
    /// it: the Developer page regenerates this copy on every `onAppear`, and
    /// "Clear Trail" telling the user the record is gone while a full copy
    /// sits in the temporary directory is a false promise — more so now that
    /// the trail carries session-lifecycle facts (gh#234).
    ///
    /// Carries the test-host suffix under XCTest for the same reason
    /// `directory` does: `clear()` removes this path too, so a shared name
    /// would have a test run delete the copy the user had just generated from
    /// the Developer page to attach to a report.
    static var exportURL: URL {
        let name = EventStorageLocation.isRunningUnderXCTest
            ? "done-diagnostic-trail-test-host.txt"
            : "done-diagnostic-trail.txt"
        return FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    /// Writes the combined trail to a share-ready file in the temporary
    /// directory and returns it. Regenerated on each call so what gets shared
    /// is what is on disk right now.
    static func exportFile() -> URL? {
        let text = combinedText()
        guard !text.isEmpty else { return nil }
        let url = exportURL
        do {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Clearing

    /// Goes up by one on every `clear()`. A writer that skips lines it has
    /// already written compares this to tell that what it remembers writing
    /// is no longer in the trail.
    static var clearGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return clears
    }

    /// Drops everything retained. Wired into the app's "erase local data" paths
    /// — the trail carries event IDs and counts, and a user asking for local
    /// traces to be erased means this one too.
    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
        liveByteCount = 0
        // A fresh banner belongs in the emptied file, not carried over.
        didWriteSessionBanner = false
        clears += 1
        try? FileManager.default.removeItem(at: liveURL)
        try? FileManager.default.removeItem(at: rotatedURL)
        // The share-ready copy is part of "everything retained".
        try? FileManager.default.removeItem(at: exportURL)
    }

    // MARK: - Formatting

    /// `ISO8601DateFormatter` is not cheap to construct, and this runs on the
    /// path of every persisted mutation.
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func timestamp() -> String {
        formatter.string(from: Date())
    }
}
