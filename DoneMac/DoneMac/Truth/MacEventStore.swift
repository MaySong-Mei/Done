//
//  MacEventStore.swift
//  DoneMac
//
//  The Mac truth store. Deliberately NOT observable — no @Published, no
//  @Observable, no objectWillChange. Views never see this type; surface
//  models register a StoreInterest and receive CommitDelta. That makes
//  #219's four concepts structural rather than disciplinary:
//    1. recipients are the enumerable `observers` array;
//    2. `now` is an explicit parameter on every mutation;
//    3. every commit bumps a slot generation and emits one delta;
//    4. derived presentation values are never READ from storage by any Mac
//       renderer — `colorDepth` is carried as an opaque passenger for
//       synced-row compat with iOS. It gets stamped exactly once, at the
//       feedback seam, when effort flows land (Phase 4/5); until then no
//       Mac mutation touches it.
//
//  Mutation semantics come from shared pure functions (EventZone, Event
//  helpers); the store orchestrates, it does not invent rules.
//

import Foundation

@MainActor
final class MacEventStore {
    private(set) var calendarEvents: [Event] = []
    private(set) var todoLists: [TodoList] = []
    private(set) var revision = StoreRevision()
    private(set) var sidecar = SidecarFile()
    private(set) var frozenSlots: Set<StorageSlot> = []
    private(set) var dominoLastPushEffective: Date?
    /// The sidecar file was unreadable at load. Revision bumping stops for
    /// the run (each bump would restart histories at 1 and poison future
    /// sync dirtiness), and the tripwire records it. Rows keep working.
    private(set) var sidecarFrozen = false
    /// Mutations are refused until load() completes: a pre-load commit
    /// would replace the slot with the empty in-memory array and mint a
    /// stale/nil domino stamp — the exact corruption iOS documents as
    /// must-be-unreachable.
    private(set) var isLoaded = false

    let bill: MacWorkBill
    let persistence: MacPersistence
    private let calendar: Calendar

    private struct Observer {
        let id: UUID
        let interest: StoreInterest
        let handler: (CommitDelta) -> Void
    }
    private var observers: [Observer] = []

    /// Sidecar submissions get their OWN monotonic sequence, decoupled
    /// from slot generations — round-5 BLOCKER: markPushed submitting at
    /// generation+1 made the NEXT edit's sidecar land at the same number
    /// and get dropped as redundant, silently losing its dirty flag
    /// across a relaunch.
    private var sidecarSeq: UInt64 = 0

    private func nextSidecarSeq() -> UInt64 {
        sidecarSeq &+= 1
        return sidecarSeq
    }

    /// Serialized chain of persistence submissions. `flush()` awaits the
    /// chain before draining the actor, so "everything committed so far is
    /// on disk after flush" is a guarantee, not a race.
    private var persistChain: Task<Void, Never>?

    /// Same threshold, same rationale as `EventStore.dominoMinimumPushInterval`:
    /// deferring sub-minute drift to the next call produces the identical end
    /// state (push is computed relative to `last`), so this trades write
    /// frequency against nothing.
    static let dominoMinimumPushInterval: TimeInterval = 60

    /// Seed the shared sample events into an empty store on first launch —
    /// product parity with iOS `EventStore.seedsSampleDataIfEmpty` (the same
    /// reason the phone shows Team Standup / Lunch Run / … on a fresh
    /// install). Off under tests so fixtures stay deterministic.
    private let seedsSampleDataIfEmpty: Bool

    init(
        persistence: MacPersistence,
        bill: MacWorkBill,
        calendar: Calendar,
        seedsSampleDataIfEmpty: Bool = false
    ) {
        self.persistence = persistence
        self.bill = bill
        self.calendar = calendar
        self.seedsSampleDataIfEmpty = seedsSampleDataIfEmpty
    }

    // MARK: - Load

