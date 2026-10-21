//
//  SyncApplier.swift
//  Done
//
//  Applies ONE already-decoded page of `sync_changes` to local state —
//  design §6 (the rule table and its per-table sections), §6.1 (two passes,
//  one persist per slot per page, refusal), §6.2 (the reference zone first)
//  and §6.4 (the erase epoch) of Docs/sync/00-realtime-sync-design.md. No
//  network: the puller hands a page in, the outcome says whether the page
//  counts as applied (I1) and what the engine still owes (the event_types
//  losers to tombstone directly, the pending-verify keys the page cleared).
//
//  The decisions are the pure pieces' (`SyncDecision`, `SyncSettingsMerge`,
//  `SyncEventTypeWinners`, `SyncSingletonTombstone`); this file only wires
//  them to the stores, the shelf, the baseline and the cursor, in this order:
//
//    0. precheck — every slot the page touches (and the slots its cascades
//       and the zone rule read) is unfrozen, and every table has a store;
//       otherwise the page is refused and nothing is written.
//    1. zone first — a live user_settings row's reference zone is decided
//       (§6.2) before any occurrence-keyed row of the page is decoded:
//       decoding a single-event key reads the reference calendar, which
//       freezes the device's own zone on a fresh install. A zone write that
//       does not land stops the page as a failed commit of user_settings.
//    2. pass 1, read only — the three-way decision for every row, against
//       the arrays and baseline as they were before the page; every losing
//       version is appended to the shelf NOW, including the dirty or
//       never-uploaded records a tombstone cascade will prune (fresh-eyes
//       B2). A failed append refuses the page: the shelf is the only copy.
//    3. pass 2 — the arrays change in memory; tombstones run the existing
//       delete cascades' in-memory steps, with image files left alone.
//    4. persist — each touched slot once, in a fixed order, the erase epoch
//       checked right before every write; the record prune of a cascade
//       runs only after the calendar commit returned true (#145); a slot's
//       baseline is written right after its own commit (I3); a false stops
//       the page there, cursor untouched. "True" means the slot's bytes are
//       durable, every store write it made included: a store that swallows
//       a failed write cannot report one.
//    5. cursor — `SyncCursorStore.commit`, with every table that APPEARED
//       in the page (skipped rows included, S11 / B1).
//
//  Rows the cascades change without an incoming version (orphaned
//  interrupt children, released absorbed todos, interrupt timeline items)
//  get no baseline write and stay dirty (I2), so the outbound flush carries
//  the repair to the server.
//

import Foundation

/// One `sync_changes` page as the gateway decoded it: rows from any of the
/// nine tables, in seq order.
struct RemotePage {
    let rows: [SyncFeedRow]

    var firstSeq: Int64? { rows.map(\.seq).min() }
    var lastSeq: Int64? { rows.map(\.seq).max() }
}

/// A store the applier writes a single-row-per-user table through
/// (agent_preferences, agent_conversations). The rows are hashed in the
/// outbound projection on both sides, so "same" means what the pusher means.
@MainActor
protocol SyncSingletonAdapter: AnyObject {
    /// The store could not be read: the page is refused (§6.1 precheck).
    var isFrozen: Bool { get }
    /// The local row, in the outbound projection.
    func localRow() -> [String: Any]
    /// The incoming row decoded and re-projected the way the pusher would
    /// send it; nil when it does not decode.
    func projected(_ incoming: [String: Any]) -> [String: Any]?
    /// Adopt the incoming row. True only when every write it made is
    /// durable; false stops the page before this slot's baseline.
    func adopt(_ incoming: [String: Any]) -> Bool
}

/// The slots one page persists, in the order it persists them. The
/// calendar goes first so a cascade's record prune can follow its commit.
enum SyncApplySlot: String, CaseIterable {
    case calendarEvents
    case events
    case calendarEventLogRecords
    case calendarEventFeedbackRecords
    case todoLists
    case eventTypes = "event_types"
    case skillInsights = "skill_insights"
    case userSettings = "user_settings"
    case agentPreferences = "agent_preferences"
    case agentConversations = "agent_conversations"

    /// The baseline table label whose entries this slot's commit carries.
    var baselineTable: String {
        switch self {
        case .calendarEvents: return "calendar_events"
        case .events: return "events"
        case .calendarEventLogRecords: return "event_logs"
        case .calendarEventFeedbackRecords: return "event_feedback"
        case .todoLists: return "todo_lists"
        case .eventTypes, .skillInsights, .userSettings, .agentPreferences, .agentConversations:
            return rawValue
        }
    }

    init?(baselineTable: String) {
        guard let slot = Self.allCases.first(where: { $0.baselineTable == baselineTable }) else { return nil }
        self = slot
    }

    var storageSlot: StorageSlot? {
        switch self {
        case .calendarEvents: return .calendarEvents
        case .events: return .events
        case .calendarEventLogRecords: return .calendarEventLogRecords
        case .calendarEventFeedbackRecords: return .calendarEventFeedbackRecords
        case .todoLists: return .todoLists
        default: return nil
        }
    }
}

/// Everything one page application needs besides the page.
@MainActor
struct SyncApplyContext {
    /// The engine: the user, the baseline, the cursor, the pending-verify
    /// set, and the row projections the pusher hashes with.
    let engine: SupabaseSyncService
    let shelf: ConflictShelf
    /// `LocalDataEraseEpoch.capture()`, taken before the RPC that fetched
    /// this page.
    let eraseToken: Int
    /// The issue number of the RPC that returned this page (design §6
    /// "`[]` 的收口"): only an element recorded before it may be cleared.
    let pullIssue: Int
    var eventTypeStore: EventTypeTemplateStore?
    var skillStore: SkillInsightStore?
    /// agent_preferences / agent_conversations, by table.
    var singletons: [String: SyncSingletonAdapter] = [:]
    /// The in-flight table (design §6 结果未知的写): what an outstanding
    /// write of ours for the key sent. nil when nothing is outstanding.
    var inFlight: (SyncBaselineKey) -> PendingVerifyPayload? = { _ in nil }
    /// A catch-up in progress (design §6.6 设备追平): the pre-rules run on
    /// every stale entry the page meets, before the §6 table.
    var catchUp: SyncCatchUpContext?
    /// False for rows a recovery write-back landed: applied like a page,
    /// but a write's seq is not a feed position and must not move the cursor.
    var commitsCursor = true
    /// Test seam: every step, in order, as it is taken.
    var trace: ((String) -> Void)?

