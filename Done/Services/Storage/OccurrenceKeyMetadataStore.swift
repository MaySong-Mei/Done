//
//  OccurrenceKeyMetadataStore.swift
//  Done
//
//  The frozen reference time zone, in durable metadata.
//
//  WHY THIS ONE IS NOT LIKE THE OTHERS
//  -----------------------------------
//  Everything else moved off `UserDefaults` in this series is user content
//  measured in hundreds of kilobytes. This is one identifier string, written
//  once, on first access, years ago. Its consequence is wildly out of
//  proportion to its size — and in the opposite direction from a lost array.
//
//  `CalendarOccurrenceKey.dayKey` is the identity field of every occurrence
//  record: which calendar day a feedback entry or a log entry belongs to. It is
//  derived in a DELIBERATELY frozen time zone so that identity survives the
//  user travelling, which is the whole reason the scalar exists. Losing the
//  scalar does not lose a day. It causes the next launch to freeze a NEW zone —
//  and if the user is somewhere else when that happens, every record already on
//  disk keeps its stored `dayKey` while every newly derived key disagrees with
//  it. Nothing is reported missing. Logs and feedback simply stop finding the
//  occurrence they belong to, and the further back you look, the more of them
//  are wrong.
//
//  So the scalar gets the same commit mechanics as the arrays, and the failure
//  posture is inverted to match the consequence: on an unreadable file this
//  store SERVES a best guess and REFUSES to write it. Re-freezing is the
//  damage; serving a wrong zone for one session is not.
//
//  It is a scalar/metadata file, deliberately not an array-shaped
//  `StorageSlot` — the slots are the user's data and are swept, wiped and
//  mirrored as a set, none of which is true of this. It lives in its own
//  directory for the reason every other value file does:
//  `DurableEventStorage.sweepUnknownEntries()` deletes anything off its
//  whitelist inside `EventStore/`.
//

import Combine
import Foundation
import os

private let occurrenceMetadataLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Done",
    category: "Persistence"
)

/// `ObservableObject` so `StorageFaultBanner` can watch it the way it watches
/// every other durable store that can refuse writes. The `.unusable` state is
/// decided at most once per process — at the first `resolve()` — so nothing is
/// published from the lazy read path (which can run inside a view body); the
/// only transitions that happen AFTER a banner could already be on screen are
/// the two user-confirmed exits, and those send.
@MainActor
final class OccurrenceKeyMetadataStore: ObservableObject {
    static let productionDirectoryName = "OccurrenceKey"
    static let testHostDirectoryName = "OccurrenceKey-TestHost"
    static let referenceTimeZoneFilename = "referenceTimeZone.json"

    /// The real store. Cut off from legacy migration under XCTest for the same
    /// reason the other production stores are: `DoneTests` is a host-app
    /// bundle, so an un-redirected path would have every test read and write
    /// the dogfood user's own frozen zone.
    static let shared = OccurrenceKeyMetadataStore(
        directory: productionDirectory(),
        legacyDefaults: EventStorageLocation.isRunningUnderXCTest ? nil : .standard
    )

    /// What the file (or the legacy key, or neither) had to say. Resolved at
    /// most once per process: `dayKey` is on the hot path — every occurrence
    /// lookup, every timeline render that touches a feedback record — and it
    /// used to cost a `UserDefaults` read, which must not become a stat().
    private enum Resolution {
        /// A zone was established, and this is it.
        case established(String, TimeZone)
        /// Provably never established anywhere. The only state that may be
        /// written over.
        case fresh
        /// The file could not be read, or holds an identifier this system does
        /// not know. Serve `zone` and NEVER commit it.
        case unusable(TimeZone)
    }

    let directory: URL

    private let file: AtomicValueFile<String>
    private let legacyDefaults: UserDefaults?
    private let currentTimeZone: () -> TimeZone
    private var resolution: Resolution?

    /// The file could not be READ. Distinct from "no zone has been frozen yet",
    /// which is `.fresh` and is a perfectly healthy first launch.
    ///
    /// Resolves first. The read is lazy — nothing touches the file until
    /// someone asks for the zone — so without this a caller that asked "are you
    /// healthy?" before anyone asked "which zone?" would be told yes by a store
    /// that had not looked. `resolve()` never writes; only `referenceTimeZone`
    /// does, and only from `.fresh`.
    var isFrozen: Bool {
        _ = resolve()
        return file.fault != nil
    }

    /// Injectable `currentTimeZone` because the interesting behaviour is what
    /// happens when the device's zone has CHANGED between two launches, and a
    /// test cannot move the simulator to Shanghai.
    init(directory: URL,
         legacyDefaults: UserDefaults?,
         currentTimeZone: @escaping () -> TimeZone = { TimeZone.current }) {
        self.directory = directory
        self.file = AtomicValueFile(directory: directory, filename: Self.referenceTimeZoneFilename)
        self.legacyDefaults = legacyDefaults
        self.currentTimeZone = currentTimeZone
    }

    // MARK: - Reading

