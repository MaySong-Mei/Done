//
//  EventStorageLocation.swift
//  Done
//
//  Where an `EventStore`'s durable files live.
//
//  This exists because `DoneTests` is a HOST-APP test bundle: the tests run
//  inside Done.app, in Done.app's container. Isolation today is provided
//  entirely by `UserDefaults(suiteName:)`. A file store whose path is derived
//  from `FileManager.urls(for: .applicationSupportDirectory)` would therefore
//  have every test read and WRITE the real dogfood store — including the
//  host app's own `@StateObject EventStore`, which is constructed with
//  `.production` even while a test run is in progress.
//
//  So: `.production` is redirected to a separate directory whenever the
//  process is running under XCTest, and the location parameter on
//  `EventStore.init` has NO default value — forgetting it is a compile error,
//  not a silently-contaminated dogfood store.
//

import Foundation

enum EventStorageLocation: Equatable {
    /// The real store. Redirected to a sibling directory (and cut off from
    /// legacy migration) when the process is running under XCTest.
    case production
    /// A named directory under `EventStoreTests/`. Pair the name with the
    /// test's `UserDefaults` suite name so the two clean up together.
    case isolated(name: String)
    /// Throwaway directory under `NSTemporaryDirectory()`.
    case ephemeral(id: UUID)

    // MARK: - Test-host detection

    /// True inside an XCTest run. Injected by the test runner into the host
    /// app's environment; asserted by `EventStorageLocationTests` precisely
    /// because a silent failure here would mean tests writing the dogfood
    /// store rather than a redirected one.
    static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static let productionDirectoryName = "EventStore"
    static let testHostDirectoryName = "EventStore-TestHost"
    static let isolatedRootName = "EventStoreTests"

    // MARK: - Resolution

    /// Whether legacy `UserDefaults` keys are a valid migration source here.
    ///
    /// Off for `.production` under XCTest: the host app's own store must not
    /// suck the developer's/dogfooder's real `UserDefaults` blobs into the
    /// redirected test-host directory. On for `.isolated`/`.ephemeral`, which
    /// is what keeps the pre-existing "pre-seed the raw key, then boot a
    /// store" tests working — they became the migration regression net.
    var migratesLegacyDefaults: Bool {
        switch self {
        case .production: return !Self.isRunningUnderXCTest
        case .isolated, .ephemeral: return true
        }
    }

    var isProduction: Bool {
        if case .production = self { return true }
        return false
    }

    func directoryURL() throws -> URL {
        switch self {
        case .production:
            let name = Self.isRunningUnderXCTest
                ? Self.testHostDirectoryName
                : Self.productionDirectoryName
            return try Self.applicationSupport().appendingPathComponent(name, isDirectory: true)
        case .isolated(let name):
            return try Self.applicationSupport()
                .appendingPathComponent(Self.isolatedRootName, isDirectory: true)
                .appendingPathComponent(Self.sanitize(name), isDirectory: true)
        case .ephemeral(let id):
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("EventStore-\(id.uuidString)", isDirectory: true)
        }
    }

    private static func applicationSupport() throws -> URL {
        // `.applicationSupportDirectory` is NOT `Caches`/`tmp` (system-purgeable
        // = a fresh data-loss vector) and is included in device/iCloud backup,
        // matching where `Library/Preferences/<bid>.plist` lived. The backup
        // inclusion is deliberate and `isExcludedFromBackupKey` must never be
        // set here: a calendar is unrecoverable user-authored content, and
        // excluding it would hand a restored device an empty calendar — exactly
        // the class of disaster this change exists to remove.
        guard let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            throw CocoaError(.fileNoSuchFile)
        }
        return base
    }

    /// Suite names carry dots, spaces and UUIDs. Keep them recognisable but
    /// path-safe, and never let one escape its parent directory.
    static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var out = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        // A leading dot would make a hidden directory (and `.`/`..` would be a
        // traversal). Separators are already gone, but this closes the rest.
        while out.hasPrefix(".") { out.removeFirst() }
        if out.isEmpty { out = "unnamed" }
        return String(out.prefix(120))
    }

    // MARK: - Teardown

    /// Deletes the whole directory for a test location. Traps on `.production`
    /// — a test-support entry point must not be able to delete the real store,
    /// whatever it is handed.
    static func destroy(_ location: EventStorageLocation) {
        if location.isProduction {
            preconditionFailure("EventStorageLocation.destroy must never target .production")
        }
        guard let url = try? location.directoryURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Backstop for tests that leak (a `defer` that never ran, a crashed
    /// process). Only ever touches `EventStoreTests/`, never production.
    static func sweepStaleIsolatedDirectories(olderThan age: TimeInterval = 24 * 3600,
                                              now: Date = Date()) {
        guard let root = try? applicationSupport()
            .appendingPathComponent(isolatedRootName, isDirectory: true) else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, now.timeIntervalSince(modified) > age else { continue }
            try? fm.removeItem(at: entry)
        }
    }
}