    init(engine: SupabaseSyncService, shelf: ConflictShelf, eraseToken: Int, pullIssue: Int) {
        self.engine = engine
        self.shelf = shelf
        self.eraseToken = eraseToken
        self.pullIssue = pullIssue
    }
}

enum SyncApplyRefusal: Equatable {
    /// A slot the page touches (or its cascade / zone rule reads) is frozen.
    case frozen(slot: String)
    /// A shelf append failed (I/O). Nothing else was written.
    case shelf
    /// The page carries a table the context has no store for.
    case missingStore(table: String)
    /// No signed-in user: nothing can be scoped, nothing is written.
    case signedOut
}

enum SyncApplyStatus: Equatable {
    /// Every touched slot persisted, every baseline written, the cursor
    /// committed.
    case applied
    /// Refused before anything but shelf lines (and, for a live settings
    /// row, the §6.2 zone decision) was written.
    case refused(SyncApplyRefusal)
    /// An erase began since the token was captured; stopped before the next
    /// write.
    case staleErase
    /// A slot's commit returned false (for user_settings, the §6.2 zone
    /// write included). The slots before it are durable with their
    /// baselines; this one and the rest are not; no cursor.
    case commitFailed(slot: String)
}

struct SyncApplyOutcome {
    var status: SyncApplyStatus = .applied
    /// The cursor value after the commit; nil when the page did not commit
    /// one (refused, stale, failed, or empty).
    var cursor: Int64?
    var decisions: [SyncBaselineKey: SyncDecisionAction] = [:]
    /// Every (uid, table, id, seq) this page put on the shelf (or found
    /// already there), in order.
    var shelved: [ConflictShelfEntry.DedupeKey] = []
    /// Every (table, id) the page delivered.
    var seen: Set<SyncBaselineKey> = []
    /// Pending-verify elements the page cleared (design §6 "`[]` 的收口"):
    /// the seen keys minus the undecodable ones. A row this build could not
    /// read was never compared and moved no baseline, so its element stays.
    var clearedPendingVerify: Set<SyncBaselineKey> = []
    /// event_types losers the engine must tombstone itself
    /// (`PATCH event_types?id=in.(…)&deleted_at=is.null`): they never
    /// enter the baseline, so the collection diff cannot see them.
    var directTombstones: [String] = []
    /// The slots persisted, in order; one entry per slot per page.
    var persistedSlots: [String] = []
    /// Rows that did not decode: nothing written for them; their table
    /// still counts toward the cursor.
    var undecodable: [SyncBaselineKey] = []
    /// Log / feedback rows under a pre-#26 id, left untouched.
    var legacyIds: [SyncBaselineKey] = []

    /// I1: only an applied page counts as "the last page".
    var countsAsApplied: Bool { status == .applied }
}

@MainActor
enum SyncApplier {
    static func apply(_ page: RemotePage, to store: EventStore, context: SyncApplyContext) -> SyncApplyOutcome {
        PageApplication(store: store, context: context, page: page).run()
    }
}

// MARK: - One page

@MainActor
private final class PageApplication {
    private enum Abort: Error {
        case stale
        case shelf
        /// A write before pass 1 (the §6.2 zone) did not land.
        case commit(SyncApplySlot)
    }

    private struct Row {
        let feed: SyncFeedRow
        let table: String
        let id: String
        let tombstone: Bool

        var key: SyncBaselineKey { SyncBaselineKey(table: table, id: id) }
        var seq: Int64 { feed.seq }
        var data: [String: Any] { feed.data }
    }

    let store: EventStore
    let context: SyncApplyContext
    let page: RemotePage
    var outcome = SyncApplyOutcome()

    private var engine: SupabaseSyncService { context.engine }
    private var baseline: SyncBaselineStore { engine.baseline }
    private var uid: String { engine.userId }

    private var rows: [Row] = []
    private var touched: Set<SyncApplySlot> = []
    private var appeared: Set<String> = []
    private var pageTombstones: Set<SyncBaselineKey> = []

    // Pass-1 plan.
    private var baselineWrites: [String: [(id: String, write: SyncBaselineWrite)]] = [:]
    private var originRemovals: [String: [String]] = [:]
    private var settingsBaselineWrite: SyncSettingsBaseline?
    private var calendarAdopts: [Event] = []
    private var calendarDeletions: [Event] = []
    private var todoAdopts: [Event] = []
    private var todoRemovals: Set<String> = []
    private var logAdopts: [String: CalendarEventLogRecord] = [:]
    private var logRemovals: Set<String> = []
    private var feedbackAdopts: [String: CalendarEventFeedbackRecord] = [:]
    private var feedbackRemovals: Set<String> = []
    private var listAdopts: [TodoList] = []
    private var listRemovals: Set<String> = []
    private var typeAdopts: [EventTypeTemplate] = []
    private var typeRemovals: Set<String> = []
    private var skillAdopts: [SkillInsight] = []
    private var skillRemovals: Set<String> = []
    private var settingsMerge: (merged: [String: Any], local: [String: Any])?
    private var singletonAdopts: [String: [String: Any]] = [:]

    init(store: EventStore, context: SyncApplyContext, page: RemotePage) {
        self.store = store
        self.context = context
        self.page = page
    }

    func run() -> SyncApplyOutcome {
        let result = apply()
        // I1 is read at flush time (review six): a page that did not land
        // takes the session off head here, before any debounce can fire.
        if !result.countsAsApplied { engine.inboundAtHead = false }
        return result
    }