    /// The zone `dayKey` is derived in. Establishes one on a genuinely first
    /// access, exactly as the `UserDefaults` version did — the difference is
    /// only that the write now lands on disk before the call returns.
    var referenceTimeZone: TimeZone {
        switch resolve() {
        case .established(_, let zone):
            return zone
        case .unusable(let zone):
            return zone
        case .fresh:
            // Write-on-first-access, preserved. This is the moment the zone is
            // frozen, and it is the only moment this store may write of its own
            // accord — `.fresh` is proof that nothing is being overwritten.
            let zone = currentTimeZone()
            let identifier = zone.identifier
            do {
                try file.commit(identifier)
                trail("occurrencekey: froze reference time zone \(identifier)")
            } catch {
                // Cache it anyway: a zone that flickers WITHIN a session would
                // split the day keys of a single sitting, which is worse than
                // one that is re-decided on the next launch. The next launch is
                // `.fresh` again and tries the write again.
                trailError("occurrencekey: could not persist the frozen time zone \(identifier): \(String(describing: error))")
            }
            resolution = .established(identifier, zone)
            return zone
        }
    }

    /// The identifier as the settings blob should carry it — or nil, meaning
    /// "this device has nothing to say about the frozen zone".
    ///
    /// Deliberately NON-establishing. `SyncedSettings.currentSnapshot()` runs
    /// on every settings upload and on every local snapshot; if reading it
    /// froze a zone, a device that had not yet drawn a calendar would freeze
    /// (and then broadcast) whatever zone it happened to be in at sync time.
    /// The `UserDefaults` version had this property for free — `object(forKey:)`
    /// does not write — and losing it would be a new bug wearing the old one's
    /// clothes.
    var establishedIdentifier: String? {
        if case .established(let identifier, _) = resolve() { return identifier }
        return nil
    }

    /// Whether the whole `user_settings` upload must be held back.
    ///
    /// `user_settings` is one row upserted WHOLE, so a key the blob omits is a
    /// key the cloud LOSES. `.fresh` may safely be omitted — nothing has been
    /// established, which is exactly what an absent `UserDefaults` key used to
    /// say. `.unusable` may not: the local copy is the broken one, the cloud's
    /// is the good one, and quietly dropping the key would delete it.
    var suppressesSettingsUpload: Bool {
        if case .unusable = resolve() { return true }
        return false
    }

    private func resolve() -> Resolution {
        if let resolution { return resolution }

        let outcome = file.read(legacy: { [legacyDefaults] in
            guard let legacyDefaults,
                  let identifier = legacyDefaults.string(
                    forKey: CalendarOccurrenceKey.referenceTimeZoneDefaultsKey
                  ),
                  TimeZone(identifier: identifier) != nil
            else { return .absent }
            // Migrated, never rewritten and never deleted: the untouched key is
            // what a downgraded binary lands on, and for this scalar landing on
            // the ORIGINAL frozen zone is the entire point.
            return .present(identifier)
        })

        let resolved: Resolution
        switch outcome {
        case .loaded(let identifier, let provenance):
            if let zone = TimeZone(identifier: identifier) {
                resolved = .established(identifier, zone)
                if provenance == .legacyMigrated {
                    trail("occurrencekey: migrated frozen time zone \(identifier) from UserDefaults")
                }
            } else {
                // Readable bytes, meaningless content (a hand-edited file, a
                // zone this OS build dropped). Serve something, commit nothing.
                resolved = .unusable(currentTimeZone())
                trailError("occurrencekey: stored time zone \(identifier) is unknown to this system; serving the current zone WITHOUT overwriting the file")
            }
        case .fresh:
            resolved = .fresh
        case .unreadable(let fault):
            // THE CASE THIS FILE EXISTS FOR. Serve the legacy key if it is
            // still there — it is the last thing that knows the original
            // answer — otherwise the current zone, and in NEITHER case write.
            // Committing here is the actual damage: the file may well be fine
            // and merely unreadable right now (a launch before first unlock is
            // enough), and re-freezing a different zone over it is not
            // recoverable by anything the user can do.
            let legacyIdentifier = legacyDefaults?.string(
                forKey: CalendarOccurrenceKey.referenceTimeZoneDefaultsKey
            )
            let zone = legacyIdentifier.flatMap { TimeZone(identifier: $0) } ?? currentTimeZone()
            resolved = .unusable(zone)
            trailError("occurrencekey: reference time zone UNREADABLE (\(fault)); serving \(zone.identifier) without committing it")
        }

        resolution = resolved
        return resolved
    }

    // MARK: - Writing

