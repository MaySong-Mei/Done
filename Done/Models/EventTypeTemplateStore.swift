//
//  EventTypeTemplateStore.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import SwiftUI
import Combine

struct EventTypeTemplate: Codable, Hashable, Identifiable {
    var id: UUID
    var title: String
    var colorHex: String

    init(id: UUID = UUID(), title: String, colorHex: String) {
        self.id = id
        self.title = title
        self.colorHex = colorHex
    }
}

enum EventTypeTemplateChangeResult: Equatable {
    case created(EventTypeTemplate)
    case existing(EventTypeTemplate)
    case invalid
}

/// The durable, process-wide owner of the event-type templates and the
/// deleted-type color history.
///
/// WHY A SINGLETON BEHIND THE STORE
/// --------------------------------
/// `EventTypeTemplateStore` is constructed per view (`@StateObject` in six
/// places) plus once in `AgentRuntime`. While the data lived in `UserDefaults`
/// each of those instances read the same bytes, so the duplication was merely
/// wasteful; the moment it lives in a file, N instances would mean N caches
/// that only agree until one of them writes. Worse, `save()` from a stale
/// instance would commit ITS array over the file. So exactly one object owns
/// the truth and every store is a thin, self-refreshing mirror of it — which
/// also fixes the pre-existing cross-instance staleness for free.
///
/// The files live in `Application Support/EventTypes/`, deliberately NOT under
/// `EventStore/`: `DurableEventStorage.sweepUnknownEntries()` deletes anything
/// off its whitelist in that directory, so a `templates.json` next to the
/// slots would be swept on the next launch.
@MainActor
final class EventTypeCatalog {
    static let productionDirectoryName = "EventTypes"
    static let testHostDirectoryName = "EventTypes-TestHost"
    static let templatesFilename = "templates.json"
    static let colorHistoryFilename = "colorHistory.json"

    static let fallbackTemplates: [EventTypeTemplate] = [
        EventTypeTemplate(title: "Study", colorHex: "#34C759"),
        EventTypeTemplate(title: "Work", colorHex: "#0A84FF"),
        EventTypeTemplate(title: "Exercise", colorHex: "#FFD60A"),
        EventTypeTemplate(title: "Sleep", colorHex: "#AF52DE")
    ]

    /// The real catalog. Redirected to a sibling directory (and cut off from
    /// legacy migration) under XCTest, for the same reason
    /// `EventStorageLocation.production` is: `DoneTests` is a host-app bundle,
    /// so an un-redirected path would have every test read and write the
    /// dogfood user's own types.
    static let shared = EventTypeCatalog(
        directory: productionDirectory(),
        legacyDefaults: EventStorageLocation.isRunningUnderXCTest ? nil : .standard
    )

    /// Broadcast after any change to `templates` or `colorHistory`, including
    /// a fault being cleared. Every `EventTypeTemplateStore` re-mirrors on it.
    let changes = PassthroughSubject<Void, Never>()

    private(set) var templates: [EventTypeTemplate] = []
    private(set) var colorHistory: [String: String] = [:]

    /// Where the two files live. Exposed because a caller that wants to reason
    /// about the catalog's storage (diagnostics, and the tests that stage a
    /// damaged file) should not have to guess it back out of the app-support
    /// path rules.
    let directory: URL

    private let templatesFile: AtomicValueFile<[EventTypeTemplate]>
    private let historyFile: AtomicValueFile<[String: String]>
    private let legacyDefaults: UserDefaults?
    private var writeFailedFiles: Set<String> = []

