//
//  SettingsOrphanCleanup.swift
//  Done
//
//  Takes out of the app's preferences what nothing reads any more: keys
//  whose code is gone, and the temp files an interrupted write of the
//  preferences plist leaves beside it. Idempotent — a run that finds
//  nothing changes nothing and writes no trail line — and run at launch on
//  a utility-priority task, never on the main thread.
//

import Foundation

nonisolated enum SettingsOrphanCleanup {

    /// Keys no target reads or writes. A key goes on this list only when
    /// `git grep` over the whole repository finds no reference to it, and
    /// the change that adds it says so:
    /// - the Google Calendar integration's (removed in January 2026): the
    ///   OAuth access and refresh tokens it kept in plain text, their
    ///   expiry, the account's email;
    /// - the token-inference state from before the `.v2` keys.
    /// Never a legacy key the storage migration still reads as its
    /// downgrade net, never a `syncHashes.` key, never a `.v2` key
    /// (SettingsOrphanCleanupTests).
    static let orphanedKeys = [
        "googleAccessToken", "googleRefreshToken", "googleTokenExpiry", "googleUserEmail",
        "tokenInferenceDynamicHypotheses.v1", "tokenInferenceMetaHypotheses.v1", "tokenInferenceProjections.v1",
    ]

    /// A temp file younger than this may be a write in progress.
    static let orphanFileAge: TimeInterval = 24 * 3600

    struct Outcome: Equatable {
        var removedKeys: [String] = []
        var removedFiles = 0
        var removedBytes: Int64 = 0

        var isEmpty: Bool { removedKeys.isEmpty && removedFiles == 0 }
    }

    /// One pass over `defaults` and over `preferencesDirectory`, where the
    /// live plist is `<bundleIdentifier>.plist`. Removed there: regular
    /// files named `<bundleIdentifier>.plist.` plus a non-empty suffix,
    /// last modified more than `orphanFileAge` before `now` — never the
    /// live plist, never a symlink or directory, never another name.
    @discardableResult
    static func run(defaults: UserDefaults, preferencesDirectory: URL?, bundleIdentifier: String?,
                    now: Date = Date()) -> Outcome {
        var outcome = Outcome()
        for key in orphanedKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
            // A value from the registration or global domain survives the
            // remove; it is not this app's to take, and not counted.
            if defaults.object(forKey: key) == nil { outcome.removedKeys.append(key) }
        }
        if let preferencesDirectory, let bundleIdentifier, !bundleIdentifier.isEmpty {
            let prefix = bundleIdentifier + ".plist."
            let fileManager = FileManager.default
            let names = (try? fileManager.contentsOfDirectory(atPath: preferencesDirectory.path)) ?? []
            for name in names where name.hasPrefix(prefix) && name.count > prefix.count {
                let url = preferencesDirectory.appendingPathComponent(name, isDirectory: false)
                // `attributesOfItem` does not follow a symlink: its type is the link's.
                guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      let modified = attributes[.modificationDate] as? Date,
                      now.timeIntervalSince(modified) > orphanFileAge
                else { continue }
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                guard (try? fileManager.removeItem(at: url)) != nil else { continue }
                outcome.removedFiles += 1
                outcome.removedBytes += size
            }
        }
        if !outcome.isEmpty {
            DiagnosticTrail.record("Persistence", "settings: cleanup removed keys=\(outcome.removedKeys.joined(separator: ",")) files=\(outcome.removedFiles) bytes=\(outcome.removedBytes)")
        }
        return outcome
    }

    /// The app's own: standard defaults, `Library/Preferences`, the main
    /// bundle's identifier. Off the main thread at utility priority.
    static func runForAppInBackground() {
        Task.detached(priority: .utility) {
            let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            run(defaults: .standard,
                preferencesDirectory: library?.appendingPathComponent("Preferences", isDirectory: true),
                bundleIdentifier: Bundle.main.bundleIdentifier)
        }
    }
}