    private func apply() -> SyncApplyOutcome {
        guard let firstSeq = page.firstSeq, let lastSeq = page.lastSeq else { return outcome }
        guard !uid.isEmpty else { return refuse(.signedOut, firstSeq: firstSeq) }
        classify()
        outcome.seen = Set(rows.map(\.key))

        if let refusal = precheck() {
            return refuse(refusal, firstSeq: firstSeq)
        }

        do {
            try zoneFirst()
            try passOne()
        } catch Abort.shelf {
            return refuse(.shelf, firstSeq: firstSeq)
        } catch Abort.commit(let slot) {
            outcome.status = .commitFailed(slot: slot.rawValue)
            DiagnosticTrail.record("Sync", "sync.apply.refused slot=\(slot.rawValue) seq=\(firstSeq) reason=commit")
            return outcome
        } catch {
            outcome.status = .staleErase
            return outcome
        }

        do {
            try step("pass2")
            passTwo()
            for slot in SyncApplySlot.allCases where touched.contains(slot) {
                try step("persist \(slot.rawValue)")
                outcome.persistedSlots.append(slot.rawValue)
                guard persist(slot) else {
                    outcome.status = .commitFailed(slot: slot.rawValue)
                    DiagnosticTrail.record("Sync", "sync.apply.refused slot=\(slot.rawValue) seq=\(firstSeq) reason=commit")
                    return outcome
                }
                if slot == .calendarEvents {
                    // #145: the records a cascade prunes leave memory only
                    // once the event's own removal is durable.
                    for event in calendarDeletions { store.pruneRecordsInMemoryAfterRemoteDeletion(of: event) }
                }
                try step("baseline \(slot.rawValue)")
                writeBaselines(for: slot)
                baseline.persist()
            }
            if context.commitsCursor {
                try step("cursor")
                engine.cursor.commit(seq: lastSeq, baseline: baseline, touched: appeared)
                outcome.cursor = engine.cursor.value
            } else {
                baseline.persist()
            }
        } catch {
            outcome.status = .staleErase
            return outcome
        }

        outcome.clearedPendingVerify = engine.dropSeenPendingVerify(
            outcome.seen.subtracting(outcome.undecodable), pullIssue: context.pullIssue)
        return outcome
    }

    // MARK: Plumbing

    /// The trace line, then the erase-epoch check that must sit right
    /// before the write it names (design §6.4: no suspension in between).
    private func step(_ name: String) throws {
        context.trace?(name)
        if LocalDataEraseEpoch.isStale(context.eraseToken) { throw Abort.stale }
    }

    private func refuse(_ refusal: SyncApplyRefusal, firstSeq: Int64) -> SyncApplyOutcome {
        outcome.status = .refused(refusal)
        let slot: String
        switch refusal {
        case .frozen(let name): slot = name
        case .shelf: slot = "shelf"
        case .missingStore(let table): slot = table
        case .signedOut: slot = "session"
        }
        DiagnosticTrail.record("Sync", "sync.apply.refused slot=\(slot) seq=\(firstSeq)")
        return outcome
    }

    private func appendShelf(table: String, id: String, seq: Int64, reason: ConflictShelfReason, row: [String: Any]) throws {
        let entry = ConflictShelfEntry(uid: uid, table: table, id: id, seq: seq, reason: reason, row: row)
        context.trace?("shelf \(table) \(id) \(reason.rawValue)")
        guard context.shelf.append(entry, eraseToken: context.eraseToken) else {
            throw LocalDataEraseEpoch.isStale(context.eraseToken) ? Abort.stale : Abort.shelf
        }
        outcome.shelved.append(entry.dedupeKey)
    }

    private func planBaseline(_ write: SyncBaselineWrite, table: String, id: String) {
        guard write != .keep else { return }
        baselineWrites[table, default: []].append((id, write))
    }

    /// The §6 table's `(h_in, seq)` write, carrying the incoming row's
    /// version id and clearing a catch-up marker (design §6.6: the entry
    /// returns to an ordinary one once reconciled).
    private func stamped(_ write: SyncBaselineWrite, _ row: Row) -> SyncBaselineWrite {
        guard case .write(var entry) = write else { return write }
        entry.vid = row.data["version_id"] as? String
        entry.stale = false
        return .write(entry)
    }

    /// Rows that read clean again drop their origin (design §6.6 来源快进:
    /// kept "until the row is clean again"); a conflict keeps it.
    private func planOriginRemoval(_ action: SyncDecisionAction, table: String, id: String) {
        switch action {
        case .same, .echo, .adopt, .tombstone:
            originRemovals[table, default: []].append(id)
        case .skip, .conflict:
            break
        }
    }

    // MARK: §6.6 pre-rules on a stale entry

    /// Rules 1 and 2 for a live incoming row meeting a stale entry with a
    /// local row present; nil hands the row to the §6 table (with the
    /// entry's seq hidden, see `baseForTable`). Returns the decision in
    /// the §6 vocabulary plus what to shelve.
    private func catchUpDecision(_ row: Row, localHash: String?, base: SyncBaselineEntry?, incomingHash: String) -> SyncCatchUpDecision? {
        guard let catchUp = context.catchUp, let base, base.stale, !row.tombstone, let localHash else { return nil }
        return SyncCatchUp.decide(
            incomingHash: incomingHash,
            incomingSeq: row.seq,
            incomingVid: row.data["version_id"] as? String,
            localHash: localHash,
            base: base,
            origin: baseline.origin(table: row.table, id: row.id),
            ancestorOfOrigin: catchUp.isAncestor(row.key)
        )
    }

    /// The entry the §6 table sees: a stale entry with its seq hidden, so
    /// the skip row (`in_seq ≤ base.seq`) never fires on a restored row
    /// whose seq went back (the X5 mutant); any other entry as it is.
    private func baseForTable(_ base: SyncBaselineEntry?) -> SyncBaselineEntry? {
        guard let base, base.stale else { return base }
        return SyncBaselineEntry(hash: base.hash, seq: nil, vid: base.vid, stale: true)
    }

    /// The catch-up shelf line for the local copy (rule 1 / 2's loser).
    private func shelveCatchUp(_ row: Row, local: [String: Any], base: SyncBaselineEntry, decision: SyncCatchUpDecision) throws {
        let entry = ConflictShelfEntry(
            uid: uid, table: row.table, id: row.id, seq: row.seq, reason: .catchup, row: local,
            against: .init(seq: row.seq, vid: row.data["version_id"] as? String),
            localVid: decision.localClean ? base.vid : nil,
            localSeq: base.seq,
            localClean: decision.localClean,
            catchup: true,
            epoch: context.catchUp?.epoch
        )
        context.trace?("shelf \(row.table) \(row.id) catchup")
        guard context.shelf.append(entry, eraseToken: context.eraseToken) else {
            throw LocalDataEraseEpoch.isStale(context.eraseToken) ? Abort.stale : Abort.shelf
        }
        outcome.shelved.append(entry.dedupeKey)
        DiagnosticTrail.record("Sync", "sync.catchup.shelved table=\(row.table) id=\(row.id) seq=\(row.seq)")
    }

    private func noteConflict(_ row: Row) {
        DiagnosticTrail.record("Sync", "sync.conflict table=\(row.table) id=\(row.id) seq=\(row.seq)")
    }