    /// TWO files, TWO freeze scopes — deliberately not one `isFrozen` that ORs
    /// them into every decision.
    ///
    /// The templates array is authored content: unreadable means refuse every
    /// edit and suppress the mirror, because `diffSync` uploading fallback
    /// rows DELETEs the user's real cloud types. The color history is a
    /// nicety — it re-colors a re-created type — and the migration funnel
    /// already says so in as many words ("dropping one unreadable entry beats
    /// refusing every template edit"). A single OR'd predicate made a shredded
    /// history do exactly what that comment forbids: lock out create, rename,
    /// recolor, reorder and delete over a lost color map.
    var isTemplatesFrozen: Bool { templatesFile.fault != nil }
    var isColorHistoryFrozen: Bool { historyFile.fault != nil }
    /// Either file. The right predicate for the two consumers that span BOTH —
    /// the degraded banner, and the local DR snapshot, whose one document
    /// carries the templates array *and* (through the settings blob) the color
    /// history, so a hole in either poisons it.
    var isFrozen: Bool { isTemplatesFrozen || isColorHistoryFrozen }
    /// Frozen, or a write did not land. Either way the user gets the banner.
    var isDegraded: Bool { isFrozen || !writeFailedFiles.isEmpty }

    init(directory: URL, legacyDefaults: UserDefaults?) {
        self.directory = directory
        self.templatesFile = AtomicValueFile(directory: directory, filename: Self.templatesFilename)
        self.historyFile = AtomicValueFile(directory: directory, filename: Self.colorHistoryFilename)
        self.legacyDefaults = legacyDefaults
        load()
    }

    // MARK: - Load

    private func load() {
        switch templatesFile.read(legacy: { [legacyDefaults] in
            guard let legacyDefaults,
                  let data = legacyDefaults.data(forKey: EventTypeTemplateStore.storageKey) else {
                return .absent
            }
            // Both historical shapes, because the funnel is the ONLY path off
            // the legacy key: accepting one of them would freeze every user
            // still on the other.
            if let decoded = try? JSONDecoder().decode([EventTypeTemplate].self, from: data) {
                return decoded.isEmpty ? .absent : .present(decoded)
            }
            if let decoded = try? JSONDecoder().decode([String].self, from: data) {
                return decoded.isEmpty ? .absent : .present(decoded.map {
                    EventTypeTemplate(title: $0, colorHex: EventTypeTemplateStore.defaultColorHex(for: $0))
                })
            }
            return .damaged(detail: "eventTypeTemplates: neither [EventTypeTemplate] nor [String]",
                            raw: data)
        }) {
        case .loaded(let rows, _):
            templates = rows
        case .fresh:
            // Served, NOT written — today's behaviour for a user who never
            // touched types, kept so a future build that changes the built-in
            // list still reaches them. The first edit persists the whole array.
            templates = Self.fallbackTemplates
        case .unreadable:
            // NEVER the built-in four here. That is the whole point: a default
            // served over damaged data is indistinguishable from a choice the
            // user made, and within seconds it is the cloud's copy too.
            // `AtomicValueFile` has already promoted `.bak` if it could, so
            // what is left is genuinely nothing.
            templates = []
        }

        switch historyFile.read(legacy: { [legacyDefaults] in
            // A plist dictionary, not `Data` — `saveColorToHistory` used
            // `defaults.set(dictionary:)`.
            guard let legacyDefaults,
                  let raw = legacyDefaults.object(forKey: EventTypeTemplateStore.colorHistoryKey) else {
                return .absent
            }
            guard let dictionary = raw as? [String: Any] else {
                return .damaged(detail: "eventTypeColorHistory: not a dictionary", raw: nil)
            }
            // Salvage rather than freeze on a stray non-string value: this map
            // is a nicety (it re-colors a re-created type), so dropping one
            // unreadable entry beats refusing every template edit.
            let salvaged = dictionary.compactMapValues { $0 as? String }
            return salvaged.isEmpty ? .absent : .present(salvaged)
        }) {
        case .loaded(let dictionary, _):
            colorHistory = dictionary
        case .fresh, .unreadable:
            colorHistory = [:]
        }
    }

    // MARK: - Mutation

    /// Refuses while frozen, so the caller can mirror back the truth. Returns
    /// false ALSO when the write failed — but in that case the in-memory value
    /// has already moved, matching `EventStore.persist`: memory is what the
    /// user sees, and forking it from disk silently is its own way to lose
    /// work. The banner is what tells them.
    @discardableResult
    func setTemplates(_ rows: [EventTypeTemplate]) -> Bool {
        guard !isTemplatesFrozen else {
            DiagnosticTrail.record("Persistence", "ERROR eventtypes: templates write REFUSED (templates file frozen)")
            return false
        }
        templates = rows
        let landed = write(Self.templatesFilename) { try templatesFile.commit(rows) }
        changes.send()
        return landed
    }

