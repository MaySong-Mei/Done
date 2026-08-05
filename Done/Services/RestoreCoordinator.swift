import Foundation
import Combine
import SwiftUI
import os

/// Shares the `Persistence` category with `EventStore`'s durability trail so a
/// single `log stream --predicate 'category == "Persistence"'` shows local
/// writes and cloud restores interleaved — the only way to tell "the write
/// never survived" from "the write survived and a restore undid it".
private let persistenceLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Done",
    category: "Persistence"
)

/// How a restored cloud snapshot is reconciled with the device's current data.
/// `cloudOverwritesLocal` is destructive; `merge` is additive with user-chosen
/// resolution for ID collisions.
enum RestoreStrategy {
    /// Union of local + cloud. New cloud rows (no ID match locally) are always
    /// added. Rows with the same ID on both sides are "conflicts" — the user
    /// chooses how to resolve them via `ConflictResolution`.
    case merge

    /// Discard local data and replace with the cloud snapshot. Use only when the
    /// user explicitly wants to restore a fresh device from cloud backup.
    case cloudOverwritesLocal
}

/// How to resolve same-ID collisions during a merge. Can be applied uniformly
/// (batch path) or per-row (review-each path) via `PerRowDecisions`.
enum ConflictResolution: Equatable, Hashable {
    case keepLocal
    case keepCloud
}

/// Per-row overrides for merge conflict resolution. When provided to
/// `applyRestore`, the store consults this map first for each colliding row
/// and only falls back to the global `resolution` for rows the user didn't
/// explicitly decide. Keyed by table because each table has a different ID
/// type.
struct PerRowDecisions: Equatable {
    var calendarEvents: [UUID: ConflictResolution] = [:]
    var todoEvents: [UUID: ConflictResolution] = [:]
    var logs: [CalendarOccurrenceKey: ConflictResolution] = [:]
    var feedback: [CalendarOccurrenceKey: ConflictResolution] = [:]
    var todoLists: [UUID: ConflictResolution] = [:]
    var eventTypes: [UUID: ConflictResolution] = [:]
    var skills: [UUID: ConflictResolution] = [:]

    var totalCount: Int {
        calendarEvents.count + todoEvents.count + logs.count + feedback.count
            + todoLists.count + eventTypes.count + skills.count
    }

    /// Tally of explicit (user-touched) decisions in each direction. Used in
    /// the per-row UI's "Apply" button label.
    var counts: (localWins: Int, cloudWins: Int) {
        var local = 0, cloud = 0
        let allDicts: [[AnyHashable: ConflictResolution]] = [
            calendarEvents as [AnyHashable: ConflictResolution],
            todoEvents as [AnyHashable: ConflictResolution],
            logs as [AnyHashable: ConflictResolution],
            feedback as [AnyHashable: ConflictResolution],
            todoLists as [AnyHashable: ConflictResolution],
            eventTypes as [AnyHashable: ConflictResolution],
            skills as [AnyHashable: ConflictResolution],
        ]
        for dict in allDicts {
            for v in dict.values {
                switch v {
                case .keepLocal: local += 1
                case .keepCloud: cloud += 1
                }
            }
        }
        return (local, cloud)
    }
}

/// Per-table list of IDs where local and cloud both have the row with
/// different content. Non-collisions (cloud-only or local-only) are not
/// conflicts — they're additive.
struct ConflictReport: Equatable {
    var calendarEvents: [UUID] = []
    var todoEvents: [UUID] = []
    var logs: [CalendarOccurrenceKey] = []
    var feedback: [CalendarOccurrenceKey] = []
    var todoLists: [UUID] = []
    var eventTypes: [UUID] = []
    var skills: [UUID] = []

    var totalCount: Int {
        calendarEvents.count + todoEvents.count + logs.count + feedback.count
            + todoLists.count + eventTypes.count + skills.count
    }

    var isEmpty: Bool { totalCount == 0 }
}

