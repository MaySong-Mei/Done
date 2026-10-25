//
//  MacEventStore.swift
//  DoneMac
//
//  The Mac surfaces' window onto the SHARED `EventStore` — the same store,
//  storage and sync engine the iPhone runs. This type used to be its own
//  truth layer (own persistence actor, revision sidecar, own sync engine);
//  that design retired when the Mac caught up with king's realtime sync
//  (gh#257): keeping a parallel engine in step with the epoch / write-gate /
//  change-feed protocol was not affordable, and the 2026-09 design kept this
//  exact exit ("stop the thin store, use the shared EventStore").
//
//  What stays Mac-native is the observation contract the projection layer
//  is built on (#219 concepts 1 and 3): surfaces register a StoreInterest and
//  receive one CommitDelta per change to the calendar rows. The shared store
//  is ObservableObject-era, so the delta is DERIVED here: every published
//  `rawCalendarEvents` value is diffed by id against the last one this
//  adapter saw. That covers local edits AND rows the sync engine applies from
//  other devices, with one code path.
//
//  `now` stays an explicit parameter on the mutation API so call sites keep
//  their shape; the shared store stamps with its own clock.
//

import Foundation
import Combine

@MainActor
final class MacEventStore {
    /// The shared store's rows, always — never a copy that could lag. Deltas
    /// are emitted only after the shared store has stored its new value
    /// (never from inside its @Published willSet), so a handler that reads
    /// this during its callback sees the rows the delta describes.
    var calendarEvents: [Event] { shared.rawCalendarEvents }
    private(set) var revision = StoreRevision()
    /// The rows the last emitted delta was computed against.
    private var lastEmittedRows: [Event] = []

    let shared: EventStore
    let bill: MacWorkBill
    /// The Mac's day frame. Follows the system time zone (MacAppRuntime
    /// adopts the new `Calendar.current` on NSSystemTimeZoneDidChange), so it
    /// stays the frame the shared store computes recurrence days in.
    private(set) var calendar: Calendar

    private struct Observer {
        let id: UUID
        let interest: StoreInterest
        let handler: (CommitDelta) -> Void
    }
    private var observers: [Observer] = []
    private var rowsCancellable: AnyCancellable?
    /// While > 0, a mutation this adapter forwarded is running: the shared
    /// store may write its array several times for one operation (a
    /// recurring split appends, re-parents and caps in separate writes), and
    /// those are only marked pending (`hasPendingRows`) until it returns, then
    /// leave as ONE delta — the "one Mac mutation, one delta" contract the
    /// budget assertions are written against. Writes the shared store makes
    /// on its own (sync apply, restore) arrive with depth 0 and coalesce into
    /// one delta on the next main-queue turn (see `flushScheduled`).
    private var batchDepth = 0
    /// A write landed that no delta has described yet.
    private var hasPendingRows = false
    /// A main-queue flush is already on its way for writes made outside a
    /// Mac mutation (sync apply, restore). The sync applier writes the array
    /// once per tombstone; diffing each write would cost a full pass over
    /// every row per tombstone (review 2026-10-24 #3: a 500-row page over
    /// 5,000 rows ≈ 2 s of main thread), so those writes coalesce into one
    /// diff per main-queue turn.
    private var flushScheduled = false
    /// True while observers run; a mutation from inside a handler defers its
    /// delta to the next turn instead of re-entering `emit`.
    private var isEmitting = false

    /// Above this many changed rows a delta claims every day (nil) instead of
    /// walking each row's day span — a pull of a whole account, a restore,
    /// an erase. Bulk is the documented honest fallback, never a guess.
    static let bulkThreshold = 200

    /// The shared store loads synchronously in its initializer, so the
    /// adapter is loaded from birth. Kept for the surfaces that wait on it.
    var isLoaded: Bool { true }