    /// Refused only by ITS OWN file's fault. A frozen templates file does not
    /// reach in here: the one caller that writes both — `remove(title:)` —
    /// checks that the removal actually took before recording the color, so
    /// the pairing is enforced where the pairing exists rather than by
    /// widening this refusal to a file that is perfectly readable.
    @discardableResult
    func setColorHistory(_ history: [String: String]) -> Bool {
        guard !isColorHistoryFrozen else {
            DiagnosticTrail.record("Persistence", "ERROR eventtypes: colorHistory write REFUSED (history file frozen)")
            return false
        }
        colorHistory = history
        let landed = write(Self.colorHistoryFilename) { try historyFile.commit(history) }
        changes.send()
        return landed
    }

    /// Unfreeze. Only ever called from inside a user-confirmed restore or a
    /// wipe — an automatic path must never do this, because a frozen catalog
    /// presents as empty and the next ordinary edit would write that emptiness
    /// down.
    ///
    /// Per file, because a restore only ever arrives holding SOME of them: a
    /// snapshot with no `eventTypes` array says nothing about the user's
    /// types, and lifting the freeze on the strength of it would leave the
    /// catalog writably empty — the next ordinary edit commits `[] + edit`
    /// over the quarantined file and the sink mirrors that up.
    func clearFault(templates: Bool = true, colorHistory: Bool = true) {
        guard templates || colorHistory else { return }
        if templates {
            templatesFile.clearFault()
            writeFailedFiles.remove(Self.templatesFilename)
        }
        if colorHistory {
            historyFile.clearFault()
            writeFailedFiles.remove(Self.colorHistoryFilename)
        }
        changes.send()
    }

    /// "Reset all local data". Clears the fault first, mirroring
    /// `EventStore.clearAllLocalData`: a frozen file must still be erasable —
    /// the user asked for the data to be gone, and a file we could not READ is
    /// one we can still empty.
    ///
    /// The built-ins are WRITTEN here rather than served unsaved, because
    /// after a reset they are a state the user asked for, not an absence.
    func wipeToDefaults() {
        templatesFile.wipe()
        historyFile.wipe()
        writeFailedFiles.removeAll()
        templates = Self.fallbackTemplates
        colorHistory = [:]
        _ = write(Self.templatesFilename) {
            try templatesFile.commit(Self.fallbackTemplates, intent: .destructive)
        }
        _ = write(Self.colorHistoryFilename) {
            try historyFile.commit([:], intent: .destructive)
        }
        changes.send()
    }

    private func write(_ name: String, _ body: () throws -> Void) -> Bool {
        do {
            try body()
            writeFailedFiles.remove(name)
            return true
        } catch {
            writeFailedFiles.insert(name)
            DiagnosticTrail.record("Persistence", "ERROR eventtypes: \(name) write failed: \(error)")
            return false
        }
    }

    // MARK: - Directories

    private static func productionDirectory() -> URL {
        let name = EventStorageLocation.isRunningUnderXCTest
            ? testHostDirectoryName
            : productionDirectoryName
        guard let base = try? EventStorageLocation.applicationSupport() else {
            // Unresolvable base: hand the files a path that cannot be created
            // so they raise `directoryUnavailable` and freeze, rather than
            // quietly writing somewhere purgeable.
            return URL(fileURLWithPath: "/dev/null").appendingPathComponent(name, isDirectory: true)
        }
        return base.appendingPathComponent(name, isDirectory: true)
    }

    // MARK: - Test-suite registry

    private final class Registration {
        weak var defaults: UserDefaults?
        let catalog: EventTypeCatalog
        init(defaults: UserDefaults, catalog: EventTypeCatalog) {
            self.defaults = defaults
            self.catalog = catalog
        }
    }

    private static var registry: [ObjectIdentifier: Registration] = [:]
    private static var didSweepIsolatedDirectories = false