/// Full preview of what `merge` will do to the local store, computed before
/// the user picks a resolution. Three independent counts per table:
///   - `conflicts`: same identity on both sides with different content
///   - `addsFromCloud`: cloud has it, local doesn't → will be added
///   - `keepsLocalOnly`: local has it, cloud doesn't → will stay untouched
/// The first is governed by the user's resolution choice; the other two
/// happen unconditionally and are shown so the user sees the full picture.
struct MergePreview: Equatable {
    struct TableCounts: Equatable {
        var calendarEvents = 0
        var todoEvents = 0
        var logs = 0
        var feedback = 0
        var todoLists = 0
        var eventTypes = 0
        var skills = 0

        var totalCount: Int {
            calendarEvents + todoEvents + logs + feedback + todoLists + eventTypes + skills
        }
    }

    var conflicts: ConflictReport = ConflictReport()
    var addsFromCloud: TableCounts = TableCounts()
    var keepsLocalOnly: TableCounts = TableCounts()

    /// True when applying merge is a pure no-op — nothing to add, nothing to
    /// keep that's unique, nothing to resolve. Used by `prepareMerge` to
    /// short-circuit the review step on fresh installs.
    var isNoOp: Bool {
        conflicts.isEmpty && keepsLocalOnly.totalCount == 0 && addsFromCloud.totalCount == 0
    }
}

/// Per-table tally returned from `apply(...)`. Numbers reflect what landed
/// in the local store as a result of the restore — not what was fetched from the
/// server (e.g. cloud rows already present locally don't increment `added*`).
struct RestoreApplySummary: Equatable {
    var addedTodoEvents = 0
    var addedCalendarEvents = 0
    var addedLogs = 0
    var addedFeedback = 0
    var addedLists = 0
    var addedTypes = 0
    var addedSkills = 0
    var replacedTotalCount = 0
}