    func load() async {
        let loaded = await persistence.loadAll()
        calendarEvents = loaded.calendarEvents
        todoLists = loaded.todoLists
        dominoLastPushEffective = loaded.dominoStamp
        sidecar = loaded.sidecar
        frozenSlots = Set(loaded.frozenSlots)
        sidecarFrozen = loaded.sidecarWasUnreadable
        if sidecarFrozen {
            bill.bump(.sidecarUnreadableSeen)
        }
        // Continue generation numbering from the persistence watermark, so a
        // store constructed over a live MacPersistence cannot number its
        // first commits below the gate (QA finding 4 / review finding 6).
        for slot in [StorageSlot.calendarEvents, .todoLists] {
            revision[slot] = await persistence.generationWatermark(slot)
        }
        sidecarSeq = await persistence.sidecarWatermark()
        let orphans = sidecar.orphans(against: Set(calendarEvents.map(\.id)))
        if !orphans.isEmpty {
            bill.bump(.sidecarOrphansSeen, by: orphans.count)
        }
        isLoaded = true
        if seedsSampleDataIfEmpty, calendarEvents.isEmpty,
           !frozenSlots.contains(.calendarEvents) {
            seedSampleEvents(now: Date())
        }
    }

    /// Verbatim shape of the iOS sample set (EventStore.seedSampleCalendarEvents)
    /// so a fresh Mac reads identically to a fresh phone; the type strings
    /// resolve to the shared EventTypeCatalog's default colors.
    private func seedSampleEvents(now: Date) {
        let today = calendar.startOfDay(for: now)
        func time(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            (calendar.date(byAdding: .day, value: day, to: today) ?? today)
                .addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
        }
        let samples: [(String, String, Int, Int, Int, Int, Int)] = [
            ("Morning Focus", "Work", 0, 9, 0, 11, 30),
            ("Team Standup", "Work", 0, 11, 30, 12, 0),
            ("Lunch Run", "Exercise", 0, 12, 30, 13, 30),
            ("Design Review", "Work", 0, 14, 0, 15, 30),
            ("Reading", "Study", 0, 20, 0, 21, 30),
            ("Piano Practice", "Hobby", 1, 8, 0, 9, 0),
            ("Project Sprint", "Work", 1, 10, 0, 16, 0),
            ("Grocery Shopping", "Errand", 1, 17, 0, 18, 0),
            ("Yoga", "Exercise", -1, 7, 0, 8, 0),
            ("Coffee Chat", "Social", -1, 10, 30, 11, 30),
        ]
        for (title, type, day, sh, sm, eh, em) in samples {
            var event = Event(
                id: UUID(), title: title,
                timeRanges: [.init(start: time(day, sh, sm), end: time(day, eh, em))],
                kind: .event
            )
            event.type = type
            addCalendarEvent(event, now: now)
        }
    }

    /// Refused + counted: the tripwire (expected 0) is the loud signal.
    /// No assertionFailure — negative tests must be able to exercise this.
    private func requireLoaded(_ function: StaticString = #function) -> Bool {
        if isLoaded { return true }
        bill.bump(.preLoadMutationRefused)
        return false
    }

    // MARK: - Observation

    @discardableResult
    func addObserver(interest: StoreInterest, handler: @escaping (CommitDelta) -> Void) -> UUID {
        let id = UUID()
        observers.append(Observer(id: id, interest: interest, handler: handler))
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.removeAll { $0.id == id }
    }

    var observerCount: Int { observers.count }

    // MARK: - Mutations (calendar events)

    /// A recurring series renders on every pattern day, not its seed days,
    /// so any commit touching one must claim EVERYTHING — an underclaimed
    /// delta leaves ghost blocks in day caches (round-2 blocker, review #2
    /// / QA3 F2). Bulk (nil) is the documented honest fallback.
    private func affectedKeys(touching events: [Event?]) -> Set<DayKey>? {
        var acc = Set<DayKey>()
        for event in events {
            guard let event else { continue }
            if event.isRecurringSeries { return nil }
            guard let keys = DayKey.keys(of: event, calendar: calendar) else { return nil }
            acc.formUnion(keys)
        }
        return acc
    }