    /// Which catalog an `EventTypeTemplateStore(defaults:)` talks to.
    ///
    /// `.standard` is the app, and gets the one shared catalog. Anything else
    /// is a test suite: it gets its own catalog over its own throwaway
    /// directory, paired with that suite, so the pre-existing "pre-seed the
    /// raw key, then boot a store" tests stay the migration regression net
    /// (`EventAgenticIntakeCodableTests`, `EventStoreDurabilityTests`) without
    /// any of them touching the production directory.
    ///
    /// Keyed by object identity with a weak back-reference, because a
    /// `UserDefaults` suite name is not recoverable from the instance and a
    /// bare address can be reused after the old suite deallocates — the
    /// identity check is what stops a recycled address inheriting a dead
    /// suite's templates.
    static func forDefaults(_ defaults: UserDefaults) -> EventTypeCatalog {
        if defaults === UserDefaults.standard { return shared }
        let key = ObjectIdentifier(defaults)
        if let existing = registry[key], existing.defaults === defaults { return existing.catalog }
        let catalog = EventTypeCatalog(directory: isolatedDirectory(), legacyDefaults: defaults)
        registry[key] = Registration(defaults: defaults, catalog: catalog)
        return catalog
    }

    /// Bind a suite to a catalog the caller built.
    ///
    /// The only way to hand the bridged `SyncedSettings` path a catalog in a
    /// specific state, because `forDefaults` owns both the directory and the
    /// moment of construction — and a fault is raised during construction, so
    /// there is no "corrupt it afterwards" that the registry's instance would
    /// ever notice. `.standard` is refused outright: the app's own catalog is
    /// not something a caller gets to swap.
    static func register(_ catalog: EventTypeCatalog, for defaults: UserDefaults) {
        precondition(defaults !== UserDefaults.standard,
                     "the shared catalog is not replaceable")
        registry[ObjectIdentifier(defaults)] = Registration(defaults: defaults, catalog: catalog)
    }

    private static func isolatedDirectory() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("EventTypeCatalogs", isDirectory: true)
        if !didSweepIsolatedDirectories {
            didSweepIsolatedDirectories = true
            sweepStaleIsolatedDirectories(under: root)
        }
        return root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Backstop for suites that leak (a `tearDown` that never ran, a crashed
    /// process). Only ever touches the throwaway root.
    private static func sweepStaleIsolatedDirectories(under root: URL,
                                                      olderThan age: TimeInterval = 24 * 3600) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let now = Date()
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, now.timeIntervalSince(modified) > age else { continue }
            try? fm.removeItem(at: entry)
        }
    }
}

/// A thin, self-refreshing mirror of `EventTypeCatalog` with the API the views
/// already use. Holds no truth of its own: every mutation goes to the catalog
/// and comes back through `catalog.changes`.
final class EventTypeTemplateStore: ObservableObject {
    @Published private(set) var templates: [EventTypeTemplate] = []
    /// Frozen or write-failed. Published so the persistence-degraded banner
    /// can watch it the same way it watches `EventStore.persistenceDegraded`.
    @Published private(set) var isCatalogDegraded = false

    static let storageKey = "eventTypeTemplates"
    /// Neutral gray used as the fallback type color and the default for new templates.
    static let fallbackColorHex = "#8E8E93"
    /// Deliberate neutral for an *uncategorized* (empty-type) calendar block
    /// on the canvas — a softer, cooler tone than `fallbackColorHex` so an
    /// untyped item reads as an intentional "not filed yet" state rather than
    /// the mid-gray that doubles as a new template's placeholder color.
    /// Canvas-render only (`CalendarLayout.eventColor`); analytics/reports keep
    /// bucketing empty type as "Other" and color that independently.
    static let uncategorizedColorHex = "#A8ACB8"
    /// Migration source and the `SyncedSettings` key. Never written to except
    /// by "reset all local data", which is the only place allowed to purge a
    /// legacy key — the untouched blob is the rollback safety net.
    static let colorHistoryKey = "eventTypeColorHistory"

    let catalog: EventTypeCatalog
    private var catalogSubscription: AnyCancellable?