    /// Adopt an identifier that arrived in a restored settings blob.
    ///
    /// USER-CONFIRMED PATH ONLY, and the one write that may overwrite an
    /// established zone — including a frozen one, which is why it clears the
    /// fault. Cross-device agreement on `dayKey` is the whole purpose of the
    /// scalar, so a user who has looked at the cloud copy and accepted it is
    /// asking for exactly this.
    ///
    /// A nil or unknown identifier is a NO-OP, not a clear. A snapshot that
    /// does not carry the key says nothing about the user's frozen zone (an
    /// older snapshot, a peer that never uploaded it), and honouring that
    /// absence would delete an established zone and let the next access freeze
    /// wherever the device happens to be — which is the loss this whole file is
    /// about, arriving dressed as a restore.
    @discardableResult
    func applyRestoredIdentifier(_ identifier: String?) -> Bool {
        guard let identifier, let zone = TimeZone(identifier: identifier) else { return false }
        objectWillChange.send()
        file.clearFault()
        do {
            try file.commit(identifier, intent: .destructive)
            resolution = .established(identifier, zone)
            trail("occurrencekey: reference time zone RESTORED to \(identifier)")
            return true
        } catch {
            trailError("occurrencekey: restored time zone \(identifier) could not be written: \(String(describing: error))")
            // In memory the restore has landed, so this session already agrees
            // with the other devices; the file retries on the next restore.
            resolution = .established(identifier, zone)
            return false
        }
    }

    /// Erase the frozen zone along with the rest of the user's local data.
    ///
    /// USER-CONFIRMED PATH ONLY — "Reset all local data". This is the other
    /// legitimate exit from `.unusable` besides `applyRestoredIdentifier`, and
    /// before it existed there was NONE that a user could reach locally: one
    /// corrupt read of a once-written scalar (no `.bak` exists yet) left
    /// `suppressesSettingsUpload` true forever, which silently held back every
    /// settings upload AND every local DR snapshot, and the reset button wiped
    /// every other durable store around it.
    ///
    /// The wipe RE-FREEZES the device's current zone immediately, the same way
    /// `EventTypeTemplateStore.wipeToDefaults` commits its defaults straight
    /// after wiping: `AtomicValueFile.wipe()` deliberately keeps the commit
    /// witness, so an emptied-and-abandoned directory would read back as
    /// `.lostAfterCommit` — the very state this call exists to end. Freezing
    /// now is safe for the same reason a first launch's freeze is: every
    /// occurrence record whose `dayKey` the old zone anchored was just erased
    /// with the rest of the local data.
    func wipe() {
        objectWillChange.send()
        file.wipe()
        let zone = currentTimeZone()
        do {
            try file.commit(zone.identifier, intent: .destructive)
            trail("occurrencekey: reference time zone WIPED and re-frozen to \(zone.identifier)")
        } catch {
            trailError("occurrencekey: wipe could not persist \(zone.identifier): \(String(describing: error))")
        }
        resolution = .established(zone.identifier, zone)
    }

    // MARK: - Plumbing

    private func trail(_ message: String) {
        occurrenceMetadataLogger.log("\(message, privacy: .public)")
        DiagnosticTrail.record("Persistence", message)
    }

    private func trailError(_ message: String) {
        occurrenceMetadataLogger.error("\(message, privacy: .public)")
        DiagnosticTrail.record("Persistence", "ERROR " + message)
    }

    private static func productionDirectory() -> URL {
        let name = EventStorageLocation.isRunningUnderXCTest
            ? testHostDirectoryName
            : productionDirectoryName
        guard let base = try? EventStorageLocation.applicationSupport() else {
            // Unresolvable base: a path that cannot be created, so the file
            // raises `directoryUnavailable` and serves-without-writing rather
            // than freezing a zone somewhere purgeable.
            return URL(fileURLWithPath: "/dev/null").appendingPathComponent(name, isDirectory: true)
        }
        return base.appendingPathComponent(name, isDirectory: true)
    }

    // MARK: - Test-suite registry

    private final class Registration {
        weak var defaults: UserDefaults?
        let store: OccurrenceKeyMetadataStore
        init(defaults: UserDefaults, store: OccurrenceKeyMetadataStore) {
            self.defaults = defaults
            self.store = store
        }
    }

    private static var registry: [ObjectIdentifier: Registration] = [:]

    /// Which store a `SyncedSettings` call talks to. Same shape and same
    /// reasoning as `EventTypeCatalog.forDefaults`: `.standard` is the app and
    /// gets the one shared store; anything else is a test suite and gets its
    /// own store over a throwaway directory, keyed by object identity with a
    /// weak back-reference so a recycled address cannot inherit a dead suite's
    /// frozen zone.
    static func forDefaults(_ defaults: UserDefaults) -> OccurrenceKeyMetadataStore {
        if defaults === UserDefaults.standard { return shared }
        let key = ObjectIdentifier(defaults)
        if let existing = registry[key], existing.defaults === defaults { return existing.store }
        let store = OccurrenceKeyMetadataStore(directory: isolatedDirectory(), legacyDefaults: defaults)
        registry[key] = Registration(defaults: defaults, store: store)
        return store
    }

    /// Bind a suite to a store the caller built — the only way to hand the
    /// bridged `SyncedSettings` path a store in a specific state, because
    /// `forDefaults` owns both the directory and the moment of construction.
    static func register(_ store: OccurrenceKeyMetadataStore, for defaults: UserDefaults) {
        precondition(defaults !== UserDefaults.standard,
                     "the shared occurrence-key store is not replaceable")
        registry[ObjectIdentifier(defaults)] = Registration(defaults: defaults, store: store)
    }

    private static func isolatedDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("OccurrenceKeyMetadata", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