    func addCalendarEvent(_ event: Event, now: Date) {
        guard requireLoaded() else { return }
        guard !frozenSlots.contains(.calendarEvents) else { return }
        var new = calendarEvents
        new.append(event)
        commitCalendarEvents(
            new,
            changedIDs: [event.id],
            affectedDayKeys: affectedKeys(touching: [event]),
            now: now
        )
    }

    /// Replace one event wholesale. The caller built the new value through
    /// shared edit helpers; the store's job is delta + stamping, not rules.
    func replaceCalendarEvent(_ event: Event, now: Date) {
        guard requireLoaded() else { return }
        guard !frozenSlots.contains(.calendarEvents) else { return }
        guard let index = calendarEvents.firstIndex(where: { $0.id == event.id }) else { return }
        let old = calendarEvents[index]
        guard event != old else { return }
        var new = calendarEvents
        // The write-side rule's SECOND half (QA round-3 F2): a range write
        // onto a detached exception instance must rebase the mint-frame
        // mirror in the same commit, or renderTimeRanges re-projects the
        // fresh instants a day off through the stale mirror (gh#127 shape).
        new[index] = Event.rebasedExceptionInstanceAfterRangeWrite(
            event, previous: old, calendar: calendar
        )
        commitCalendarEvents(
            new,
            changedIDs: [event.id],
            affectedDayKeys: affectedKeys(touching: [old, new[index]]),
            now: now
        )
    }

    func removeCalendarEvent(id: UUID, now: Date) {
        guard requireLoaded() else { return }
        guard !frozenSlots.contains(.calendarEvents) else { return }
        guard let index = calendarEvents.firstIndex(where: { $0.id == id }) else { return }
        let old = calendarEvents[index]
        var new = calendarEvents
        new.remove(at: index)
        // A row the server knows must not silently resurrect on the next
        // pull (round-5 review #7 / QA F5): tombstone it so the pull skips
        // re-adoption and the engine pushes the delete.
        let serverKnowsIt = sidecar.records[id]?.lastPushedRevision != nil
            || sidecar.serverStamps[id] != nil
        sidecar.remove([id])
        if serverKnowsIt && !sidecarFrozen {
            sidecar.tombstones.insert(id)
        }
        commitCalendarEvents(
            new,
            changedIDs: [id],
            affectedDayKeys: affectedKeys(touching: [old]),
            now: now,
            bumpSidecar: false
        )
    }

    // MARK: - Recurrence