    init(shared: EventStore, bill: MacWorkBill, calendar: Calendar) {
        self.shared = shared
        self.bill = bill
        self.calendar = calendar
        lastEmittedRows = shared.rawCalendarEvents
        rowsCancellable = shared.$rawCalendarEvents
            .dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.receive() }
            }
    }

    /// Kept for call-site compatibility with the retired async loader.
    func load() async {}

    /// The shared store writes on every commit and flushes its debounced
    /// mirrors on the lifecycle edges (`AppLifecycle`), terminate included.
    /// Nothing is pending here.
    func flush() async {}

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

    // MARK: - Mutations (forwarded to the shared store)

    func addCalendarEvent(_ event: Event, now: Date) {
        batched { shared.addCalendarEvent(event) }
    }

    /// Replace one event wholesale. The shared store applies the write-side
    /// rules (exception-instance mirror rebase, interrupt refresh) and saves.
    func replaceCalendarEvent(_ event: Event, now: Date) {
        guard let old = shared.findCalendarEvent(id: event.id), old != event else { return }
        batched { shared.updateCalendarEvent(event) }
    }

    func removeCalendarEvent(id: UUID, now: Date) {
        guard let event = shared.findCalendarEvent(id: id) else { return }
        batched { shared.deleteCalendarEvent(event) }
    }

    /// this / following / all edit of one occurrence, through the shared
    /// store's orchestration (logs, feedback and interrupts re-anchor with
    /// the split, which the retired Mac port could not do).
    ///
    /// Returns the id the UI should now select: the materialized one-day
    /// exception (`.single`), the split-off series (`.following`), or the
    /// series itself (`.all`). nil when nothing new was minted for a
    /// per-occurrence edit, so the caller keeps its selection instead of
    /// jumping to the template.
    @discardableResult
    func applyRecurringEdit(
        seriesID: UUID,
        occurrenceDate: Date,
        scope requestedScope: Event.RecurrenceEditScope,
        now: Date,
        edit: (inout Event) -> Void
    ) -> UUID? {
        noteFrameMismatchIfAny()
        guard let series = shared.findCalendarEvent(id: seriesID) else { return nil }
        let scope = Event.resolvedRecurrenceEditScope(
            requested: requestedScope, series: series,
            occurrenceDate: occurrenceDate, calendar: calendar
        )
        let before = Set(shared.rawCalendarEvents.map(\.id))
        batched {
            shared.applyRecurringEdit(
                seriesEvent: series, occurrenceDate: occurrenceDate,
                scope: requestedScope, edit: edit
            )
        }
        let minted = shared.rawCalendarEvents.filter { !before.contains($0.id) }
        switch scope {
        case .all:
            return seriesID
        case .following:
            // The split-off row: a new series, or — when the edit turned
            // repeat off — a one-off. Never the capped old series, whose end
            // is now before `occurrenceDate` (review 2026-10-24 #1).
            return minted.first(where: { $0.id != seriesID && $0.recurrenceParentId != seriesID })?.id
                ?? minted.first?.id
                ?? seriesID
        case .single:
            return minted.first(where: { $0.recurrenceParentId == seriesID })?.id
        }
    }

    /// Delete one occurrence of a series, scoped — the shared store's delete,
    /// which tombstones through the sync engine like every other delete.
    func removeRecurringOccurrence(
        seriesID: UUID,
        occurrenceDate: Date,
        scope requestedScope: Event.RecurrenceEditScope,
        now: Date
    ) {
        noteFrameMismatchIfAny()
        guard let series = shared.findCalendarEvent(id: seriesID) else { return }
        batched {
            shared.deleteRecurringCalendarEvent(
                seriesEvent: series, occurrenceDate: occurrenceDate, scope: requestedScope
            )
        }
    }

    /// The system zone changed and the runtime moved the Mac to it.
    func adoptCalendar(_ calendar: Calendar) {
        self.calendar = calendar
    }

    /// The shared store computes recurrence days in `Calendar.current`. If the
    /// zone changed and the notification has not reached the runtime yet, the
    /// shared store's frame wins (it is the one that writes); record it so a
    /// wrong-day report can be traced. Not an assert: a laptop crossing zones
    /// is ordinary, and crashing a debug build over it helped nobody
    /// (review 2026-10-24 #2).
    private func noteFrameMismatchIfAny() {
        guard calendar.timeZone != Calendar.current.timeZone else { return }
        DiagnosticTrail.record("Calendar", "mac.frame.mismatch mac=\(calendar.timeZone.identifier) current=\(Calendar.current.timeZone.identifier)")
    }

    // MARK: - Delta derivation

    private func batched<T>(_ body: () -> T) -> T {
        batchDepth += 1
        defer {
            batchDepth -= 1
            if batchDepth == 0 {
                if isEmitting {
                    scheduleFlush()
                } else {
                    flushPendingDeltas()
                }
            }
        }
        return body()
    }

    /// Called from the shared store's @Published willSet: the new value is
    /// not stored yet, so nothing is read here — the flush reads the stored
    /// array later.
    private func receive() {
        hasPendingRows = true
        guard batchDepth == 0 else { return }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.flushScheduled = false
                self?.flushPendingDeltas()
            }
        }
    }

    /// Emit the delta for every write not yet described. Runs at the end of
    /// a Mac mutation (synchronously) and on the turn after outside writes.
    /// Tests call it to settle outside writes without waiting a turn.
    func flushPendingDeltas() {
        guard hasPendingRows, !isEmitting else { return }
        hasPendingRows = false
        ingest(shared.rawCalendarEvents)
    }

    private func ingest(_ rows: [Event]) {
        let old = lastEmittedRows
        var oldByID: [UUID: Event] = [:]
        oldByID.reserveCapacity(old.count)
        for event in old { oldByID[event.id] = event }

        var changed = Set<UUID>()
        var touched: [Event] = []
        for event in rows {
            if let previous = oldByID.removeValue(forKey: event.id) {
                if previous != event {
                    changed.insert(event.id)
                    touched.append(previous)
                    touched.append(event)
                }
            } else {
                changed.insert(event.id)
                touched.append(event)
            }
        }
        for (id, removed) in oldByID {
            changed.insert(id)
            touched.append(removed)
        }
        lastEmittedRows = rows
        guard !changed.isEmpty else { return }

        let generation = revision.bump(.calendarEvents)
        bill.bump(.storeCommits)
        bill.bump(.recordsRewritten, by: changed.count)
        emit(CommitDelta(
            slot: .calendarEvents,
            generation: generation,
            changedIDs: changed,
            affectedDayKeys: changed.count > Self.bulkThreshold ? nil : affectedKeys(touching: touched)
        ))
    }

    /// A recurring series renders on every pattern day, not its seed days,
    /// so any change touching one must claim EVERYTHING — an underclaimed
    /// delta leaves ghost blocks in day caches (round-2 blocker, review #2 /
    /// QA3 F2). Bulk (nil) is the documented honest fallback.
    private func affectedKeys(touching events: [Event]) -> Set<DayKey>? {
        var acc = Set<DayKey>()
        for event in events {
            if event.isRecurringSeries { return nil }
            guard let keys = DayKey.keys(of: event, calendar: calendar) else { return nil }
            acc.formUnion(keys)
        }
        return acc
    }

    private func emit(_ delta: CommitDelta) {
        bill.bump(.deltasEmitted)
        isEmitting = true
        defer {
            isEmitting = false
            // A handler that wrote to the store left its delta for later.
            if hasPendingRows { scheduleFlush() }
        }
        for observer in observers where observer.interest.matches(delta) {
            bill.bump(.observerNotifications)
            observer.handler(delta)
        }
    }
}