    private var fallbackTemplates: [EventTypeTemplate] { EventTypeCatalog.fallbackTemplates }

    convenience init(defaults: UserDefaults = .standard) {
        self.init(catalog: EventTypeCatalog.forDefaults(defaults))
    }

    /// Bind to an explicit catalog. The `defaults:` initializer resolves one
    /// through the registry, which owns the directory — so this is what a test
    /// simulating a relaunch (two catalogs, one directory) needs.
    init(catalog: EventTypeCatalog) {
        self.catalog = catalog
        mirrorCatalog()
        catalogSubscription = catalog.changes.sink { [weak self] in self?.mirrorCatalog() }
    }

    private func mirrorCatalog() {
        if templates != catalog.templates { templates = catalog.templates }
        if isCatalogDegraded != catalog.isDegraded { isCatalogDegraded = catalog.isDegraded }
    }

    /// EITHER file could not be read. The predicate for the two consumers that
    /// span both — the degraded banner and the local DR snapshot. For anything
    /// that acts on one of the files, use the specific one below; do not
    /// re-derive an equivalent test at a call site.
    var isCatalogFrozen: Bool { catalog.isFrozen }

    /// THE predicate for "these templates must not leave memory": every export
    /// path is a mirror, and mirroring an unreadable store deletes the copy it
    /// mirrors onto. See `EventTypeCatalog.isTemplatesFrozen`.
    var areTemplatesFrozen: Bool { catalog.isTemplatesFrozen }

    /// The color history could not be read — which is NOT the same as it being
    /// empty, and the difference matters because the settings blob is upserted
    /// whole: an omitted key deletes the cloud's copy.
    var isColorHistoryFrozen: Bool { catalog.isColorHistoryFrozen }

    /// Deleted-type color memory, read through the durable store rather than
    /// `UserDefaults` (`SyncedSettings` bridges the key to here).
    var colorHistory: [String: String] { catalog.colorHistory }

    /// User-confirmed restore only, and only for the halves the restore
    /// actually carries — see `EventTypeCatalog.clearFault(templates:colorHistory:)`.
    func clearCatalogFault(templates: Bool = true, colorHistory: Bool = true) {
        catalog.clearFault(templates: templates, colorHistory: colorHistory)
    }

    func ensureIncludes(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !templates.contains(where: { $0.title == trimmed }) {
            templates.append(
                EventTypeTemplate(title: trimmed, colorHex: Self.defaultColorHex(for: trimmed))
            )
            save()
        }
    }

    func add(_ title: String, colorHex: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !templates.contains(where: { $0.title == trimmed }) else { return }
        templates.append(EventTypeTemplate(title: trimmed, colorHex: colorHex))
        save()
    }

    func contains(title: String) -> Bool {
        let normalized = Self.normalizedTitle(title)
        guard !normalized.isEmpty else { return false }
        return templates.contains { Self.normalizedTitle($0.title) == normalized }
    }

    @discardableResult
    func ensureTemplate(title: String) -> EventTypeTemplateChangeResult {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalid }

        if let existing = templates.first(where: { Self.normalizedTitle($0.title) == Self.normalizedTitle(trimmed) }) {
            return .existing(existing)
        }