    /// Mac port of `EventStore.applyRecurringEdit` over the SHARED pure engine
    /// `Event.applyEdit` — the this/following/all orchestration, minus the
    /// reindexing iOS carries: logs/feedback live in separate record slots the
    /// Mac doesn't have, and interrupts are dormant on Mac (never minted here).
    /// KNOWN DEFERRAL (review #3): a SYNCED iOS row can carry an
    /// `interruptRelation` field pointing at a series this splits; iOS
    /// re-anchors those across the split, the Mac does not, so a synced
    /// interrupt child on a day ≥ split stays parented to the capped old
    /// series until interrupts are wired on Mac. The `.following` split still lands
    /// as ONE commit: capping the old series, minting the new one, carrying its
    /// on-or-after-split exception keys, and re-parenting materialized
    /// exception instances all ride a single `commitCalendarEvents` — a kill
    /// between them must never leave two live series over the same days
    /// (the invariant iOS's issue #145-B single-commit protects).
    ///
    /// `occurrenceDate` is the day the edit was invoked on (the grabbed
    /// occurrence). `edit` mutates the copy the resolved scope hands it: the
    /// whole series (`.all`), the materialized one-day exception (`.single`),
    /// or the split-off series (`.following`).
    /// Returns the id the UI should now select: the materialized exception
    /// (`.single`), the split-off series (`.following`), or the series itself
    /// (`.all`) — so a per-occurrence edit re-targets the row it just minted
    /// instead of the template. nil if nothing applied.
    @discardableResult
    func applyRecurringEdit(
        seriesID: UUID,
        occurrenceDate: Date,
        scope requestedScope: Event.RecurrenceEditScope,
        now: Date,
        edit: (inout Event) -> Void
    ) -> UUID? {
        guard requireLoaded() else { return nil }
        guard !frozenSlots.contains(.calendarEvents) else { return nil }
        // Re-read the live series — the caller may hold a stale snapshot.
        guard let series = calendarEvents.first(where: { $0.id == seriesID }) else { return nil }

        let scope = Event.resolvedRecurrenceEditScope(
            requested: requestedScope, series: series,
            occurrenceDate: occurrenceDate, calendar: calendar
        )
        let result = Event.applyEdit(
            series: series, occurrenceDate: occurrenceDate,
            scope: scope, edit: edit, calendar: calendar
        )

        var new = calendarEvents
        var changed = Set<UUID>()

        if scope == .following, var newSeries = result.newSeries {
            let splitDay = calendar.startOfDay(for: occurrenceDate)
            let splitKey = Event.recurrenceDayKey(for: splitDay, calendar: calendar)
            // Carry the old series' on-or-after-split exceptions to the new
            // one, or the new series renders a default occurrence on a day the
            // user had customized/skipped (classified by nominal day KEY, the
            // gh#127 frame — never by reinterpreting the legacy mirror dates).
            let carried = series.recurrenceExceptions(onOrAfterDayKey: splitKey)
            newSeries.recurrenceExceptionDates.append(contentsOf: carried.dates)
            newSeries.recurrenceExceptionDayKeys.append(contentsOf: carried.dayKeys)
            // Re-parent materialized exception instances ≥ split so the day
            // belongs to the new series (delete-new sweeps them, delete-old
            // doesn't). Same frozen-key frame as the carry above.
            for index in new.indices {
                guard new[index].recurrenceParentId == series.id,
                      let instanceKey = Event.resolvedRecurrenceInstanceDayKey(
                          dayKey: new[index].recurrenceInstanceDayKey,
                          legacyDate: new[index].recurrenceInstanceDate
                      ),
                      instanceKey >= splitKey else { continue }
                new[index].recurrenceParentId = newSeries.id
                changed.insert(new[index].id)
            }
            if let updated = result.updatedSeries,
               let index = new.firstIndex(where: { $0.id == updated.id }) {
                new[index] = updated
                changed.insert(updated.id)
            }
            new.append(newSeries)
            changed.insert(newSeries.id)
        } else {
            if let updated = result.updatedSeries,
               let index = new.firstIndex(where: { $0.id == updated.id }) {
                new[index] = updated
                changed.insert(updated.id)
            }
            if let exception = result.exceptionInstance {
                new.append(exception)
                changed.insert(exception.id)
            }
            if let newSeries = result.newSeries {  // defensive; not expected off .following
                new.append(newSeries)
                changed.insert(newSeries.id)
            }
        }

        // The row the UI should re-target after this edit.
        let selectID = result.newSeries?.id ?? result.exceptionInstance?.id ?? result.updatedSeries?.id

        // No-op guard, mirroring replaceCalendarEvent's `event != old`: a
        // recurring edit that changed nothing must not bump the generation,
        // rewrite the slot, or emit an all-days-dirty delta (review #5).
        guard !changed.isEmpty, new != calendarEvents else { return selectID }
        // A series edit touches an unbounded day range → all-days-dirty (nil).
        commitCalendarEvents(new, changedIDs: changed, affectedDayKeys: nil, now: now)
        return selectID
    }

