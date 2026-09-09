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

    let bill: MacWorkBill
    let persistence: MacPersistence
    private let calendar: Calendar

    private struct Observer {
        let id: UUID
        let interest: StoreInterest
        let handler: (CommitDelta) -> Void
    }
    private var observers: [Observer] = []

    /// Serialized chain of persistence submissions. `flush()` awaits the
    /// chain before draining the actor, so "everything committed so far is
    /// on disk after flush" is a guarantee, not a race.
    private var persistChain: Task<Void, Never>?

    /// Same threshold, same rationale as `EventStore.dominoMinimumPushInterval`:
    /// deferring sub-minute drift to the next call produces the identical end
    /// state (push is computed relative to `last`), so this trades write
    /// frequency against nothing.
    static let dominoMinimumPushInterval: TimeInterval = 60

    init(persistence: MacPersistence, bill: MacWorkBill, calendar: Calendar) {
        self.persistence = persistence
        self.bill = bill
        self.calendar = calendar
    }

    // MARK: - Load

    func load() async {
        let loaded = await persistence.loadAll()
        calendarEvents = loaded.calendarEvents
        todoLists = loaded.todoLists
        dominoLastPushEffective = loaded.dominoStamp
        sidecar = loaded.sidecar
        frozenSlots = Set(loaded.frozenSlots)
        let orphans = sidecar.orphans(against: Set(calendarEvents.map(\.id)))
        if !orphans.isEmpty {
            bill.bump(.sidecarOrphansSeen, by: orphans.count)
        }
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

    func addCalendarEvent(_ event: Event, now: Date) {
        guard !frozenSlots.contains(.calendarEvents) else { return }
        var new = calendarEvents
        new.append(event)
        commitCalendarEvents(
            new,
            changedIDs: [event.id],
            affectedDayKeys: DayKey.keys(of: event, calendar: calendar),
            now: now
        )
    }

    /// Replace one event wholesale. The caller built the new value through
    /// shared edit helpers; the store's job is delta + stamping, not rules.
    func replaceCalendarEvent(_ event: Event, now: Date) {
        guard !frozenSlots.contains(.calendarEvents) else { return }
        guard let index = calendarEvents.firstIndex(where: { $0.id == event.id }) else { return }
        let old = calendarEvents[index]
        guard event != old else { return }
        var new = calendarEvents
        new[index] = event
        commitCalendarEvents(
            new,
            changedIDs: [event.id],
            affectedDayKeys: DayKey.keys(of: old, calendar: calendar)
                .union(DayKey.keys(of: event, calendar: calendar)),
            now: now
        )
    }

    func removeCalendarEvent(id: UUID, now: Date) {
        guard !frozenSlots.contains(.calendarEvents) else { return }
        guard let index = calendarEvents.firstIndex(where: { $0.id == id }) else { return }
        let old = calendarEvents[index]
        var new = calendarEvents
        new.remove(at: index)
        sidecar.remove([id])
        commitCalendarEvents(
            new,
            changedIDs: [id],
            affectedDayKeys: DayKey.keys(of: old, calendar: calendar),
            now: now,
            bumpSidecar: false
        )
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
        var affected = Set<DayKey>()
        for index in new.indices {
            let event = new[index]
            guard event.kind == .todo,
                  event.absorbedIntoEventID == nil,
                  !event.isRecurringSeries,
                  let firstStart = event.timeRanges.first?.start,
                  firstStart >= horizonAtLast else { continue }
            affected.formUnion(DayKey.keys(of: event, calendar: calendar))
            new[index].timeRanges = event.timeRanges.map { range in
                Event.TimeRange(
                    start: range.start.addingTimeInterval(delta),
                    end: range.end.addingTimeInterval(delta)
                )
            }
            affected.formUnion(DayKey.keys(of: new[index], calendar: calendar))
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
        if bumpSidecar {
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

        // The stamp rides with the rows it describes (the iOS rule "no
        // calendar write may drop the stamp", enforced here, once).
        let stamp = dominoLastPushEffective
        let snapshot = calendarEvents
        let sidecarSnapshot = sidecar
        chainPersist { persistence in
            await persistence.submitCalendarEvents(snapshot, generation: generation, dominoStamp: stamp)
            await persistence.submitSidecar(sidecarSnapshot, generation: generation)
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

    /// Terminate/background edge: everything pending reaches disk.
    func flush() async {
        await persistChain?.value
        await persistence.flush()
    }
}