/// Drives the cloud-restore flow.
///
/// State machine:
/// ```
/// idle → fetching → ready
///                      ├── applyOverwrite()         → applying → finished
///                      └── prepareMerge()
///                            ├── no conflicts        → applying → finished
///                            └── conflicts → mergeReview
///                                              └── applyMerge(resolution:) → applying → finished
/// ```
@MainActor
final class RestoreCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case fetching
        case ready(RestoreSnapshot)
        case mergeReview(RestoreSnapshot, MergePreview)
        case perRowReview(RestoreSnapshot, MergePreview)
        case applying(RestoreStrategy)
        case finished(RestoreApplySummary, RestoreStrategy, ConflictResolution?)
        case failed(String)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.fetching, .fetching): return true
            case (.ready, .ready): return true
            case (.mergeReview, .mergeReview): return true
            case (.perRowReview, .perRowReview): return true
            case (.applying(let a), .applying(let b)): return a == b
            case (.finished(let s1, let st1, let r1), .finished(let s2, let st2, let r2)):
                return s1 == s2 && st1 == st2 && r1 == r2
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    /// User-driven overrides for the per-row review path. Reset on entry; the
    /// view binds per-row pickers directly via `rowBinding(...)`.
    @Published var perRowDecisions: PerRowDecisions = PerRowDecisions()

    private weak var syncService: SupabaseSyncService?
    private weak var eventStore: EventStore?
    private weak var eventTypeStore: EventTypeTemplateStore?
    private weak var skillStore: SkillInsightStore?
    private weak var preferenceStore: AgentPreferenceStore?
    private weak var imageBackupCoordinator: ImageBackupCoordinator?

    init() {}

    /// Wire up dependencies after init. Must be called before `startFetch()`;
    /// allows the coordinator to be a `@StateObject` whose deps are created later.
    /// `imageBackupCoordinator` is optional — when present, restore will pull
    /// down any missing image binaries from Supabase Storage after applying
    /// events (so user-attached photos survive cross-device / cross-account
    /// recovery, per #22). Passing nil keeps the structured-only restore.
    func configure(
        syncService: SupabaseSyncService,
        eventStore: EventStore,
        eventTypeStore: EventTypeTemplateStore,
        skillStore: SkillInsightStore,
        preferenceStore: AgentPreferenceStore,
        imageBackupCoordinator: ImageBackupCoordinator? = nil
    ) {
        self.syncService = syncService
        self.eventStore = eventStore
        self.eventTypeStore = eventTypeStore
        self.skillStore = skillStore
        self.preferenceStore = preferenceStore
        self.imageBackupCoordinator = imageBackupCoordinator
    }

    var isConfigured: Bool { syncService != nil && eventStore != nil }

    /// Whether a restore can plausibly be offered right now — i.e. the local
    /// store looks like a brand-new install. We deliberately ignore
    /// `rawCalendarEvents` here because `EventStore.seedSampleCalendarEvents`
    /// populates it with 10 demo entries (with non-empty titles) on first run.
    /// User activity instead surfaces in todos, logs, or feedback — checking
    /// those three is the cleanest "user has interacted" signal.
    func shouldOfferAutoRestore() -> Bool {
        guard let eventStore else { return false }
        return eventStore.events.isEmpty
            && eventStore.calendarEventLogRecords.isEmpty
            && eventStore.calendarEventFeedbackRecords.isEmpty
    }

    func startFetch() async {
        guard let syncService else {
            phase = .failed("Restore service is not configured.")
            return
        }
        phase = .fetching
        do {
            let snapshot = try await syncService.fetchRestoreSnapshot()
            phase = .ready(snapshot)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Begin the merge flow. Computes a full preview (conflicts + adds + keeps)
    /// and transitions to `.mergeReview` unless the merge is a complete no-op
    /// (truly fresh device, nothing to add, nothing to keep, nothing to
    /// resolve), in which case the review step is skipped.
    func prepareMerge() async {
        guard case .ready(let snapshot) = phase else { return }
        let preview = computeMergePreview(against: snapshot)
        if preview.isNoOp {
            await applyInternal(snapshot: snapshot, strategy: .merge, resolution: .keepLocal)
        } else {
            phase = .mergeReview(snapshot, preview)
        }
    }

    /// Finalize a merge using the user-picked resolution. Only valid from the
    /// `.mergeReview` phase.
    func applyMerge(resolution: ConflictResolution) async {
        guard case .mergeReview(let snapshot, _) = phase else { return }
        await applyInternal(snapshot: snapshot, strategy: .merge, resolution: resolution)
    }

    /// Drop into per-row review for the fine-grained "pick winner per conflict"
    /// path. Called from `.mergeReview` when the user taps "Review each".
    /// Decisions start empty (i.e., everything defaults to keep-local until the
    /// user explicitly flips a row).
    func enterPerRowReview() {
        guard case .mergeReview(let snapshot, let preview) = phase else { return }
        perRowDecisions = PerRowDecisions()
        phase = .perRowReview(snapshot, preview)
    }

    /// Return to mergeReview without applying anything.
    func leavePerRowReview() {
        guard case .perRowReview(let snapshot, let preview) = phase else { return }
        phase = .mergeReview(snapshot, preview)
    }

    /// Finalize using per-row decisions; rows not explicitly touched fall back
    /// to keep-local.
    func applyPerRow() async {
        guard case .perRowReview(let snapshot, _) = phase else { return }
        await applyInternal(
            snapshot: snapshot,
            strategy: .merge,
            resolution: .keepLocal,
            perRowDecisions: perRowDecisions
        )
    }

    /// Two-way Binding for SwiftUI pickers. Reading defaults to `.keepLocal`
    /// when the row hasn't been touched. Writing publishes via the
    /// `@Published` wrapper.
    func rowBinding<ID: Hashable>(
        table: WritableKeyPath<PerRowDecisions, [ID: ConflictResolution]>,
        id: ID
    ) -> Binding<ConflictResolution> {
        Binding(
            get: { self.perRowDecisions[keyPath: table][id] ?? .keepLocal },
            set: { self.perRowDecisions[keyPath: table][id] = $0 }
        )
    }

    /// Apply the destructive "cloud overwrites local" strategy. Only valid from
    /// the `.ready` phase. The UI gates this behind a confirmation dialog.
    func applyOverwrite() async {
        guard case .ready(let snapshot) = phase else { return }
        await applyInternal(snapshot: snapshot, strategy: .cloudOverwritesLocal, resolution: .keepLocal)
    }

    private func applyInternal(
        snapshot: RestoreSnapshot,
        strategy: RestoreStrategy,
        resolution: ConflictResolution,
        perRowDecisions: PerRowDecisions? = nil
    ) async {
        guard let eventStore, let eventTypeStore, let skillStore else { return }

        let restoreLine = "restore APPLY strategy=\(String(describing: strategy)) resolution=\(String(describing: resolution)) cloudCalendarRows=\(snapshot.calendarEvents.count) localBefore=\(eventStore.rawCalendarEvents.count)"
        persistenceLogger.log("\(restoreLine, privacy: .public)")
        DiagnosticTrail.record("Persistence", restoreLine)
        phase = .applying(strategy)
        var summary = eventStore.applyRestore(
            snapshot,
            strategy: strategy,
            resolution: resolution,
            perRowDecisions: perRowDecisions
        )
        summary.addedTypes = eventTypeStore.applyRestore(
            templates: snapshot.eventTypes,
            strategy: strategy,
            resolution: resolution,
            perRowDecisions: perRowDecisions?.eventTypes
        )
        summary.addedSkills = skillStore.applyRestore(
            insights: snapshot.skills,
            strategy: strategy,
            resolution: resolution,
            perRowDecisions: perRowDecisions?.skills
        )

        // User settings (UserDefaults blob). For `cloudOverwritesLocal` we
        // fully replace local UserDefaults to match cloud. For `.merge` we
        // honor the resolution: keep-local adds only cloud-only keys,
        // keep-cloud overwrites collisions too.
        if let blob = snapshot.settings, !blob.isEmpty {
            switch strategy {
            case .cloudOverwritesLocal:
                SyncedSettings.replace(with: blob)
            case .merge:
                SyncedSettings.apply(blob, resolution: resolution)
            }
        }

        // Composer rescue drafts. Deliberately outside the block above: they
        // are local-only (not in the `SyncedSettings` allow-list, so
        // `replace` never touches them) and must be dropped whenever local
        // state is discarded, whether or not the snapshot carried settings.
        // A draft that survives a destructive restore describes an event the
        // restored data may already contain — accepting the banner would then
        // create a duplicate. Same reasoning as `resetAllLocalData`.
        if strategy == .cloudOverwritesLocal {
            CalendarComposerDraftStore.clear()
            CalendarEditDraftStore.clear()
            CalendarDetailComposerDraftStore.clear()
        }

        // Agent preferences (rules + decision history). Single-row blob.
        // Per-row conflict UI doesn't apply; merge.keepLocal is a no-op.
        if let preferenceStore,
           (snapshot.agentRules != nil || snapshot.agentDecisionHistory != nil) {
            preferenceStore.applyRestore(
                rules: snapshot.agentRules ?? [],
                decisionHistory: snapshot.agentDecisionHistory ?? [],
                strategy: strategy,
                resolution: resolution
            )
        }

        // TokenInferenceRepository's learned state (migration 011 — lives
        // on the same agent_preferences row). Same merge semantics: a
        // single-row blob per slice, keepLocal is a no-op, keepCloud
        // replaces in-memory + on-disk via the singleton's applyRestore.
        if snapshot.tokenDynamicHypotheses != nil ||
           snapshot.tokenMetaHypotheses != nil ||
           snapshot.tokenProjections != nil {
            TokenInferenceRepository.shared.applyRestore(
                dynamicHypotheses: snapshot.tokenDynamicHypotheses,
                metaHypotheses: snapshot.tokenMetaHypotheses,
                projections: snapshot.tokenProjections,
                strategy: strategy,
                resolution: resolution
            )
        }

        // Agent conversation history. Re-encode the cloud's jsonb blob
        // back into UserDefaults under `agentConversations` so the next
        // `AgentService.load()` picks it up. Same semantics as settings:
        // cloud overwrites in `.cloudOverwritesLocal` or `merge.keepCloud`;
        // `merge.keepLocal` is a no-op.
        if let conversationsBlob = snapshot.agentConversationsBlob {
            let shouldOverwrite: Bool = {
                switch strategy {
                case .cloudOverwritesLocal: return true
                case .merge:                return resolution == .keepCloud
                }
            }()
            if shouldOverwrite,
               let data = try? JSONSerialization.data(withJSONObject: conversationsBlob) {
                UserDefaults.standard.set(data, forKey: AgentConversationsStorageKey)
            }
        }

        // Re-seed the sync service's diff baseline with hashes computed from the
        // newly-restored local state. Must happen on the same MainActor tick as
        // the store mutations above, before the upload sinks' debounce timer
        // fires, so the next sync sees zero diff and doesn't churn the server.
        syncService?.markRestoreCompleted(
            eventStore: eventStore,
            eventTypeStore: eventTypeStore,
            skillStore: skillStore
        )

        // After structured restore, pull any cloud-backed image binaries
        // whose local files are missing (cross-device / cross-account
        // recovery per #22). We await this on purpose so the user doesn't
        // see "Restore complete" while photos are still streaming in.
        // For very large image libraries this can be slow; a future polish
        // could surface per-image progress in `RestoreSheet`'s applying view.
        if let imageBackupCoordinator {
            let allRestoredEvents = eventStore.events + eventStore.rawCalendarEvents
            await imageBackupCoordinator.downloadMissing(forEvents: allRestoredEvents)
            // Avatar lives at a fixed `_avatar.jpg` path, not tied to any
            // event — it has its own download path independent of the
            // per-event image walk above.
            await imageBackupCoordinator.downloadAvatarIfMissing()
        }

        let resolutionForSummary: ConflictResolution? = strategy == .merge ? resolution : nil
        phase = .finished(summary, strategy, resolutionForSummary)
    }

    func reset() {
        phase = .idle
    }

    // MARK: - Merge preview

    /// Compute the full merge preview: conflicts (same id/title, different
    /// content), adds-from-cloud (id missing locally), and keeps-local-only
    /// (id missing on cloud). Event types use title-based identity instead of
    /// UUID — see `EventTypeTemplateStore.applyRestore`.
    private func computeMergePreview(against snapshot: RestoreSnapshot) -> MergePreview {
        guard let eventStore, let eventTypeStore, let skillStore else { return MergePreview() }
        var preview = MergePreview()

        let todoSummary = diffByID(local: eventStore.events, cloud: snapshot.todoEvents, id: \.id)
        preview.conflicts.todoEvents = todoSummary.conflicts
        preview.addsFromCloud.todoEvents = todoSummary.addsFromCloud
        preview.keepsLocalOnly.todoEvents = todoSummary.keepsLocalOnly

        let calSummary = diffByID(local: eventStore.rawCalendarEvents, cloud: snapshot.calendarEvents, id: \.id)
        preview.conflicts.calendarEvents = calSummary.conflicts
        preview.addsFromCloud.calendarEvents = calSummary.addsFromCloud
        preview.keepsLocalOnly.calendarEvents = calSummary.keepsLocalOnly

        let logSummary = diffByID(local: eventStore.calendarEventLogRecords, cloud: snapshot.logs, id: \.id)
        preview.conflicts.logs = logSummary.conflicts
        preview.addsFromCloud.logs = logSummary.addsFromCloud
        preview.keepsLocalOnly.logs = logSummary.keepsLocalOnly

        let feedbackSummary = diffByID(local: eventStore.calendarEventFeedbackRecords, cloud: snapshot.feedback, id: \.id)
        preview.conflicts.feedback = feedbackSummary.conflicts
        preview.addsFromCloud.feedback = feedbackSummary.addsFromCloud
        preview.keepsLocalOnly.feedback = feedbackSummary.keepsLocalOnly

        let listSummary = diffByID(local: eventStore.todoLists, cloud: snapshot.todoLists, id: \.id)
        preview.conflicts.todoLists = listSummary.conflicts
        preview.addsFromCloud.todoLists = listSummary.addsFromCloud
        preview.keepsLocalOnly.todoLists = listSummary.keepsLocalOnly

        let typeSummary = diffByTitle(
            local: eventTypeStore.templates,
            cloud: snapshot.eventTypes
        )
        preview.conflicts.eventTypes = typeSummary.conflicts
        preview.addsFromCloud.eventTypes = typeSummary.addsFromCloud
        preview.keepsLocalOnly.eventTypes = typeSummary.keepsLocalOnly

        let skillSummary = diffByID(local: skillStore.insights, cloud: snapshot.skills, id: \.id)
        preview.conflicts.skills = skillSummary.conflicts
        preview.addsFromCloud.skills = skillSummary.addsFromCloud
        preview.keepsLocalOnly.skills = skillSummary.keepsLocalOnly

        return preview
    }

    private struct DiffSummary<ID> {
        var conflicts: [ID] = []
        var addsFromCloud: Int = 0
        var keepsLocalOnly: Int = 0
    }

    private func diffByID<T: Equatable, ID: Hashable>(
        local: [T], cloud: [T], id: KeyPath<T, ID>
    ) -> DiffSummary<ID> {
        // Some ID types deliberately collapse multiple rows to the same
        // hashable identity (most notably `CalendarOccurrenceKey` for log /
        // feedback records, whose `==` for `.singleEvent` only compares
        // `eventID`). If user data ever ends up with duplicate-keyed rows we
        // must not crash on `Dictionary(uniqueKeysWithValues:)` — keep the
        // first occurrence and treat subsequent duplicates as already-counted.
        let localByID = Dictionary(
            local.map { ($0[keyPath: id], $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let cloudIDs = Set(cloud.map { $0[keyPath: id] })
        var result = DiffSummary<ID>()
        var seenCloudIDs = Set<ID>()
        for c in cloud {
            let cid = c[keyPath: id]
            // Skip duplicate cloud rows so the conflict count doesn't inflate.
            guard seenCloudIDs.insert(cid).inserted else { continue }
            if let l = localByID[cid] {
                if l != c { result.conflicts.append(cid) }
            } else {
                result.addsFromCloud += 1
            }
        }
        var seenLocalIDs = Set<ID>()
        for l in local where !cloudIDs.contains(l[keyPath: id]) {
            let lid = l[keyPath: id]
            guard seenLocalIDs.insert(lid).inserted else { continue }
            result.keepsLocalOnly += 1
        }
        return result
    }

    private func diffByTitle(
        local: [EventTypeTemplate], cloud: [EventTypeTemplate]
    ) -> DiffSummary<UUID> {
        let normalize = EventTypeTemplateStore.normalizedTitle
        let localByTitle = Dictionary(
            local.map { (normalize($0.title), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // Pre-dedupe cloud by title so the same-name-multiple-cloud-rows case
        // (created by independent installs each seeding their own "Study"
        // etc.) doesn't inflate the conflict list and produce last-write-wins
        // ambiguity at apply time. Keeps the first occurrence.
        var seenCloudTitles = Set<String>()
        var dedupedCloud: [EventTypeTemplate] = []
        for t in cloud where seenCloudTitles.insert(normalize(t.title)).inserted {
            dedupedCloud.append(t)
        }
        let cloudTitles = Set(dedupedCloud.map { normalize($0.title) })
        var result = DiffSummary<UUID>()
        for c in dedupedCloud {
            let key = normalize(c.title)
            if let l = localByTitle[key] {
                if l != c { result.conflicts.append(c.id) }
            } else {
                result.addsFromCloud += 1
            }
        }
        for l in local where !cloudTitles.contains(normalize(l.title)) {
            result.keepsLocalOnly += 1
        }
        return result
    }

}