    /// Delete one occurrence of a series at `occurrenceDate`, scoped:
    ///  - `.all`      → remove the series row AND its materialized exception
    ///                  instances,
    ///  - `.single`   → skip just this day (record the exception key on the
    ///                  series) and remove any materialized instance for it,
    ///  - `.following` → cap the series the day before and remove materialized
    ///                  instances on or after the split.
    /// Every removed row that the server already knows is tombstoned, so the
    /// delete propagates and the next pull doesn't re-adopt it (the
    /// removeCalendarEvent invariant).
    func removeRecurringOccurrence(
        seriesID: UUID,
        occurrenceDate: Date,
        scope requestedScope: Event.RecurrenceEditScope,
        now: Date
    ) {
        guard requireLoaded() else { return }
        guard !frozenSlots.contains(.calendarEvents) else { return }
        guard let series = calendarEvents.first(where: { $0.id == seriesID }) else { return }

        let scope = Event.resolvedRecurrenceEditScope(
            requested: requestedScope, series: series,
            occurrenceDate: occurrenceDate, calendar: calendar
        )
        let day = calendar.startOfDay(for: occurrenceDate)
        let key = Event.recurrenceDayKey(for: day, calendar: calendar)

        var new = calendarEvents
        var changed = Set<UUID>()
        var removed = Set<UUID>()

        func instanceKey(_ e: Event) -> Int? {
            Event.resolvedRecurrenceInstanceDayKey(
                dayKey: e.recurrenceInstanceDayKey, legacyDate: e.recurrenceInstanceDate
            )
        }

        switch scope {
        case .all:
            for e in new where e.id == seriesID || e.recurrenceParentId == seriesID {
                removed.insert(e.id)
            }
            new.removeAll { removed.contains($0.id) }

        case .single:
            if let index = new.firstIndex(where: { $0.id == seriesID }) {
                new[index].appendRecurrenceException(onDay: day, calendar: calendar)
                changed.insert(seriesID)
            }
            for e in new where e.recurrenceParentId == seriesID && instanceKey(e) == key {
                removed.insert(e.id)
            }
            new.removeAll { removed.contains($0.id) }

        case .following:
            if let index = new.firstIndex(where: { $0.id == seriesID }) {
                new[index].repeatEndType = .onDate
                new[index].repeatEndDate = calendar.date(byAdding: .day, value: -1, to: day)
                changed.insert(seriesID)
            }
            for e in new where e.recurrenceParentId == seriesID {
                if let k = instanceKey(e), k >= key { removed.insert(e.id) }
            }
            new.removeAll { removed.contains($0.id) }
        }

        changed.formUnion(removed)
        guard !changed.isEmpty, new != calendarEvents else { return }
        // Sidecar is managed by hand here (like removeCalendarEvent): bump the
        // rows that CHANGED but survive (capped series, exception-key series)
        // so they push; tombstone the rows that were REMOVED. Bumping a
        // removed id would resurrect its sidecar record, so the two sets stay
        // disjoint and commit runs with bumpSidecar:false.
        let modified = changed.subtracting(removed)
        if !modified.isEmpty && !sidecarFrozen {
            sidecar.bump(modified, at: now)
        }
        tombstoneRemoved(removed)
        commitCalendarEvents(new, changedIDs: changed, affectedDayKeys: nil, now: now,
                             bumpSidecar: false)
    }

