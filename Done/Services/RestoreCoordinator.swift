import Foundation
import Combine
import SwiftUI
import QuartzCore
import os

/// Shares the `Persistence` category with `EventStore`'s durability trail so a
/// single `log stream --predicate 'category == "Persistence"'` shows local
/// writes and cloud restores interleaved — the only way to tell "the write
/// never survived" from "the write survived and a restore undid it".
private let persistenceLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Done",
    category: "Persistence"
)

// RestoreStrategy / ConflictResolution live in Models/RestoreTypes.swift
// (shared, UIKit-free); PerRowDecisions stays here with the coordinator.

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
/// the user picks a resolution. Independent counts per table:
///   - `conflicts`: same identity on both sides with different content
///   - `addsFromCloud`: cloud has it, local doesn't → will be added
///   - `keepsLocalOnly`: local has it, cloud doesn't → will stay untouched
///   - `keptDeleted`: cloud has it, and this device deleted it without the
///     delete reaching the cloud → stays deleted, the delete goes up
/// The first is governed by the user's resolution choice; the others
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
    var keptDeleted: TableCounts = TableCounts()

    /// True when applying merge is a pure no-op — nothing to add, nothing to
    /// keep that's unique, nothing to resolve, no delete of the user's to
    /// keep. Used by `prepareMerge` to short-circuit the review step on
    /// fresh installs; a merge that keeps a delete is reviewed, so the user
    /// is told the row stays deleted.
    var isNoOp: Bool {
        conflicts.isEmpty && keepsLocalOnly.totalCount == 0 && addsFromCloud.totalCount == 0
            && keptDeleted.totalCount == 0
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

    /// Runs after a phase that shows the loading view is published and
    /// before the synchronous work that follows it, which on a large
    /// account holds the main thread long enough to notice. Without it the
    /// loading view never reaches the screen: SwiftUI draws after the
    /// current main-actor work returns, and the restore's work would run
    /// first — the user saw the previous page frozen instead of "正在恢复…".
    /// Injectable so a test can hold it and look at what has and has not
    /// happened by then.
    private let waitForLoadingFrame: @MainActor () async -> Void

    init(waitForLoadingFrame: @escaping @MainActor () async -> Void = { await DisplayedFrameWait.wait() }) {
        self.waitForLoadingFrame = waitForLoadingFrame
    }

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

    /// Which halves of a frozen event-type catalog this restore is entitled to
    /// unfreeze.
    struct CatalogUnfreeze: Equatable {
        var templates: Bool
        var colorHistory: Bool
    }

    /// A restore unfreezes on the strength of the user having accepted the
    /// cloud copy — so it may only unfreeze the halves the cloud copy actually
    /// CONTAINS. A `.merge` of a snapshot whose `eventTypes` array is empty (an
    /// older snapshot, or a peer that never uploaded its types) says nothing
    /// about the user's types: `applyRestore` short-circuits, no write happens,
    /// and an unconditional unfreeze would leave a writably EMPTY catalog
    /// standing over a quarantined file — where the next ordinary edit commits
    /// `[] + edit` and the now-unsuppressed sink mirrors that up as a delete of
    /// everything else.
    ///
    /// Static and pure so the rule can be read (and tested) without a network
    /// round trip standing in front of it.
    static func catalogUnfreeze(for snapshot: RestoreSnapshot) -> CatalogUnfreeze {
        let carriesHistory: Bool = {
            guard let value = snapshot.settings?[EventTypeTemplateStore.colorHistoryKey],
                  !(value is NSNull) else { return false }
            return true
        }()
        return CatalogUnfreeze(templates: !snapshot.eventTypes.isEmpty,
                               colorHistory: carriesHistory)
    }

    private func applyInternal(
        snapshot: RestoreSnapshot,
        strategy: RestoreStrategy,
        resolution: ConflictResolution,
        perRowDecisions: PerRowDecisions? = nil
    ) async {
        guard let eventStore, let eventTypeStore, let skillStore else { return }

        // Before the wait, with no suspension in between: every entry point
        // guards on a phase that is not `.applying`, so a second tap while
        // the spinner comes up starts nothing.
        phase = .applying(strategy)
        // The spinner reaches the screen first; it keeps turning while the
        // work below holds the main thread (the system animates it). The
        // wait goes BEFORE the store mutations, never between them — see
        // `markRestoreCompleted` below.
        await waitForLoadingFrame()

        // The snapshot was read above the cursor its fetch recorded; the
        // replay below hands the baseline the snapshot's versions and
        // `markRestoreCompleted` takes the cursor back to that position
        // (`RestoreFetchMark`). If the device's feed is no longer the one
        // that position was taken in — another account, an erase, or a
        // server epoch other than the one recorded at the fetch (a reset, or
        // a first epoch recorded after a fetch that saw none) — nothing is
        // applied: checked here, after the wait and before the first
        // mutation, with no suspension between this check and
        // `markRestoreCompleted`.
        if let syncService, let mark = snapshot.fetchMark,
           let refusal = syncService.restoreApplyRefusal(mark) {
            let refusedLine = "restore REFUSED reason=\(refusal.rawValue) strategy=\(String(describing: strategy)) resolution=\(String(describing: resolution))"
            persistenceLogger.log("\(refusedLine, privacy: .public)")
            DiagnosticTrail.record("Persistence", refusedLine)
            phase = .failed(L(.restoreSnapshotOutdated))
            return
        }

        // A merge leaves out the cloud rows this device deleted without the
        // delete reaching the cloud, and the replay in `markRestoreCompleted`
        // keeps those deletes' entries. Read here: after the refusal check,
        // before `applyRestore` and `clearCatalogFault` unfreeze anything (a
        // frozen table's emptiness is not a delete), and with no suspension
        // before the mutations and the replay. The preview's count was read
        // earlier and only informs the review.
        let pendingDeletes: RestorePendingDeletes = {
            guard strategy == .merge, let syncService else { return .none }
            return syncService.pendingDeletes(in: snapshot, eventStore: eventStore,
                                              eventTypeStore: eventTypeStore, skillStore: skillStore)
        }()

        let restoreLine = "restore APPLY strategy=\(String(describing: strategy)) resolution=\(String(describing: resolution)) cloudCalendarRows=\(snapshot.calendarEvents.count) localBefore=\(eventStore.rawCalendarEvents.count) keptDeleted=\(pendingDeletes.totalCount)"
        persistenceLogger.log("\(restoreLine, privacy: .public)")
        DiagnosticTrail.record("Persistence", restoreLine)
        var summary = eventStore.applyRestore(
            snapshot,
            strategy: strategy,
            resolution: resolution,
            perRowDecisions: perRowDecisions,
            pendingDeletes: pendingDeletes
        )
        // A restore is the one user-confirmed path back for a frozen catalog:
        // the user has looked at the cloud copy and said "use that". Nothing
        // automatic may unfreeze, because a frozen catalog presents as empty
        // and the next ordinary edit would write that emptiness down.
        //
        // "Use that" only covers what the snapshot actually holds, though —
        // see `catalogUnfreeze(for:)`.
        let unfreeze = Self.catalogUnfreeze(for: snapshot)
        eventTypeStore.clearCatalogFault(templates: unfreeze.templates,
                                         colorHistory: unfreeze.colorHistory)
        summary.addedTypes = eventTypeStore.applyRestore(
            templates: snapshot.eventTypes,
            strategy: strategy,
            resolution: resolution,
            perRowDecisions: perRowDecisions?.eventTypes,
            pendingDeletes: pendingDeletes.eventTypes
        )
        summary.addedSkills = skillStore.applyRestore(
            insights: snapshot.skills,
            strategy: strategy,
            resolution: resolution,
            perRowDecisions: perRowDecisions?.skills,
            pendingDeletes: pendingDeletes.skills
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

        // The token-inference state on that row is not restored: it is
        // device-local (`SupabaseSyncService.agentPreferencesTokenColumns`).

        // Agent conversation history. Re-encode the cloud's jsonb blob and hand
        // it to the durable repository, which commits it and posts its change
        // notification so the next `AgentService.init()` picks it up. Same
        // semantics as settings: cloud overwrites in `.cloudOverwritesLocal` or
        // `merge.keepCloud`; `merge.keepLocal` is a no-op.
        //
        // This is also the one user-confirmed path that may UNFREEZE the
        // repository — the user has looked at the cloud copy and said "use
        // that", which is the only evidence that outranks an unreadable local
        // file. Scoped to the branch that actually writes, for the same reason
        // the catalog's unfreeze is scoped to what the snapshot contains: a
        // `keepLocal` merge says nothing about the user's history, and lifting
        // the freeze on the strength of it would leave the repository writably
        // EMPTY for the next ordinary save to commit.
        if let conversationsBlob = snapshot.agentConversationsBlob {
            let shouldOverwrite: Bool = {
                switch strategy {
                case .cloudOverwritesLocal: return true
                case .merge:                return resolution == .keepCloud
                }
            }()
            if shouldOverwrite,
               let data = try? JSONSerialization.data(withJSONObject: conversationsBlob) {
                do {
                    try AgentConversationRepository.shared.applyRestore(blobData: data)
                } catch {
                    // A blob the cloud should not have sent. Logged rather than
                    // thrown on: the rest of this restore has already landed,
                    // and refusing the bad shape leaves the local history
                    // intact, which is the better of the two outcomes.
                    DiagnosticTrail.record(
                        "Persistence",
                        "ERROR agentchat: restored conversation blob rejected: \(String(describing: error))"
                    )
                }
            }
        }

        // Re-seed the sync service's diff baseline from the snapshot just
        // applied. Must happen on the same MainActor tick as the store
        // mutations above, before the upload sinks' debounce timer fires, so
        // the next sync sends only what differs from the cloud — after a
        // merge that includes the rows the cloud never had. It also takes
        // the pull cursor back to where the fetch began and, when that moved
        // it, asks for a pull at once, which re-delivers whatever changed on
        // the server since the snapshot was read, the user's review time
        // included.
        syncService?.markRestoreCompleted(
            eventStore: eventStore,
            eventTypeStore: eventTypeStore,
            skillStore: skillStore,
            snapshot: snapshot,
            strategy: strategy,
            keepingDeletes: pendingDeletes.baselineIds
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
    /// content), adds-from-cloud (id missing locally), keeps-local-only
    /// (id missing on cloud), and kept-deleted (a cloud row the merge leaves
    /// out because this device deleted it — the same rows `applyInternal`
    /// leaves out, read from the device as it is now). Event types use
    /// title-based identity instead of UUID — see
    /// `EventTypeTemplateStore.applyRestore`.
    private func computeMergePreview(against snapshot: RestoreSnapshot) -> MergePreview {
        guard let eventStore, let eventTypeStore, let skillStore else { return MergePreview() }
        var preview = MergePreview()
        let pending = syncService?.pendingDeletes(in: snapshot, eventStore: eventStore,
                                                  eventTypeStore: eventTypeStore, skillStore: skillStore) ?? .none

        let todoSummary = diffByID(local: eventStore.events, cloud: snapshot.todoEvents, id: \.id,
                                   pendingDeletes: pending.todoEvents)
        preview.conflicts.todoEvents = todoSummary.conflicts
        preview.addsFromCloud.todoEvents = todoSummary.addsFromCloud
        preview.keepsLocalOnly.todoEvents = todoSummary.keepsLocalOnly
        preview.keptDeleted.todoEvents = todoSummary.keptDeleted

        let calSummary = diffByID(local: eventStore.rawCalendarEvents, cloud: snapshot.calendarEvents, id: \.id,
                                  pendingDeletes: pending.calendarEvents)
        preview.conflicts.calendarEvents = calSummary.conflicts
        preview.addsFromCloud.calendarEvents = calSummary.addsFromCloud
        preview.keepsLocalOnly.calendarEvents = calSummary.keepsLocalOnly
        preview.keptDeleted.calendarEvents = calSummary.keptDeleted

        let logSummary = diffByID(local: eventStore.calendarEventLogRecords, cloud: snapshot.logs, id: \.id,
                                  pendingDeletes: pending.logs)
        preview.conflicts.logs = logSummary.conflicts
        preview.addsFromCloud.logs = logSummary.addsFromCloud
        preview.keepsLocalOnly.logs = logSummary.keepsLocalOnly
        preview.keptDeleted.logs = logSummary.keptDeleted

        let feedbackSummary = diffByID(local: eventStore.calendarEventFeedbackRecords, cloud: snapshot.feedback, id: \.id,
                                       pendingDeletes: pending.feedback)
        preview.conflicts.feedback = feedbackSummary.conflicts
        preview.addsFromCloud.feedback = feedbackSummary.addsFromCloud
        preview.keepsLocalOnly.feedback = feedbackSummary.keepsLocalOnly
        preview.keptDeleted.feedback = feedbackSummary.keptDeleted

        let listSummary = diffByID(local: eventStore.todoLists, cloud: snapshot.todoLists, id: \.id,
                                   pendingDeletes: pending.todoLists)
        preview.conflicts.todoLists = listSummary.conflicts
        preview.addsFromCloud.todoLists = listSummary.addsFromCloud
        preview.keepsLocalOnly.todoLists = listSummary.keepsLocalOnly
        preview.keptDeleted.todoLists = listSummary.keptDeleted

        let typeSummary = diffByTitle(
            local: eventTypeStore.templates,
            cloud: snapshot.eventTypes,
            pendingDeletes: pending.eventTypes
        )
        preview.conflicts.eventTypes = typeSummary.conflicts
        preview.addsFromCloud.eventTypes = typeSummary.addsFromCloud
        preview.keepsLocalOnly.eventTypes = typeSummary.keepsLocalOnly
        preview.keptDeleted.eventTypes = typeSummary.keptDeleted

        let skillSummary = diffByID(local: skillStore.insights, cloud: snapshot.skills, id: \.id,
                                    pendingDeletes: pending.skills)
        preview.conflicts.skills = skillSummary.conflicts
        preview.addsFromCloud.skills = skillSummary.addsFromCloud
        preview.keepsLocalOnly.skills = skillSummary.keepsLocalOnly
        preview.keptDeleted.skills = skillSummary.keptDeleted

        return preview
    }

    private struct DiffSummary<ID> {
        var conflicts: [ID] = []
        var addsFromCloud: Int = 0
        var keepsLocalOnly: Int = 0
        var keptDeleted: Int = 0
    }

    private func diffByID<T: Equatable, ID: Hashable>(
        local: [T], cloud: [T], id: KeyPath<T, ID>, pendingDeletes: Set<ID>
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
            } else if pendingDeletes.contains(cid) {
                result.keptDeleted += 1
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
        local: [EventTypeTemplate], cloud: [EventTypeTemplate], pendingDeletes: Set<UUID>
    ) -> DiffSummary<UUID> {
        let normalize = EventTypeTemplateStore.normalizedTitle
        let localByTitle = Dictionary(
            local.map { (normalize($0.title), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var result = DiffSummary<UUID>()
        // A type deleted here takes no part in the merge, matched by UUID and
        // set aside before the title dedupe — as `applyRestore` does.
        var seenPending = Set<UUID>()
        for t in cloud where pendingDeletes.contains(t.id) && seenPending.insert(t.id).inserted {
            result.keptDeleted += 1
        }
        // Pre-dedupe cloud by title so the same-name-multiple-cloud-rows case
        // (created by independent installs each seeding their own "Study"
        // etc.) doesn't inflate the conflict list and produce last-write-wins
        // ambiguity at apply time. Keeps the first occurrence.
        var seenCloudTitles = Set<String>()
        var dedupedCloud: [EventTypeTemplate] = []
        for t in cloud where !pendingDeletes.contains(t.id) && seenCloudTitles.insert(normalize(t.title)).inserted {
            dedupedCloud.append(t)
        }
        let cloudTitles = Set(dedupedCloud.map { normalize($0.title) })
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

// MARK: - Waiting for a frame

/// Suspends until the display has been handed the frames that follow the
/// call, so whatever was published just before it is on the screen before
/// the caller holds the main thread.
///
/// Counted in display refreshes (`CADisplayLink`), not in time: a changed
/// frame is committed to the render server between one refresh and the
/// next, and the continuation resumed from a refresh's callback runs only
/// after the main thread has finished that pass. More than one refresh,
/// so a change SwiftUI defers to the next main-queue turn is covered as
/// well as one it applies at once — at any refresh rate. Once
/// committed, the render server draws the frame, and turns the spinner,
/// without the main thread.
///
/// `ceiling` bounds the wait when no refresh comes (the app moved to the
/// background, the screen is off): the caller's work then runs anyway, as
/// it did before there was a wait.
@MainActor
enum DisplayedFrameWait {
    nonisolated static let frames = 2
    nonisolated static let ceiling: Duration = .milliseconds(500)

    static func wait(frames: Int = frames, ceiling: Duration = ceiling) async {
        #if os(iOS)
        await Ticker(frames: frames).run(ceiling: ceiling)
        #else
        // The Mac target compiles the restore coordinator but presents no
        // restore UI, so there is no loading view to wait for.
        #endif
    }

    #if os(iOS)
    /// One wait: a display link that resumes the waiter after `frames`
    /// refreshes, or when `ceiling` passes, whichever comes first — once.
    private final class Ticker: NSObject {
        private var remaining: Int
        private var link: CADisplayLink?
        private var continuation: CheckedContinuation<Void, Never>?
        private var timeout: Task<Void, Never>?

        init(frames: Int) {
            remaining = frames
        }

        func run(ceiling: Duration) async {
            guard remaining > 0 else { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                let link = CADisplayLink(target: self, selector: #selector(tick))
                link.add(to: .main, forMode: .common)
                self.link = link
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: ceiling)
                    guard !Task.isCancelled else { return }
                    self?.finish()
                }
            }
        }

        @objc private func tick(_ link: CADisplayLink) {
            remaining -= 1
            if remaining <= 0 { finish() }
        }

        private func finish() {
            // The link retains its target; invalidating releases the cycle.
            link?.invalidate()
            link = nil
            timeout?.cancel()
            timeout = nil
            continuation?.resume()
            continuation = nil
        }
    }
    #endif
}