    private func inFlightHash(_ key: SyncBaselineKey) -> String? {
        if case .rowHash(let hash)? = context.inFlight(key) { return hash }
        return nil
    }

    // MARK: Hashes, in the outbound projection

    private func eventHash(_ event: Event, kind: String) -> String {
        SupabaseSyncService.rowHash(SupabaseSyncService.eventRowHashableFields(event, kind: kind, userId: uid))
    }

    private func kind(ofEventsTable table: String) -> String {
        table == "calendar_events" ? "calendar" : "todo"
    }

    private func wireId(_ key: CalendarOccurrenceKey) -> String {
        engine.encodeOccurrenceKey(key)
    }

    // MARK: Local lookups (pre-page)

    private lazy var calendarById: [String: Event] = Dictionary(
        store.rawCalendarEvents.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
    private lazy var todoById: [String: Event] = Dictionary(
        store.events.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
    private lazy var logsByWireId: [String: CalendarEventLogRecord] = Dictionary(
        store.calendarEventLogRecords.map { (wireId($0.id), $0) }, uniquingKeysWith: { first, _ in first })
    private lazy var feedbackByWireId: [String: CalendarEventFeedbackRecord] = Dictionary(
        store.calendarEventFeedbackRecords.map { (wireId($0.id), $0) }, uniquingKeysWith: { first, _ in first })
    private lazy var listsById: [String: TodoList] = Dictionary(
        store.todoLists.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
    private lazy var typesById: [String: EventTypeTemplate] = Dictionary(
        (context.eventTypeStore?.templates ?? []).map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
    private lazy var skillsById: [String: SkillInsight] = Dictionary(
        (context.skillStore?.insights ?? []).map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })

    // MARK: 0. Classify and precheck

    private func classify() {
        var byKey: [SyncBaselineKey: Int] = [:]
        for feed in page.rows {
            guard let row = classify(feed) else { continue }
            if isLegacyRecordId(row) {
                // A log / feedback row under its pre-#26 date-bearing id.
                // The record's identity is its decoded key (design §6), and
                // the current-format id of that key is the row this build
                // reads, writes and baselines; the legacy row is a second,
                // older server row for the same record. Folding it into the
                // key would let its content (or its tombstone, the re-key
                // cleanup) overwrite or delete the current record, and keying
                // it by its own id would put a duplicate record in the array.
                // So it changes nothing: no memory, no baseline, no shelf.
                appeared.insert(row.table)
                outcome.legacyIds.append(row.key)
                DiagnosticTrail.record("Sync", "sync.apply.legacy_id table=\(row.table) id=\(row.id) seq=\(row.seq)")
                continue
            }
            // The feed carries a row once per page (its current version);
            // should one repeat, the later seq is the one to apply.
            if let index = byKey[row.key] {
                if rows[index].seq < row.seq { rows[index] = row }
                continue
            }
            byKey[row.key] = rows.count
            rows.append(row)
        }
        for row in rows {
            appeared.insert(row.table)
            if row.tombstone { pageTombstones.insert(row.key) }
            if let slot = SyncApplySlot(baselineTable: row.table) { touched.insert(slot) }
        }
    }

    private func classify(_ feed: SyncFeedRow) -> Row? {
        let tombstone = SupabaseSyncService.isTombstoned(feed.data)
        switch feed.table {
        case "events":
            guard let raw = feed.data["id"] as? String else { return nil }
            let id = SyncBaselineKey.localId(raw)
            let label: String
            if let kind = feed.data["kind"] as? String {
                label = SyncBaselineStore.table(forFeedTable: "events", kind: kind)
            } else {
                let known = calendarById[id] != nil || baseline.entry(table: "calendar_events", id: id) != nil
                label = known ? "calendar_events" : "events"
            }
            return Row(feed: feed, table: label, id: id, tombstone: tombstone)
        case "event_logs", "event_feedback":
            guard let raw = feed.data["id"] as? String else { return nil }
            return Row(feed: feed, table: feed.table, id: raw, tombstone: tombstone)
        case "todo_lists", "event_types", "skill_insights":
            guard let raw = feed.data["id"] as? String else { return nil }
            return Row(feed: feed, table: feed.table, id: SyncBaselineKey.localId(raw), tombstone: tombstone)
        case SyncBaselineStore.settingsTable, "agent_preferences", "agent_conversations":
            return Row(feed: feed, table: feed.table, id: uid, tombstone: tombstone)
        default:
            return nil
        }
    }

    private func isLegacyRecordId(_ row: Row) -> Bool {
        (row.table == "event_logs" || row.table == "event_feedback")
            && SupabaseSyncService.isLegacyOccurrenceKeyId(row.id)
    }

    /// §6.1: a frozen slot's array is empty or stale, so comparing against
    /// it would read every row as new and every local row as deleted. The
    /// cascades also read the record slots, and the zone rule reads them
    /// together with the calendar (§6.2).
    private func precheck() -> SyncApplyRefusal? {
        var checked = touched
        if rows.contains(where: { $0.table == "calendar_events" && $0.tombstone }) {
            checked.formUnion([.calendarEventLogRecords, .calendarEventFeedbackRecords])
        }
        if rows.contains(where: { $0.table == SyncBaselineStore.settingsTable }) {
            checked.formUnion([.calendarEvents, .calendarEventLogRecords, .calendarEventFeedbackRecords])
        }
        for slot in SyncApplySlot.allCases where checked.contains(slot) {
            switch slot {
            case .calendarEvents, .events, .calendarEventLogRecords, .calendarEventFeedbackRecords, .todoLists:
                if let storageSlot = slot.storageSlot, store.isSlotFrozen(storageSlot) {
                    return .frozen(slot: slot.rawValue)
                }
            case .eventTypes:
                guard let types = context.eventTypeStore else { return .missingStore(table: slot.rawValue) }
                if types.areTemplatesFrozen { return .frozen(slot: slot.rawValue) }
            case .skillInsights:
                if context.skillStore == nil { return .missingStore(table: slot.rawValue) }
            case .userSettings:
                if SyncedSettings.hasUnreadableBridgedOwner(engine.defaults) { return .frozen(slot: slot.rawValue) }
            case .agentPreferences, .agentConversations:
                guard let adapter = context.singletons[slot.rawValue] else { return .missingStore(table: slot.rawValue) }
                if adapter.isFrozen { return .frozen(slot: slot.rawValue) }
            }
        }
        return nil
    }

    // MARK: 1. Zone first (§6.2)

    private func zoneFirst() throws {
        guard let row = rows.first(where: { $0.table == SyncBaselineStore.settingsTable && !$0.tombstone }) else { return }
        if !baseline.settingsStale, let seq = baseline.settings?.seq, row.seq <= seq { return }
        let blob = row.data["settings"] as? [String: Any] ?? [:]
        guard let remote = blob[SyncSettingsMerge.zoneKey] as? String else { return }
        let zones = OccurrenceKeyMetadataStore.forDefaults(engine.defaults)
        let local = zones.establishedIdentifier
        guard remote != local else { return }
        // Adopt only while nothing local is anchored in the local zone: a
        // single-event record's identity carries no day key, a series
        // occurrence's does.
        let anchored = store.calendarEventLogRecords.contains { $0.baseSeriesEventID != nil }
            || store.calendarEventFeedbackRecords.contains { $0.baseSeriesEventID != nil }
        if anchored {
            if engine.zoneConflictsLogged.insert(remote).inserted {
                DiagnosticTrail.record("Sync", "sync.conflict key=zone local=\(local ?? "none") remote=\(remote)")
            }
            context.trace?("zone kept")
            return
        }
        // A zone this system does not know is never written (the store
        // refuses it), so there is nothing to adopt and nothing that failed.
        guard TimeZone(identifier: remote) != nil else {
            DiagnosticTrail.record("Sync", "sync.apply.zone_unknown zone=\(remote)")
            return
        }
        try step("zone adopt")
        // The file still holding the old zone is a failed commit of
        // user_settings: no zone_adopted line, and no settings baseline may
        // name a seq past this row (see testAZoneWriteThatDidNotLandStopsThePage).
        guard zones.applyRestoredIdentifier(remote) else { throw Abort.commit(.userSettings) }
        DiagnosticTrail.record("Sync", "sync.apply.zone_adopted zone=\(remote) previous=\(local ?? "none")")
    }

    // MARK: 2. Pass 1 — decisions and shelf appends

    private func passOne() throws {
        let typeCandidates = eventTypeCandidates()
        for row in rows {
            switch row.table {
            case "calendar_events", "events":
                try decideEvent(row)
            case "event_logs":
                try decideLog(row)
            case "event_feedback":
                try decideFeedback(row)
            case "todo_lists":
                try decideIdRow(row, local: listsById[row.id],
                                hash: { SupabaseSyncService.rowHash(self.engine.todoListToRow($0)) },
                                project: { self.engine.todoListToRow($0) },
                                decode: SupabaseSyncService.rowToTodoList,
                                adopt: { self.listAdopts.append($0) },
                                remove: { _ in self.listRemovals.insert(row.id) })
            case "event_types":
                try decideEventType(row, candidates: typeCandidates)
            case "skill_insights":
                try decideIdRow(row, local: skillsById[row.id],
                                hash: { SupabaseSyncService.rowHash(self.engine.skillToRow($0)) },
                                project: { self.engine.skillToRow($0) },
                                decode: SupabaseSyncService.rowToSkill,
                                adopt: { self.skillAdopts.append($0) },
                                remove: { _ in self.skillRemovals.insert(row.id) })
            case SyncBaselineStore.settingsTable:
                try decideSettings(row)
            case "agent_preferences", "agent_conversations":
                try decideSingleton(row)
            default:
                break
            }
        }
    }

    /// The §6 table for one id-table row. Returns the decision, nil when
    /// the live row does not decode (no write of any kind for it).
    @discardableResult
    private func decideIdRow<Model>(
        _ row: Row,
        local: Model?,
        hash: (Model) -> String,
        project: (Model) -> [String: Any],
        decode: ([String: Any]) -> Model?,
        adopt: (Model) -> Void,
        remove: (Model?) -> Void
    ) throws -> SyncDecision? {
        var incoming: Model?
        var incomingHash = ""
        if !row.tombstone {
            context.trace?("decode \(row.table) \(row.id)")
            guard let decoded = decode(row.data) else {
                outcome.undecodable.append(row.key)
                DiagnosticTrail.record("Sync", "sync.apply.undecodable table=\(row.table) id=\(row.id) seq=\(row.seq)")
                return nil
            }
            incoming = decoded
            incomingHash = hash(decoded)
        }
        let base = baseline.entry(table: row.table, id: row.id)
        let localHash = local.map(hash)
        if let pre = catchUpDecision(row, localHash: localHash, base: base, incomingHash: incomingHash), let base {
            switch pre.action {
            case .same:
                outcome.decisions[row.key] = .same
                planOriginRemoval(.same, table: row.table, id: row.id)
            case .shelveAndAdopt:
                if let local { try shelveCatchUp(row, local: project(local), base: base, decision: pre) }
                outcome.decisions[row.key] = .adopt
                planOriginRemoval(.adopt, table: row.table, id: row.id)
                if let incoming { adopt(incoming) }
            case .keepOrigin:
                outcome.decisions[row.key] = .conflict
                DiagnosticTrail.record("Sync", "sync.catchup.kept_origin table=\(row.table) id=\(row.id) seq=\(row.seq)")
            }
            planBaseline(.write(pre.entry), table: row.table, id: row.id)
            return nil
        }
        let decision = SyncDecision.decide(
            tombstone: row.tombstone,
            incomingHash: incomingHash,
            localHash: localHash,
            base: baseForTable(base),
            incomingSeq: row.seq,
            inFlightSentHash: inFlightHash(row.key)
        )
        outcome.decisions[row.key] = decision.action
        if decision.shelfLocal, let local {
            try appendShelf(table: row.table, id: row.id, seq: row.seq, reason: .tombstoneDirtyLocal, row: project(local))
        }
        if decision.shelfRemote {
            try appendShelf(table: row.table, id: row.id, seq: row.seq,
                            reason: local == nil ? .pendingDelete : .conflict, row: row.data)
            noteConflict(row)
        }
        planBaseline(stamped(decision.baseline, row), table: row.table, id: row.id)
        planOriginRemoval(decision.action, table: row.table, id: row.id)
        switch decision.localEffect {
        case .keep: break
        case .replaceWithIncoming: if let incoming { adopt(incoming) }
        case .remove: remove(local)
        }
        return decision
    }

    private func decideEvent(_ row: Row) throws {
        let isCalendar = row.table == "calendar_events"
        let kind = kind(ofEventsTable: row.table)
        let local = isCalendar ? calendarById[row.id] : todoById[row.id]
        let decision = try decideIdRow(
            row, local: local,
            hash: { self.eventHash($0, kind: kind) },
            project: { self.engine.eventToRow($0, kind: kind) },
            decode: SupabaseSyncService.rowToEvent,
            adopt: { event in
                if isCalendar { self.calendarAdopts.append(event) } else { self.todoAdopts.append(event) }
            },
            remove: { local in
                guard let local else { return }
                if isCalendar { self.calendarDeletions.append(local) } else { self.todoRemovals.insert(row.id) }
            }
        )
        guard isCalendar, decision?.action == .tombstone, let local else { return }
        touched.formUnion([.calendarEventLogRecords, .calendarEventFeedbackRecords])
        try shelveCascade(of: local, parentSeq: row.seq)
    }

    /// Fresh-eyes B2: the cascade prunes every log / feedback record of the
    /// event without looking at whether it is dirty. Each one that is dirty
    /// against its baseline (a `?` included) or has none goes to the shelf
    /// now, with the parent tombstone's seq; one whose own tombstone is in
    /// this page is left to that row. The same holds for the exception
    /// instances a series tombstone removes with it.
    private func shelveCascade(of event: Event, parentSeq: Int64) throws {
        let logs = store.calendarEventLogRecords
        let feedback = store.calendarEventFeedbackRecords
        let survivingLogs: [CalendarEventLogRecord]?
        let survivingFeedback: [CalendarEventFeedbackRecord]?
        if event.isRecurringSeries {
            let day = Calendar.current.startOfDay(for: event.primaryTimeRange?.start ?? Date())
            survivingLogs = EventStore.recordsSurviving(logs, afterDeletingSeries: event, occurrenceDate: day, scope: .all)
            survivingFeedback = EventStore.recordsSurviving(feedback, afterDeletingSeries: event, occurrenceDate: day, scope: .all)
        } else {
            survivingLogs = EventStore.recordsSurviving(logs, afterDeleting: event)
            survivingFeedback = EventStore.recordsSurviving(feedback, afterDeleting: event)
        }
        if let survivingLogs {
            let kept = Set(survivingLogs.map { wireId($0.id) })
            for record in logs where !kept.contains(wireId(record.id)) {
                let row = engine.logToRow(record)
                try shelveCascadeChild(table: "event_logs", id: wireId(record.id),
                                       hash: SupabaseSyncService.rowHash(row), row: row, parentSeq: parentSeq)
            }
        }
        if let survivingFeedback {
            let kept = Set(survivingFeedback.map { wireId($0.id) })
            for record in feedback where !kept.contains(wireId(record.id)) {
                let row = engine.feedbackToRow(record)
                try shelveCascadeChild(table: "event_feedback", id: wireId(record.id),
                                       hash: SupabaseSyncService.rowHash(row), row: row, parentSeq: parentSeq)
            }
        }
        if event.isRecurringSeries {
            for instance in store.rawCalendarEvents where instance.recurrenceParentId == event.id {
                let row = engine.eventToRow(instance, kind: "calendar")
                try shelveCascadeChild(table: "calendar_events", id: instance.id.uuidString,
                                       hash: SupabaseSyncService.rowHash(row), row: row, parentSeq: parentSeq)
            }
        }
    }

    private func shelveCascadeChild(table: String, id: String, hash: String, row: [String: Any], parentSeq: Int64) throws {
        let key = SyncBaselineKey(table: table, id: id)
        guard !pageTombstones.contains(key) else { return }
        if let base = baseline.entry(table: table, id: id), !base.isUnknown, base.hash == hash { return }
        try appendShelf(table: table, id: id, seq: parentSeq, reason: .cascade, row: row)
    }

    private func decideLog(_ row: Row) throws {
        try decideIdRow(row, local: logsByWireId[row.id],
                        hash: { SupabaseSyncService.rowHash(self.engine.logToRow($0)) },
                        project: { self.engine.logToRow($0) },
                        decode: SupabaseSyncService.rowToLog,
                        adopt: { self.logAdopts[row.id] = $0 },
                        remove: { _ in self.logRemovals.insert(row.id) })
    }

    private func decideFeedback(_ row: Row) throws {
        try decideIdRow(row, local: feedbackByWireId[row.id],
                        hash: { SupabaseSyncService.rowHash(self.engine.feedbackToRow($0)) },
                        project: { self.engine.feedbackToRow($0) },
                        decode: SupabaseSyncService.rowToFeedback,
                        adopt: { self.feedbackAdopts[row.id] = $0 },
                        remove: { _ in self.feedbackRemovals.insert(row.id) })
    }

    // MARK: event_types

    /// Who may win a title (fresh-eyes minor): the page-before local live
    /// rows and this page's live rows — a page row replacing the local row
    /// of the same id — minus every UUID this page tombstones. Computed once,
    /// before anything in the page is applied.
    private func eventTypeCandidates() -> [SyncEventTypeWinners.Namesake] {
        let tombstoned = Set(rows.filter { $0.table == "event_types" && $0.tombstone }.map { $0.id.lowercased() })
        var byId: [String: SyncEventTypeWinners.Namesake] = [:]
        for template in context.eventTypeStore?.templates ?? [] {
            byId[template.id.uuidString.lowercased()] = .init(id: template.id.uuidString, title: template.title)
        }
        for row in rows where row.table == "event_types" && !row.tombstone {
            guard let title = row.data["title"] as? String else { continue }
            byId[row.id.lowercased()] = .init(id: row.id, title: title)
        }
        return byId.filter { !tombstoned.contains($0.key) }.values.sorted { $0.id < $1.id }
    }

    private func decideEventType(_ row: Row, candidates: [SyncEventTypeWinners.Namesake]) throws {
        if !row.tombstone, let title = row.data["title"] as? String {
            let others = candidates.filter { !SyncEventTypeWinners.sameId($0.id, row.id) }
            let resolution = SyncEventTypeWinners.resolve(
                localLive: others, incoming: .init(id: row.id, title: title), incomingIsLive: true)
            for loser in resolution.removeLocally {
                let id = SyncBaselineKey.localId(loser)
                if typesById[id] != nil { typeRemovals.insert(id) }
            }
            guard resolution.incomingEntersTable else {
                // A loser: never inserted, never in the baseline; the engine
                // tombstones it directly.
                outcome.directTombstones.append(row.id)
                outcome.decisions[row.key] = .skip
                context.trace?("event_types loser \(row.id)")
                return
            }
        }
        try decideIdRow(row, local: typesById[row.id],
                        hash: { SupabaseSyncService.rowHash(self.engine.eventTypeToRow($0)) },
                        project: { self.engine.eventTypeToRow($0) },
                        decode: SupabaseSyncService.rowToEventType,
                        adopt: { self.typeAdopts.append($0) },
                        remove: { _ in self.typeRemovals.insert(row.id) })
    }

    // MARK: user_settings

    private func decideSettings(_ row: Row) throws {
        let defaults = engine.defaults
        let local = SyncedSettings.currentSnapshot(defaults)
        var base = baseline.settings
        if baseline.settingsStale, case .versioned(_, let keys, let zone)? = base {
            // A stale settings row (design §6.6): the per-key merge runs as
            // usual — it never drops a side — but the old seq must not make
            // the restored row read as already seen.
            base = .versioned(seq: nil, keys: keys, zone: zone)
        }
        if row.tombstone {
            let localKeys = SupabaseSyncService.settingsKeyHashes(
                SupabaseSyncService.settingsBlobForUpload(local: local, serverZone: nil))
            let result = SyncSingletonTombstone.applySettings(localKeys: localKeys, base: base, incomingSeq: row.seq)
            if result.skipped {
                outcome.decisions[row.key] = .skip
                return
            }
            outcome.decisions[row.key] = .tombstone
            settingsBaselineWrite = result.baseline
            if let line = result.trailLine { DiagnosticTrail.record("Sync", line) }
            return
        }
        let remote = row.data["settings"] as? [String: Any] ?? [:]
        var legacy: SyncSettingsMerge.LegacyRowHashes?
        if case .legacy = base { legacy = engine.legacySettingsRowHashes(local: local, remote: remote) }
        let merge = SyncSettingsMerge.merge(local: local, remote: remote, remoteSeq: row.seq,
                                            baseline: base, legacyRowHashes: legacy)
        if merge.skipped {
            outcome.decisions[row.key] = .skip
            return
        }
        // The in-flight echo, per key: a remote value equal to what our
        // outstanding write sent for that key is our own write coming back.
        var shelved = merge.shelved
        if case .settingsKeys(let sent)? = context.inFlight(row.key) {
            shelved.removeAll { item in
                item.side == .remote
                    && item.value.map { SyncSettingsMerge.outboundKeyHash(item.key, $0) } == sent[item.key]
            }
        }
        if !shelved.isEmpty {
            let shelfRow: [String: Any] = ["keys": shelved.sorted { $0.key < $1.key }.map(\.shelfObject)]
            try appendShelf(table: row.table, id: row.id, seq: row.seq, reason: .settingsKeys, row: shelfRow)
            DiagnosticTrail.record("Sync", "sync.conflict table=\(row.table) keys=\(shelved.map(\.key).sorted().joined(separator: ",")) seq=\(row.seq)")
        }
        outcome.decisions[row.key] = shelved.isEmpty ? .adopt : .conflict
        settingsMerge = (merge.merged, local)
        settingsBaselineWrite = merge.baseline
    }

    // MARK: agent_preferences / agent_conversations

    private func decideSingleton(_ row: Row) throws {
        guard let adapter = context.singletons[row.table] else { return }
        let base = baseline.entry(table: row.table, id: uid)
        let localHash = SupabaseSyncService.rowHash(adapter.localRow())
        if row.tombstone {
            let result = SyncSingletonTombstone.applyRow(table: row.table, localHash: localHash,
                                                         base: base, incomingSeq: row.seq)
            outcome.decisions[row.key] = result.skipped ? .skip : .tombstone
            if !result.skipped, let entry = result.baseline {
                planBaseline(.write(entry), table: row.table, id: uid)
            }
            if let line = result.trailLine { DiagnosticTrail.record("Sync", line) }
            return
        }
        guard let projected = adapter.projected(row.data) else {
            outcome.undecodable.append(row.key)
            DiagnosticTrail.record("Sync", "sync.apply.undecodable table=\(row.table) id=\(row.id) seq=\(row.seq)")
            return
        }
        let incomingHash = SupabaseSyncService.rowHash(projected)
        if let pre = catchUpDecision(row, localHash: localHash, base: base, incomingHash: incomingHash), let base {
            switch pre.action {
            case .same:
                outcome.decisions[row.key] = .same
                planOriginRemoval(.same, table: row.table, id: uid)
            case .shelveAndAdopt:
                try shelveCatchUp(row, local: adapter.localRow(), base: base, decision: pre)
                outcome.decisions[row.key] = .adopt
                planOriginRemoval(.adopt, table: row.table, id: uid)
                singletonAdopts[row.table] = row.data
            case .keepOrigin:
                outcome.decisions[row.key] = .conflict
                DiagnosticTrail.record("Sync", "sync.catchup.kept_origin table=\(row.table) id=\(row.id) seq=\(row.seq)")
            }
            planBaseline(.write(pre.entry), table: row.table, id: uid)
            return
        }
        let decision = SyncDecision.decide(
            tombstone: false,
            incomingHash: incomingHash,
            localHash: localHash,
            base: baseForTable(base),
            incomingSeq: row.seq,
            inFlightSentHash: inFlightHash(row.key)
        )
        outcome.decisions[row.key] = decision.action
        if decision.shelfRemote {
            try appendShelf(table: row.table, id: row.id, seq: row.seq, reason: .conflict, row: row.data)
            noteConflict(row)
        }
        planBaseline(stamped(decision.baseline, row), table: row.table, id: uid)
        planOriginRemoval(decision.action, table: row.table, id: uid)
        if decision.localEffect == .replaceWithIncoming { singletonAdopts[row.table] = row.data }
    }

    // MARK: 3. Pass 2 — memory

    private func passTwo() {
        store.applyRemoteCalendarRows(adopts: calendarAdopts, deletions: calendarDeletions)
        store.applyRemoteTodoRows(adopts: todoAdopts, removing: todoRemovals)
        store.applyRemoteLogRows(adopts: logAdopts, removing: logRemovals, wireId: wireId)
        store.applyRemoteFeedbackRows(adopts: feedbackAdopts, removing: feedbackRemovals, wireId: wireId)
        store.applyRemoteListRows(adopts: listAdopts, removing: listRemovals)
    }

    // MARK: 4. Persist

    private func persist(_ slot: SyncApplySlot) -> Bool {
        switch slot {
        case .calendarEvents:
            return store.saveCalendarEvents(refreshInterrupts: true)
        case .events:
            return store.save()
        case .calendarEventLogRecords:
            return store.commitLogRecordsNow()
        case .calendarEventFeedbackRecords:
            return store.saveCalendarEventFeedbackRecords()
        case .todoLists:
            return store.saveTodoLists()
        case .eventTypes:
            guard let types = context.eventTypeStore else { return false }
            var next = types.templates.filter { !typeRemovals.contains($0.id.uuidString) }
            for template in typeAdopts {
                if let index = next.firstIndex(where: { $0.id == template.id }) {
                    next[index] = template
                } else {
                    next.append(template)
                }
            }
            guard next != types.templates else { return true }
            return types.catalog.setTemplates(next)
        case .skillInsights:
            guard let skills = context.skillStore else { return false }
            var next = skills.insights.filter { !skillRemovals.contains($0.id.uuidString) }
            for insight in skillAdopts {
                if let index = next.firstIndex(where: { $0.id == insight.id }) {
                    next[index] = insight
                } else {
                    next.append(insight)
                }
            }
            guard next != skills.insights else { return true }
            return skills.replaceInsightsFromSync(next)
        case .userSettings:
            guard let merge = settingsMerge else { return true }
            let result = SyncedSettings.applyMerged(merge.merged, over: merge.local, to: engine.defaults)
            if result.written.contains(where: SyncedSettings.unionKeys.contains) {
                context.skillStore?.adoptSyncedAnalyzedIds()
            }
            return result.landed
        case .agentPreferences, .agentConversations:
            guard let data = singletonAdopts[slot.rawValue] else { return true }
            return context.singletons[slot.rawValue]?.adopt(data) ?? false
        }
    }

    private func writeBaselines(for slot: SyncApplySlot) {
        if slot == .userSettings {
            if let settingsBaselineWrite { baseline.setSettings(settingsBaselineWrite) }
            return
        }
        let table = slot.baselineTable
        for (id, write) in baselineWrites[table] ?? [] {
            switch write {
            case .keep: break
            case .remove:
                baseline.removeEntry(table: table, id: id)
                baseline.removeOrigin(table: table, id: id)
            case .write(let entry): baseline.setEntry(entry, table: table, id: id)
            }
        }
        for id in originRemovals[table] ?? [] {
            baseline.removeOrigin(table: table, id: id)
        }
    }
}

// MARK: - Production singleton adapters

/// agent_preferences: rules + decision history + the token-inference state,
/// one row (`SupabaseSyncService.agentPreferencesRow`).
@MainActor
final class AgentPreferencesSyncAdapter: SyncSingletonAdapter {
    let engine: SupabaseSyncService
    let store: AgentPreferenceStore

    init(engine: SupabaseSyncService, store: AgentPreferenceStore) {
        self.engine = engine
        self.store = store
    }

    var isFrozen: Bool { false }

    func localRow() -> [String: Any] { engine.agentPreferencesToRow(store) }

    /// The five slices of an incoming row. A column that is missing or null
    /// is empty (the pusher sends null for an empty token slice); a column
    /// that is present but does not decode (a newer build's field) makes the
    /// whole row undecodable, so it is never adopted as empty arrays over
    /// the local ones (restore keeps the local slice in that case too).
    private struct Slices {
        let rules: [AgentPreferenceRule]
        let decisions: [AgentDecisionRecord]
        let dynamic: [TokenDynamicHypothesisRecord]
        let meta: [TokenMetaHypothesisRecord]
        let projections: [TokenOccurrenceProjectionRecord]
    }

    private static func slice<T: Decodable>(_ value: Any?) -> [T]? {
        guard let value, !(value is NSNull) else { return [] }
        return SupabaseSyncService.decodeJSONArray(value)
    }

    private static func slices(_ incoming: [String: Any]) -> Slices? {
        guard let rules: [AgentPreferenceRule] = slice(incoming["rules"]),
              let decisions: [AgentDecisionRecord] = slice(incoming["decision_history"]),
              let dynamic: [TokenDynamicHypothesisRecord] = slice(incoming["token_dynamic_hypotheses"]),
              let meta: [TokenMetaHypothesisRecord] = slice(incoming["token_meta_hypotheses"]),
              let projections: [TokenOccurrenceProjectionRecord] = slice(incoming["token_projections"])
        else { return nil }
        return Slices(rules: rules, decisions: decisions, dynamic: dynamic, meta: meta, projections: projections)
    }

    func projected(_ incoming: [String: Any]) -> [String: Any]? {
        guard let s = Self.slices(incoming) else { return nil }
        return engine.agentPreferencesRow(rules: s.rules, decisionHistory: s.decisions,
                                          dynamic: s.dynamic, meta: s.meta, projections: s.projections)
    }

    func adopt(_ incoming: [String: Any]) -> Bool {
        guard let s = Self.slices(incoming) else { return false }
        let preferencesLanded = store.applyRestore(
            rules: s.rules, decisionHistory: s.decisions, strategy: .cloudOverwritesLocal, resolution: .keepCloud)
        let tokensLanded = TokenInferenceRepository.shared.applyRestore(
            dynamicHypotheses: s.dynamic, metaHypotheses: s.meta, projections: s.projections,
            strategy: .cloudOverwritesLocal, resolution: .keepCloud)
        return preferencesLanded && tokensLanded
    }
}

/// agent_conversations: the chat-history blob (`AgentConversationRepository`).
@MainActor
final class AgentConversationsSyncAdapter: SyncSingletonAdapter {
    let engine: SupabaseSyncService
    let repository: AgentConversationRepository

    /// `repository` nil is the shared one.
    init(engine: SupabaseSyncService, repository: AgentConversationRepository? = nil) {
        self.engine = engine
        self.repository = repository ?? .shared
    }

    var isFrozen: Bool { repository.isFrozen }

    func localRow() -> [String: Any] { engine.agentConversationsToRow(from: repository) }

    private func conversations(_ incoming: [String: Any]) -> Any {
        guard let value = incoming["conversations"], !(value is NSNull) else { return [Any]() }
        return value
    }

    func projected(_ incoming: [String: Any]) -> [String: Any]? {
        engine.agentConversationsRow(conversations: conversations(incoming))
    }

    func adopt(_ incoming: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: conversations(incoming)) else { return false }
        do {
            return try repository.applyRestore(blobData: data)
        } catch {
            return false
        }
    }
}