    /// Drop sidecar entries for removed rows and tombstone the ones the server
    /// already knew (so the delete propagates, not silently resurrects).
    private func tombstoneRemoved(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            let serverKnowsIt = sidecar.records[id]?.lastPushedRevision != nil
                || sidecar.serverStamps[id] != nil
            sidecar.remove([id])
            if serverKnowsIt && !sidecarFrozen {
                sidecar.tombstones.insert(id)
            }
        }
    }

    // MARK: - Domino

    /// Port of `EventStore.dominoPushTodosPastHorizon` over the shared
    /// `EventZone.horizonDate` pure function. Filter against the horizon AS
    /// OF the last push (not the current one) so a long background gap
    /// cannot silently abandon a parked todo; distance from horizon is
    /// preserved because both sides are pure-seconds arithmetic. No tick
    /// nonce here: Mac horizon visuals derive from (generation, NowBucket),
    /// so a no-op tick has zero observers by construction.
    func dominoPush(now: Date, horizonDays: Int) {
        guard requireLoaded() else { return }
        guard !frozenSlots.contains(.calendarEvents) else { return }
        guard let last = dominoLastPushEffective else {
            dominoLastPushEffective = now
            bill.bump(.dominoHeartbeats)
            chainPersist { await $0.writeDominoHeartbeat(now) }
            return
        }
        let delta = now.timeIntervalSince(last)
        guard delta > 0 else { return }
        guard delta >= Self.dominoMinimumPushInterval else { return }

        let horizonAtLast = EventZone.horizonDate(from: horizonDays, now: last)
        var new = calendarEvents
        var pushed = Set<UUID>()
        var affected: Set<DayKey>? = Set()
        func accumulate(_ keys: Set<DayKey>?) {
            guard affected != nil else { return }
            guard let keys else { affected = nil; return }
            affected?.formUnion(keys)
        }
        for index in new.indices {
            let event = new[index]
            guard event.kind == .todo,
                  event.absorbedIntoEventID == nil,
                  !event.isRecurringSeries,
                  let firstStart = event.timeRanges.first?.start,
                  firstStart >= horizonAtLast else { continue }
            accumulate(DayKey.keys(of: event, calendar: calendar))
            new[index].timeRanges = event.timeRanges.map { range in
                Event.TimeRange(
                    start: range.start.addingTimeInterval(delta),
                    end: range.end.addingTimeInterval(delta)
                )
            }
            accumulate(DayKey.keys(of: new[index], calendar: calendar))
            pushed.insert(event.id)
        }
        dominoLastPushEffective = now
        if !pushed.isEmpty {
            bill.bump(.dominoPushes)
            commitCalendarEvents(new, changedIDs: pushed, affectedDayKeys: affected, now: now)
        } else {
            // Nothing moved: an 8-byte heartbeat, never a full rewrite.
            bill.bump(.dominoHeartbeats)
            chainPersist { await $0.writeDominoHeartbeat(now) }
        }
    }

    // MARK: - Sync merge (phase-1 contract: server truth, local dirty wins)

    struct RemoteAdoption: Equatable {
        var adopted = 0
        var keptDirty = 0
        var removed = 0
        var overriddenDirty = 0
    }

    /// Dirty = the sidecar knows local revisions the server hasn't seen.
    func dirtyEventIDs() -> Set<UUID> {
        let live = Set(calendarEvents.map(\.id))
        return Set(sidecar.records.compactMap { id, meta in
            guard live.contains(id) else { return nil }
            return meta.revision > (meta.lastPushedRevision ?? 0) ? id : nil
        })
    }

    func dirtyEvents() -> [Event] {
        let ids = dirtyEventIDs()
        return calendarEvents.filter { ids.contains($0.id) }
    }

    /// Phase-1 pull merge: the server snapshot replaces local state EXCEPT
    /// rows that are locally dirty — those keep the local version and wait
    /// for the push, unless `overridingDirty` names them (the stale-write
    /// guardrail decided the server side moved: iOS wins, the local edit
    /// is dropped). Emits ONE bulk delta; adopted rows lose their sidecar
    /// entry (clean baseline — no fake local history).
    @discardableResult
    func applyRemoteEvents(
        _ remote: [Event],
        overridingDirty: Set<UUID>,
        now: Date
    ) -> RemoteAdoption {
        guard requireLoaded() else { return RemoteAdoption() }
        guard !frozenSlots.contains(.calendarEvents) else { return RemoteAdoption() }

        var adoption = RemoteAdoption()
        let dirtyIDs = dirtyEventIDs().subtracting(overridingDirty)
        let localByID = Dictionary(uniqueKeysWithValues: calendarEvents.map { ($0.id, $0) })
        let remoteIDs = Set(remote.map(\.id))

        var merged: [Event] = []
        var cleanedSidecarIDs = Set<UUID>()
        var seenRemoteIDs = Set<UUID>()
        for row in remote {
            // Belt for QA5 F3: duplicate ids in one snapshot must not
            // duplicate truth rows (first occurrence wins).
            guard seenRemoteIDs.insert(row.id).inserted else { continue }
            if sidecar.tombstones.contains(row.id) {
                if overridingDirty.contains(row.id) {
                    // iOS wrote AFTER our delete: iOS wins, the row returns.
                    sidecar.tombstones.remove(row.id)
                    merged.append(row)
                    adoption.adopted += 1
                    adoption.overriddenDirty += 1
                    cleanedSidecarIDs.insert(row.id)
                }
                // Otherwise the local delete stands; the push will carry it.
                continue
            }
            if dirtyIDs.contains(row.id), let local = localByID[row.id] {
                merged.append(local)
                adoption.keptDirty += 1
            } else {
                merged.append(row)
                adoption.adopted += 1
                if overridingDirty.contains(row.id) { adoption.overriddenDirty += 1 }
                cleanedSidecarIDs.insert(row.id)
            }
        }
        // Local dirty rows the server has never seen stay; clean local rows
        // absent from the server were deleted elsewhere — they go.
        for event in calendarEvents where !remoteIDs.contains(event.id) {
            if dirtyIDs.contains(event.id) {
                merged.append(event)
                adoption.keptDirty += 1
            } else {
                adoption.removed += 1
                if overridingDirty.contains(event.id) { adoption.overriddenDirty += 1 }
                cleanedSidecarIDs.insert(event.id)
            }
        }

        guard merged != calendarEvents || adoption.removed > 0 else {
            return RemoteAdoption(adopted: 0, keptDirty: adoption.keptDirty, removed: 0, overriddenDirty: 0)
        }

        let changed = Set(merged.map(\.id)).symmetricDifference(Set(calendarEvents.map(\.id)))
            .union(merged.filter { localByID[$0.id] != $0 }.map(\.id))
        sidecar.remove(cleanedSidecarIDs)
        commitCalendarEvents(
            merged,
            changedIDs: changed,
            affectedDayKeys: nil,
            now: now,
            bumpSidecar: false
        )
        return adoption
    }

    /// The push succeeded: exactly the CAPTURED revisions are the server's
    /// now — an edit that landed during the network round-trip stays dirty
    /// (round-5 review #3: stamping the current revision marked unpushed
    /// edits clean).
    func markPushed(_ revisions: [UUID: Int64]) {
        guard !sidecarFrozen else { return }
        for (id, pushedRevision) in revisions {
            guard var meta = sidecar.records[id] else { continue }
            meta.lastPushedRevision = max(meta.lastPushedRevision ?? 0, pushedRevision)
            sidecar.setMeta(meta, for: id)
        }
        persistSidecar()
    }

    /// Persist sidecar bookkeeping now (dedicated sequence) so a quit right
    /// after a sync keeps the state.
    private func persistSidecar() {
        guard !sidecarFrozen else { return }
        let snapshot = sidecar
        let seq = nextSidecarSeq()
        chainPersist { await $0.submitSidecar(snapshot, generation: seq) }
    }

    // MARK: - Sync baselines and tombstones (persisted with the sidecar)

    var serverStamps: [UUID: String] { sidecar.serverStamps }
    var tombstonedIDs: Set<UUID> { sidecar.tombstones }

    /// Replace the pull baseline wholesale (one pull = one authoritative
    /// snapshot of server stamps).
    func setServerStamps(_ stamps: [UUID: String]) {
        guard !sidecarFrozen else { return }
        sidecar.serverStamps = stamps
        sidecar.pushedAwaitingRebaseline.subtract(Set(stamps.keys))
        persistSidecar()
    }

    /// After OUR push, the row's next server stamp is our own write echoed
    /// in the server's formatting — mark it for conflict-free rebaselining
    /// on the next pull instead of guessing the echo's string form.
    func markAwaitingRebaseline(_ ids: Set<UUID>) {
        guard !sidecarFrozen, !ids.isEmpty else { return }
        sidecar.pushedAwaitingRebaseline.formUnion(ids)
        for id in ids { sidecar.serverStamps.removeValue(forKey: id) }
        persistSidecar()
    }

    var pushedAwaitingRebaseline: Set<UUID> { sidecar.pushedAwaitingRebaseline }

    func clearTombstones(_ ids: Set<UUID>) {
        guard !sidecarFrozen, !ids.isEmpty else { return }
        sidecar.tombstones.subtract(ids)
        for id in ids { sidecar.serverStamps.removeValue(forKey: id) }
        persistSidecar()
    }

    /// The captured (id → revision) map for the current dirty set — what a
    /// push must hand back to markPushed.
    func dirtyRevisions() -> [UUID: Int64] {
        dirtyEventIDs().reduce(into: [:]) { acc, id in
            acc[id] = sidecar.records[id]?.revision
        }
    }

    // MARK: - Commit core

    private func commitCalendarEvents(
        _ new: [Event],
        changedIDs: Set<UUID>,
        affectedDayKeys: Set<DayKey>?,
        now: Date,
        bumpSidecar: Bool = true
    ) {
        calendarEvents = new
        let generation = revision.bump(.calendarEvents)
        if bumpSidecar && !sidecarFrozen {
            sidecar.bump(changedIDs, at: now)
        }
        bill.bump(.storeCommits)
        bill.bump(.recordsRewritten, by: changedIDs.count)

        let delta = CommitDelta(
            slot: .calendarEvents,
            generation: generation,
            changedIDs: changedIDs,
            affectedDayKeys: affectedDayKeys
        )
        emit(delta)

        // The stamp rides with the rows it describes. This plumbs the
        // in-memory stamp; MONOTONICITY (never regress the on-disk stamp,
        // the iOS dominoStampToCommit rule) is enforced again at the drain,
        // so it cannot depend on this call site — review finding 2.
        let stamp = dominoLastPushEffective
        let snapshot = calendarEvents
        let sidecarSnapshot = sidecar
        let skipSidecar = sidecarFrozen
        let sidecarGeneration = nextSidecarSeq()
        chainPersist { persistence in
            await persistence.submitCalendarEvents(snapshot, generation: generation, dominoStamp: stamp)
            if !skipSidecar {
                await persistence.submitSidecar(sidecarSnapshot, generation: sidecarGeneration)
            }
        }
    }

    private func chainPersist(_ operation: @escaping @Sendable (MacPersistence) async -> Void) {
        let previous = persistChain
        let persistence = self.persistence
        persistChain = Task {
            await previous?.value
            await operation(persistence)
        }
    }

    private func emit(_ delta: CommitDelta) {
        bill.bump(.deltasEmitted)
        for observer in observers where observer.interest.matches(delta) {
            bill.bump(.observerNotifications)
            observer.handler(delta)
        }
    }

    /// Terminate/background edge: everything pending reaches disk. A write
    /// failure is never silent — the snapshot is retained actor-side for
    /// retry and the tripwire records it (review finding 5).
    func flush() async {
        await persistChain?.value
        await persistence.flush()
        let failures = await persistence.stats.failedWrites
        if failures > lastSeenFailedWrites {
            bill.bump(.persistWriteFailuresSeen, by: failures - lastSeenFailedWrites)
            lastSeenFailedWrites = failures
        }
    }
    private var lastSeenFailedWrites = 0
}