        let created = EventTypeTemplate(title: trimmed, colorHex: Self.defaultColorHex(for: trimmed))
        templates.append(created)
        save()
        return .created(created)
    }

    func update(from originalTitle: String, to newTitle: String, colorHex: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = templates.firstIndex(where: { $0.title == originalTitle }) else { return }

        if let existingIndex = templates.firstIndex(where: { $0.title == trimmed }),
           existingIndex != index {
            templates[existingIndex].colorHex = colorHex
            templates.remove(at: index)
        } else {
            templates[index].title = trimmed
            templates[index].colorHex = colorHex
        }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        templates.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func remove(title: String) {
        guard let index = templates.firstIndex(where: { $0.title == title }) else { return }
        let colorHex = templates[index].colorHex
        templates.remove(at: index)
        save()
        // `save()` mirrors the catalog back, so a refused write leaves the
        // type standing — and remembering the color of a type that was never
        // removed is how the history fills with entries for live templates.
        // This is the whole reason a frozen templates file does not need to
        // reach into `setColorHistory`: the pairing is checked where it exists.
        guard !templates.contains(where: { $0.title == title }) else { return }
        saveColorToHistory(title: title, colorHex: colorHex)
    }

    func resetToDefaults() {
        catalog.wipeToDefaults()
        mirrorCatalog()
    }

    func colorHex(for title: String) -> String {
        if let match = templates.first(where: { $0.title == title }) {
            return match.colorHex
        }
        return Self.defaultColorHex(for: title)
    }

    static func color(for title: String, defaults: UserDefaults = .standard) -> Color {
        ColorHex.toColor(colorHex(for: title, defaults: defaults))
    }

    /// The one static color read, used by 40-odd call sites and by the widget
    /// snapshot builder (`EventStore.sharedSnapshotEvents`).
    ///
    /// It used to JSON-decode the whole templates blob out of `UserDefaults`
    /// on EVERY call, which was both slow and — more importantly — a SECOND
    /// source of truth: after the live store migrated to a file, this would
    /// have kept answering from the frozen legacy key, so the canvas and the
    /// widget could show a color the user had already changed. Now it reads
    /// the same in-memory catalog the live store mirrors, so they cannot
    /// diverge, and it is strictly cheaper than before.
    ///
    /// Under a freeze the ladder degrades to last-known-good → history →
    /// deterministic default: colors get duller, nothing gets uploaded.
    static func colorHex(for title: String, defaults: UserDefaults = .standard) -> String {
        let catalog = EventTypeCatalog.forDefaults(defaults)
        if let match = catalog.templates.first(where: { $0.title == title }) {
            return match.colorHex
        }
        if let hex = catalog.colorHistory[title] {
            return hex
        }
        return Self.defaultColorHex(for: title)
    }

    static func normalizedTitle(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    /// Push the local array through the catalog and take back whatever the
    /// catalog decided. That last step is the point: a frozen catalog refuses
    /// and leaves its own array standing, so mirroring back is what reverts an
    /// edit the file will never receive — instead of leaving the UI showing a
    /// change that does not exist anywhere.
    private func save() {
        catalog.setTemplates(templates)
        mirrorCatalog()
    }

    private func saveColorToHistory(title: String, colorHex: String) {
        var history = catalog.colorHistory
        history[title] = colorHex
        catalog.setColorHistory(history)
        mirrorCatalog()
    }

    /// Apply a cloud restore snapshot.
    ///
    /// Event types are deduped by **normalized title** (not UUID), because the
    /// user-facing identity is the title — events reference their type via
    /// `Event.type: String`, not via the template's UUID. Different devices
    /// independently generate UUIDs for the seed types ("Study", "Work", …);
    /// merging by UUID would clone them visibly. Title is the right dedupe key.
    ///
    /// - `.merge`: union by normalized title. Cloud rows with a new title are
    ///   appended. Same-title collisions resolve to `.keepLocal` (no-op) or
    ///   `.keepCloud` (replace the local row, adopting cloud's UUID + colorHex).
    /// - `.cloudOverwritesLocal`: replace `templates` entirely. Cloud's own
    ///   title duplicates are collapsed before assignment so the user doesn't
    ///   inherit server-side clutter. Falls back to the built-in defaults if
    ///   cloud delivered no templates so the store is never left empty.
    ///   `resolution` is ignored.
    /// Returns the number of templates added (or set, when overwriting) that
    /// actually reached the file — zero if the catalog was still frozen, which
    /// it will be whenever the restore carried no types to unfreeze it with.
    @discardableResult
    func applyRestore(
        templates incoming: [EventTypeTemplate],
        strategy: RestoreStrategy,
        resolution: ConflictResolution,
        perRowDecisions: [UUID: ConflictResolution]? = nil
    ) -> Int {
        switch strategy {
        case .cloudOverwritesLocal:
            let deduped = Self.dedupedByTitle(incoming)
            let resolved = deduped.isEmpty ? fallbackTemplates : deduped
            templates = resolved
            save()
            // A still-frozen catalog refuses, and `save()` mirrors its own
            // array back over `templates`. Report what LANDED — a restore
            // summary that says "4 types" when the file received none is the
            // user's only signal that it did not work.
            return templates == resolved ? resolved.count : 0

        case .merge:
            // Dedupe cloud by normalized title before merging so same-title
            // duplicates (e.g., two cloud "Study" rows from different installs'
            // seed runs) don't produce last-write-wins ambiguity. Matches the
            // pre-dedup `cloudOverwritesLocal` already does on its input.
            let dedupedIncoming = Self.dedupedByTitle(incoming)
            var added = 0
            var didMutate = false
            for cloud in dedupedIncoming {
                let key = Self.normalizedTitle(cloud.title)
                if let idx = templates.firstIndex(where: {
                    Self.normalizedTitle($0.title) == key
                }) {
                    let effective = perRowDecisions?[cloud.id] ?? resolution
                    if effective == .keepCloud {
                        templates[idx] = cloud
                        didMutate = true
                    }
                } else {
                    templates.append(cloud)
                    added += 1
                    didMutate = true
                }
            }
            guard didMutate else { return 0 }
            let intended = templates
            save()
            return templates == intended ? added : 0
        }
    }

    /// Drop server-side title duplicates so a single cloud restore can't
    /// inflate the local list. Keeps the first occurrence of each normalized
    /// title.
    private static func dedupedByTitle(_ list: [EventTypeTemplate]) -> [EventTypeTemplate] {
        var seen = Set<String>()
        var result: [EventTypeTemplate] = []
        for t in list where seen.insert(normalizedTitle(t.title)).inserted {
            result.append(t)
        }
        return result
    }

    /// Internal rather than private: `EventTypeCatalog` needs it to colorize
    /// the legacy `[String]` shape during migration, and the acceptance tests
    /// assert the static readers degrade to exactly this under a freeze.
    static func defaultColorHex(for title: String) -> String {
        switch title {
        case "":
            // Uncategorized (empty type) resolves to the deliberate neutral
            // everywhere a color is shown for it — canvas, list, share card,
            // detail dot AND badges — so an untyped item reads consistently.
            // Distinct from `fallbackColorHex`, which still serves as a new
            // template's placeholder (non-empty titles keep that gray).
            return uncategorizedColorHex
        case "Study":
            return "#34C759"
        case "Work":
            return "#0A84FF"
        case "Exercise":
            return "#FFD60A"
        case "Sleep":
            return "#AF52DE"
        default:
            return fallbackColorHex
        }
    }
}

enum ColorHex {
    static func toColor(_ hex: String) -> Color {
        let sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        let value = UInt64(sanitized, radix: 16)

        switch sanitized.count {
        case 6:
            guard let value else { return .secondary }
            let red = Double((value >> 16) & 0xFF) / 255.0
            let green = Double((value >> 8) & 0xFF) / 255.0
            let blue = Double(value & 0xFF) / 255.0
            return Color(red: red, green: green, blue: blue)
        case 8:
            guard let value else { return .secondary }
            let red = Double((value >> 24) & 0xFF) / 255.0
            let green = Double((value >> 16) & 0xFF) / 255.0
            let blue = Double((value >> 8) & 0xFF) / 255.0
            let opacity = Double(value & 0xFF) / 255.0
            return Color(red: red, green: green, blue: blue, opacity: opacity)
        default:
            return .secondary
        }
    }

    static func fromColor(_ color: Color) -> String {
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            let redByte = colorByte(red)
            let greenByte = colorByte(green)
            let blueByte = colorByte(blue)
            let alphaByte = colorByte(alpha)
            if alphaByte == 255 {
                return String(format: "#%02X%02X%02X", redByte, greenByte, blueByte)
            }
            return String(format: "#%02X%02X%02X%02X", redByte, greenByte, blueByte, alphaByte)
        }
        return EventTypeTemplateStore.fallbackColorHex
    }

    private static func colorByte(_ value: CGFloat) -> Int {
        Int((max(0, min(1, value)) * 255.0).rounded())
    }
}
