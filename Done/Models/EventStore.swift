//
//  EventStore.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import Foundation
import Combine
import SwiftUI
import WidgetKit
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Done",
    category: "EventStore"
)

/// Pure projection of the calendar store into the widget's App Group payload.
///
/// Split out of `EventStore.syncWidgetSnapshots` so the interesting part —
/// *which* occurrences the widget is allowed to see and what identity each one
/// carries — is testable without a store, a simulator or an App Group. The
/// store keeps only the impure half: reading the clock, the type-color store
/// and the settings, hashing, writing, and poking WidgetCenter.
///
/// Contract: what comes out of here is what the CANVAS would render over the
/// window, one value per occurrence — the union of BOTH canvas paths,
/// `CalendarLayout.occurrencesForDate` (timed blocks; it `continue`s on
/// `isAllDay`) and `CalendarLayout.allDayOccurrencesForDate` (the all-day
/// strip). A divergence from either is a bug in one of the two; all-day events
/// belonging here is not one.
///
/// One divergence is deliberate: `occurrencesForDate` replaces a running
/// event's range with `timerStartedAt → now`, and this builder does not. A
/// timer's end is `Date()`, which is stale the moment the payload is written,
/// so mirroring it would bake a frozen "ends now" into a blob the widget may
/// serve for hours. The stored `timeRanges` of a running event are `[now, now]`
/// (see `startTimer`), i.e. a zero-length occurrence — that, not a wrong
/// duration, is what the widget shows for the one event being timed.
enum WidgetSnapshotBuilder {
    /// Snapshot window: yesterday 00:00 (inclusive) → today + 7d 00:00
    /// (exclusive). Yesterday is included because a cross-midnight occurrence
    /// that STARTED yesterday is still on today's canvas; the 7 days ahead are
    /// what let the widget stay useful for a week without the app being opened.
    static func window(now: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 7, to: today) ?? today
        return (start, end)
    }

    /// Expand `events` into per-occurrence snapshots overlapping
    /// `[windowStart, windowEnd)`.
    ///
    /// - `colorHex` is injected (rather than reaching for
    ///   `EventTypeTemplateStore`) so the function stays free of UserDefaults.
    /// - Overlap is half-open on both ends, matching
    ///   `CalendarLayout.occurrencesForDate` and the widget's own `todayEvents()`
    ///   — an occurrence that ends exactly at `windowStart` is outside.
    /// - Output is ordered by start time (ties broken by id) so an unrelated
    ///   reordering of `events` can't churn the payload hash.
    /// - Every emitted `id` is distinct: `ordinals` hands duplicate
    ///   `(event, start)` pairs a tiebreaker, so `Set(ids).count == count` is a
    ///   real invariant the on-device log can check.
    static func snapshots(
        events: [Event],
        windowStart: Date,
        windowEnd: Date,
        calendar: Calendar,
        colorHex: (String) -> String?
    ) -> [SharedEventSnapshot] {
        var snapshots: [SharedEventSnapshot] = []
        // How many occurrences of one event already claimed a given start.
        // Only ever non-zero for the degenerate same-start shape a multi-range
        // drag can produce; see `SharedEventSnapshot.occurrenceID`.
        var ordinals: [OccurrenceSlot: Int] = [:]

        /// Claims the next free ordinal for `(event, start)` — 0 the first time,
        /// which is the plain `(event, start)` composite id.
        func claimOrdinal(_ eventID: UUID, _ start: Date) -> Int {
            let slot = OccurrenceSlot(eventID: eventID, start: start)
            let ordinal = ordinals[slot, default: 0]
            ordinals[slot] = ordinal + 1
            return ordinal
        }

        for event in events {
            // Absorbed todos render inside their parent event's detail view,
            // never as their own block. Same predicate the canvas filter
            // (`EventStore.canvasRenderableCalendarEvents`) uses, so a clause
            // added to `Event.isCanvasRenderable` reaches both; applied again
            // here so a caller that hands over the raw array still cannot leak
            // an absorbed todo onto the widget.
            guard event.isCanvasRenderable else { continue }

            if event.isRecurringSeries {
                // A series has no materialized ranges — walk the window day by
                // day and ask the same expander the canvas uses. Exception days
                // (skipped, or materialized into their own instance event) drop
                // out inside `recurrenceOccurrence`, so a per-occurrence edit
                // such as "mark this one done" is carried by that instance
                // event, which arrives through the branch below.
                var day = windowStart
                while day < windowEnd {
                    if let range = CalendarLayout.recurrenceOccurrence(for: event, on: day, calendar: calendar),
                       range.end > windowStart, range.start < windowEnd {
                        snapshots.append(makeSnapshot(
                            event: event,
                            range: range,
                            ordinal: claimOrdinal(event.id, range.start),
                            colorHex: colorHex
                        ))
                    }
                    guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
                    day = next
                }
            } else {
                // Render-frame ranges: the widget mirrors the canvas (see the
                // contract above), and the canvas pins a detached exception
                // instance to its nominal day (`CalendarLayout.
                // occurrencesForDate` → `renderTimeRanges`). Identical to
                // `effectiveTimeRanges` for everything else.
                for range in event.renderTimeRanges(calendar: calendar) where range.end > windowStart && range.start < windowEnd {
                    snapshots.append(makeSnapshot(
                        event: event,
                        range: range,
                        ordinal: claimOrdinal(event.id, range.start),
                        colorHex: colorHex
                    ))
                }
            }
        }

        return snapshots.sorted {
            $0.startDate == $1.startDate
                ? $0.id.uuidString < $1.id.uuidString
                : $0.startDate < $1.startDate
        }
    }

    /// One event's claim on one start instant. Key of the `ordinals` tally that
    /// keeps two same-start ranges of one event from minting the same id.
    private struct OccurrenceSlot: Hashable {
        let eventID: UUID
        let start: Date
    }

    private static func makeSnapshot(
        event: Event,
        range: Event.TimeRange,
        ordinal: Int,
        colorHex: (String) -> String?
    ) -> SharedEventSnapshot {
        SharedEventSnapshot(
            // Per-occurrence identity. The old code put `event.id` here, so a
            // 7-day expansion of one series produced seven snapshots sharing a
            // single UUID — enough to collide any id-keyed `ForEach` or dedupe
            // on the widget side. `eventID` keeps the event reachable.
            id: SharedEventSnapshot.occurrenceID(
                eventID: event.id,
                occurrenceStart: range.start,
                ordinal: ordinal
            ),
            eventID: event.id,
            title: event.title,
            type: event.type,
            colorHex: colorHex(event.type),
            startDate: range.start,
            endDate: range.end,
            isAllDay: event.isAllDay,
            isDone: event.isDone,
            isInterrupt: event.isInterrupt,
            parentEventID: event.interruptRelation?.parentEventID
        )
    }
}

/// Durability trail for calendar-event mutations, on its own category so it can
/// be isolated on-device with:
///
///     log stream --predicate 'category == "Persistence"'
///
/// Exists to answer one question when a mutation appears to survive an app
/// restart: was it never written, written and then overwritten, or written and
/// then pulled back by a cloud restore? Each of those leaves a different trail.
/// Counts and IDs only — no user text.
private let persistenceLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Done",
    category: "Persistence"
)

/// Emits one entry to both sinks. They answer different questions and neither
/// is redundant: `os_log` is what you watch live over a cable, `DiagnosticTrail`
/// is what survives the process so the NEXT launch can be compared against it —
/// which is the whole point here, and something os_log cannot do for a
/// third-party iOS app (see `DiagnosticTrail`).
private func recordPersistence(_ message: String) {
    persistenceLogger.log("\(message, privacy: .public)")
    DiagnosticTrail.record("Persistence", message)
}

private func recordPersistenceError(_ message: String) {
    persistenceLogger.error("\(message, privacy: .public)")
    DiagnosticTrail.record("Persistence", "ERROR " + message)
}

/// Protocol unifying CalendarEventFeedbackRecord and CalendarEventLogRecord
/// for shared pruning logic.
protocol OccurrenceRecord {
    var id: CalendarOccurrenceKey { get }
    var eventID: UUID { get }
    var baseSeriesEventID: UUID? { get }
    var occurrenceDate: Date { get }
}

extension CalendarEventFeedbackRecord: OccurrenceRecord {}
extension CalendarEventLogRecord: OccurrenceRecord {}

struct SmartSplitUndoInfo {
    let originalEvent: Event
    let newEventIDs: [UUID]
}

struct MergeUndoInfo {
    let sourceEvent: Event
    let targetEvent: Event
    let mergedEventID: UUID
}

@MainActor
final class EventStore: ObservableObject {
    // Setters are internal (not private(set)) so EventStore extensions in
    // other files can mutate the published state. External call sites
    // should still go through the dedicated mutation helpers.
    @Published var events: [Event] = []
    /// Raw underlying calendar-event array — includes absorbed todos
    /// (those with `absorbedIntoEventID != nil`).  Most consumers
    /// should NOT read this directly; use
    /// `canvasRenderableCalendarEvents` for anything that renders on
    /// the canvas, drives analytics, or is user-facing.  Raw is
    /// correct ONLY for ID lookups, sync/restore/mutate paths, and
    /// the handful of deliberate-raw sites documented in
    /// `project_canvas_renderable_audit.md`.  Compile-time enforcement
    /// of this choice is the whole point of having two separate
    /// accessors after audit grouping #4.
    @Published var rawCalendarEvents: [Event] = [] {
        // Structural invalidation for `calendarEventIndexByID` (gh#213).
        //
        // The durable statement is the narrow one: `didSet` RUNS ON EVERY
        // WRITE THROUGH THIS PROPERTY NAME, whatever accessor form the
        // compiler picks. `= newValue`, `[i] = e`, `[i].field = v`, `append`,
        // `removeAll`, `sort`, and `&rawCalendarEvents` passed `inout` are
        // all writes through the name, so all of them land here. That is the
        // invalidation argument: a future mutation site cannot forget to
        // invalidate the way it could forget to bump a hand-maintained
        // generation counter. `EventStoreLookupIndexTests` has one fixture
        // per form, so the claim is measured rather than argued.
        //
        // NOT, as an earlier version of this comment said, "because a stored
        // property with an observer gets no `_modify`". This is not a plain
        // stored property — it is `@Published`, wrapper-backed, and it is
        // `Published`'s enclosing-instance subscript that denies `_modify`.
        // And for a PLAIN stored property SE-0268 grants a `didSet` that does
        // not mention `oldValue` exactly the in-place `_modify` that argument
        // claims cannot exist. The conclusion survived; the reason did not.
        //
        // `didSet` and not `willSet`, and the ORDER is load-bearing:
        // `@Published` publishes in `willSet`, i.e. BEFORE the new value is
        // stored. Under `willSet` a synchronous `$rawCalendarEvents`
        // subscriber that did a by-id lookup would rebuild the index against
        // the PRE-write array and nothing would clear it afterwards. No
        // subscriber today is synchronous:
        // `git grep -nE '\$(rawCalendarEvents|calendarEventLogRecords|calendarEventFeedbackRecords)' -- 'Done/*.swift'`
        // returns 8 lines — one is a doc comment, and each of the other 7
        // feeds a pipeline that `.debounce(for:scheduler: RunLoop.main)`s
        // before any `sink` (`SupabaseSyncService` 510/520/530,
        // `BackupSnapshotService` 96-98 through one `Merge5`,
        // `ImageBackupCoordinator` 81 through one `Merge`). So the hazard is
        // unreachable today, and
        // `testASynchronousPublishedSubscriberDoesNotStrandAStaleIndex` pins
        // the ordering anyway — "no synchronous subscriber exists" is a fact
        // about today's call sites, not about this class.
        //
        // The one LANGUAGE-level exception: Swift skips `willSet`/`didSet`
        // for assignments written lexically inside this class's own `init`.
        // Closed here by accident of structure, not by design — the arrays
        // are filled from `load()`, which is a method. Seeding one of them
        // from `init` would reopen it.
        //
        // The cost claim, stated with its premises: this `didSet` costs
        // nothing new BECAUSE the property is `@Published` (whose setter
        // already copies) and BECAUSE no observer body here reads `oldValue`
        // (which would force the old array to be fetched and retained). Drop
        // either premise and the arithmetic inverts while the sentence still
        // reads the same.
        didSet { calendarEventIndexByID = nil }
    }
    /// Bumped on every `dominoPushTodosPastHorizon` call (regardless
    /// of whether any todo actually moved).  Views that depend on
    /// `EventZone.horizonDate(...)` re-read it via @EnvironmentObject
    /// observation, so the horizon line and partial-day tint visibly
    /// drift each minute even when no events crossed the threshold.
    /// Treated as opaque — only the change matters, not the value.
    @Published private(set) var dominoTickNonce: Int = 0

    /// Calendar events that should render as independent blocks on the
    /// timeline canvas. Excludes absorbed todos — those with
    /// `absorbedIntoEventID != nil` live as subitems inside their
    /// parent event's detail view, not as their own canvas blocks.
    /// Membership is `Event.isCanvasRenderable` — shared with the widget
    /// projection so the two can't drift. Sync / detail lookup / mutation
    /// paths read `rawCalendarEvents` directly and still see the full list.
    var canvasRenderableCalendarEvents: [Event] {
        rawCalendarEvents.filter(\.isCanvasRenderable)
    }

    /// Todos that live in the Todo stack drawer — captured without any
    /// time range, not absorbed, not done. The canvas never renders
    /// these (empty `timeRanges` yields zero occurrences); the stack
    /// drawer is their only home. Membership is `Event.isStackTodo` —
    /// shared with the report stagnation line so the two can't drift.
    var datelessTodos: [Event] {
        rawCalendarEvents.filter(\.isStackTodo)
    }

    /// Return a scheduled todo to the stack: drop its time ranges so it
    /// becomes an `isStackTodo` again. Deadline and every other field
    /// survive — the user is unscheduling, not editing the intent.
    /// Single source of truth for the put-back write; the detail page's
    /// "Put back to Todo" button and the canvas drag put-back peek both
    /// go through here (same shape as `absorbTodoIntoEvent`).
    func putTodoBackToStack(todoID: UUID) {
        guard var event = findCalendarEvent(id: todoID),
              event.canReturnToStack else { return }
        event.timeRanges = []
        updateCalendarEvent(event)
    }

    /// Absorb a `.todo` into a `.event` parent. Sets
    /// `absorbedIntoEventID`; auto-cascades isDone/status/completeAt
    /// when the parent has already ended (the event happened, so the
    /// intent happened with it). Idempotent — calling on an already-
    /// absorbed todo just overwrites the parent.
    ///
    /// Recurring parents skip the auto-cascade: the last range end
    /// on a series is the template's first occurrence, not the most
    /// recent one, so the "is it past?" check is wrong. Manual
    /// markdown still works; correct recurring auto-cascade is parked
    /// alongside the broader recurrence-semantics work.
    ///
    /// Single source of truth for absorption so both the detail-view
    /// picker path and the canvas drag-and-drop path go through the
    /// same write.
    func absorbTodoIntoEvent(todoID: UUID, parentEventID: UUID, now: Date = Date()) {
        // Contract per design Q2: only `.todo` absorbed into `.event`,
        // no nesting. Both ends asserted here so any future entry
        // point (Shortcuts, drag from outside the app, future drag
        // shapes) can't violate the model — silently bail rather than
        // produce a malformed relationship.
        guard let parent = findCalendarEvent(id: parentEventID),
              parent.kind == .event,
              let source = findCalendarEvent(id: todoID),
              source.kind == .todo else { return }
        guard mutateCalendarEvent(id: todoID, { todo in
            todo.absorbedIntoEventID = parentEventID
            // Render-frame "has the parent ended?" gate: a traveled
            // detached instance's raw end can sit a whole frame before the
            // slot the canvas draws it in — auto-completing a todo dropped
            // onto a block the user sees as upcoming (gh#208). Identity
            // for anything that never traveled.
            if !parent.isRecurringSeries,
               let parentEnd = parent.renderTimeRanges(calendar: .current).last?.end,
               parentEnd < now,
               !todo.isDone {
                todo.isDone = true
                todo.status = .completed
                todo.completeAt = now
            }
        }) else { return }
        saveCalendarEvents(refreshInterrupts: true)
        calendarTodoAbsorbed.send(parentEventID)
    }

    /// Clear `absorbedIntoEventID` on a todo. Doesn't un-mark done —
    /// release ≠ undo; the user can flip done state separately.
    func releaseTodoAbsorption(todoID: UUID) {
        guard mutateCalendarEvent(id: todoID, { $0.absorbedIntoEventID = nil }) else { return }
        saveCalendarEvents(refreshInterrupts: true)
    }

    /// Domino-push every `.todo` whose start sits past `now +
    /// horizonDays × 24h` forward by the elapsed time since the last
    /// push, so they stay at the same relative distance from horizon
    /// (= the canvas "park area" follows the user instead of decaying
    /// past them). First call just stamps the timestamp without
    /// moving anything — there's no last-push to diff against yet.
    ///
    /// Filters:
    ///   - kind == .todo (events are user commitments, never moved)
    ///   - absorbedIntoEventID == nil (absorbed todos live inside a
    ///     parent, are not independent canvas items)
    ///   - !isRecurringSeries (recurring is rule-defined; shifting
    ///     timeRanges is the wrong mutation — recurring todos parked
    ///     until the recurring-events rework lands, issue #5)
    ///
    /// `horizonDays` is passed in (read from AppStorage by the caller
    /// in DoneApp) rather than re-read here, so unit tests can supply
    /// it and the store stays free of settings-key coupling.
    /// Smallest elapsed delta that is worth a push (and therefore worth a
    /// full rewrite of the calendar blob). Far below the 900s foreground
    /// tick cadence, so the visible cadence is unchanged; large enough to
    /// collapse the duplicate launch-time call.
    static let dominoMinimumPushInterval: TimeInterval = 60

    /// The legacy home of the last-push stamp. Read once at load during the
    /// migration window so an upgrading user does not lose the accumulated
    /// delta; never written again.
    static let legacyDominoLastPushKey = "calendarDominoLastPushTime"

    /// Versioned one-shot gate for `healLegacyAllDayStraddlesOnce` (gh#207).
    /// The stored integer is the highest heal pass this install has
    /// completed; a launch runs the pass only while the stored value is
    /// below `legacyAllDayStraddleHealVersion`. Bumping the constant
    /// re-arms the scan for every install exactly once — the same
    /// UserDefaults-resident shape as `legacyDominoLastPushKey`, on the
    /// store's injected `defaults` so tests control it.
    static let legacyAllDayStraddleHealVersionKey = "calendarLegacyAllDayStraddleHealVersion"
    static let legacyAllDayStraddleHealVersion = 1

    /// Both durable sources state the same kind of fact — "as of this moment,
    /// every past-horizon todo was aligned" — so the newer one is simply the
    /// stronger statement, and `max` is the right combination.
    ///
    /// The envelope stamp is written with the rows it describes, in one
    /// `rename`; the heartbeat file exists only so a no-op tick does not cost
    /// a 1.25 MB rewrite. Under every kill point the worst outcome is an OLD
    /// stamp, which under-pushes — visible, harmless, self-correcting. The
    /// dangerous direction (a lost stamp re-applying the whole elapsed delta
    /// to already-shifted todos, silently moving user dates) is unreachable.
    ///
    /// "Unreachable" holds only because NO calendar write may drop the stamp:
    /// the heartbeat is legitimately allowed to lag the envelope (a real push
    /// updates the envelope and not the heartbeat), so an envelope written
    /// with `nil` would fall back to a stale heartbeat and re-push. That is
    /// enforced in `dominoStampToCommit`, not by call sites remembering.
    private func resolveDominoLastPush() -> Date? {
        var best: Date? = loadedDominoStamp
        if let beat = storage.readDominoHeartbeat() {
            best = max(best ?? beat, beat)
        }
        if best == nil, storage.legacyDefaults != nil {
            let raw = defaults.double(forKey: Self.legacyDominoLastPushKey)
            if raw > 0 {
                let legacy = Date(timeIntervalSince1970: raw)
                best = legacy
                // Carry it across immediately, so the very next launch does not
                // depend on the legacy key still being there.
                try? storage.writeDominoHeartbeat(legacy)
            }
        }
        return best
    }

    func dominoPushTodosPastHorizon(now: Date = Date(), horizonDays: Int) {
        guard let last = dominoLastPushEffective else {
            dominoLastPushEffective = now
            try? storage.writeDominoHeartbeat(now)
            return
        }
        let delta = now.timeIntervalSince(last)
        guard delta > 0 else { return }
        // Sub-threshold deltas are visually meaningless (<1pt at the
        // default 60pt/h) and each one costs a full re-encode plus a
        // full rewrite of the entire calendar blob — on the launch path
        // this fires TWICE, because `.onAppear` and the launch
        // `.onChange(of: scenePhase)` both call
        // `handleDominoScenePhase(.active)` a few hundred ms apart.
        //
        // Returning WITHOUT stamping `lastPushKey` is lossless by
        // construction: the push is always computed relative to `last`,
        // and the distance-from-horizon invariant documented below holds
        // for any delta length, so deferring half a second of drift to
        // the next call produces the identical end state. The threshold
        // trades write frequency against push latency, never data.
        //
        // The nonce still bumps so the horizon line / partial-day tint
        // redraw behaviour is unchanged.
        guard delta >= Self.dominoMinimumPushInterval else {
            dominoTickNonce &+= 1
            return
        }
        // Filter against the horizon AS OF the last push, NOT the
        // current horizon.  A todo that was past horizon at last push
        // (and therefore got shifted to stay there) might, after a long
        // background gap, sit BEFORE the current horizon — because
        // horizon advanced during the gap while we were silent.  Using
        // the current horizon as the filter would silently abandon
        // that todo (it's now "near-future" by current standards, even
        // though the user parked it as "future" and never touched it).
        // Using horizon-as-of-last-push catches it: it was past then,
        // it deserves the catch-up delta now.  Distance from horizon is
        // preserved: `new_start − new_horizon = old_start − old_horizon`
        // for any delta length, because `EventZone.horizonDate` does
        // pure-seconds arithmetic — `horizonNow − horizonAtLast == delta`
        // exactly, including across DST transitions.
        let horizonAtLast = EventZone.horizonDate(from: horizonDays, now: last)
        var pushedCount = 0
        for i in rawCalendarEvents.indices {
            let event = rawCalendarEvents[i]
            // `firstStart >= horizonAtLast` (not strict `>`): a todo at
            // exactly the boundary should be in the future group too.
            // Multi-range todos: chronological-ascending order assumed
            // (the only multi-range path today is cross-day events
            // which are chronological by construction); the shift
            // mutates ALL ranges uniformly so internal timing stays
            // consistent.
            guard event.kind == .todo,
                  event.absorbedIntoEventID == nil,
                  !event.isRecurringSeries,
                  let firstStart = event.timeRanges.first?.start,
                  firstStart >= horizonAtLast else { continue }
            rawCalendarEvents[i].timeRanges = event.timeRanges.map { range in
                Event.TimeRange(
                    start: range.start.addingTimeInterval(delta),
                    end: range.end.addingTimeInterval(delta)
                )
            }
            pushedCount += 1
        }
        dominoLastPushEffective = now
        if pushedCount > 0 {
            // The stamp rides with the rows it describes, in the same commit.
            saveCalendarEvents(refreshInterrupts: true)
        } else {
            // Nothing moved: an 8-byte heartbeat, not a 1.25 MB rewrite.
            try? storage.writeDominoHeartbeat(now)
        }
        dominoTickNonce &+= 1
    }
    @Published var calendarEventFeedbackRecords: [CalendarEventFeedbackRecord] = [] {
        didSet { feedbackRecordIndexByKey = nil }   // see `rawCalendarEvents`
    }
    @Published var calendarEventLogRecords: [CalendarEventLogRecord] = [] {
        didSet { logRecordIndexByKey = nil }        // see `rawCalendarEvents`
    }

    @Published var todoLists: [TodoList] = []
    /// People that can be bound to events (the "with whom" of an event).
    /// App-local; deletion is a soft-archive so historical events still
    /// resolve a name. See `Person`.
    @Published var people: [Person] = []
    /// Named quick-select templates for the people picker. See `FriendGroup`.
    @Published var friendGroups: [FriendGroup] = []
    /// Lightweight Apple-Reminders-style todos shown in the calendar's
    /// pull-down panel. App-local (not cloud-synced). See `Reminder`.
    @Published var reminders: [Reminder] = []

    let calendarEventRecorded = PassthroughSubject<Event, Never>()
    /// Fires the parent's event id every time a todo is absorbed into
    /// it. Subscribed in TimelinePagerView; the matched parent ID is
    /// pushed into CalendarDayLayerView via the
    /// `recentlyAbsorbedEventIDs` set, where the per-event pulse
    /// driver edge-detects it — useful so the pulse still fires
    /// when the user picker-absorbed while the canvas was covered
    /// (returning to canvas catches the recent-id membership and
    /// animates). Survives view recreations the way `.onChange` on
    /// the count prop doesn't.
    let calendarTodoAbsorbed = PassthroughSubject<UUID, Never>()
    let calendarEventLogChanged = PassthroughSubject<CalendarEventOccurrenceContext, Never>()
    let calendarEventFeedbackChanged = PassthroughSubject<CalendarEventOccurrenceContext, Never>()

    /// Migration source and the home of `calendarDominoLastPushTime` before
    /// this change. Event arrays are no longer read from or written to it —
    /// see `DurableEventStorage`.
    private let defaults: UserDefaults
    let storage: DurableEventStorage

    /// Slots that could not be read. A slot in here is FROZEN: every save to
    /// it is refused, because the store's in-memory copy is empty (or stale)
    /// and writing it down would destroy the file we could not read. Per-slot,
    /// not global — a damaged `people.json` must not stop the calendar from
    /// being written.
    @Published private(set) var storageFaults: [StorageSlot: SlotFault] = [:]
    /// Slots whose last write attempt failed. PER-SLOT for the same reason
    /// `storageFaults` is: while a global flag was fine for raising the
    /// banner, ANY other slot's successful save cleared it — and the small
    /// slots (`reminders`, `todoLists`, `people`) save constantly, so a
    /// calendar that could not be written stopped warning within seconds
    /// while the user kept working. A slot leaves this set only when that
    /// same slot is written successfully.
    @Published private(set) var writeFailedSlots: Set<StorageSlot> = []
    /// A write failed, or a slot is frozen. UI shows a persistent banner; the
    /// user must not find out by losing work. Derived — never assigned
    /// directly, so it cannot drift from the two sets it summarises.
    @Published private(set) var persistenceDegraded = false

    private func refreshPersistenceDegraded() {
        let degraded = !storageFaults.isEmpty || !writeFailedSlots.isEmpty
        if persistenceDegraded != degraded { persistenceDegraded = degraded }
    }

    /// `seedsSampleDataIfEmpty`: when true (production default), an empty store
    /// is populated with today-relative demo events on first load. Tests that
    /// need a deterministic, empty store (and to avoid today-relative seed data)
    /// pass `false`.
    private let seedsSampleDataIfEmpty: Bool

    /// Last time every past-horizon todo was known to be aligned, from
    /// whichever of the two durable sources is newer. See
    /// `dominoPushTodosPastHorizon`.
    private var dominoLastPushEffective: Date?

    private var widgetSnapshotDebounceTask: Task<Void, Never>?
    private var widgetSnapshotBackgroundCancellable: AnyCancellable?

    /// Pending effort→`colorDepth` mirror writes, keyed by event id, newest
    /// value per event (gh#201 fix 3). Empty at rest.
    private var pendingColorDepthMirror: [UUID: Double] = [:]
    private var colorDepthMirrorDebounceTask: Task<Void, Never>?
    private var lastWrittenSnapshotHash: Int?

    /// Fires once per slot whose commit actually reached disk, in commit
    /// order. Exists so the ordering invariant this store now owns — the
    /// authoritative calendar state commits BEFORE any irreversible side
    /// effect — is observable, and therefore testable, instead of being a
    /// property only the source order asserts.
    var onSlotCommitted: ((StorageSlot) -> Void)?

    /// Fires once per `prefilledDraft(for:)` computation. Exists so "one
    /// draft per detail-view body pass" (gh#213 change A) is an observable
    /// property rather than one only the source shape asserts — the four
    /// `quick*` computed properties that used to front the draft each
    /// recomputed it, and nothing but a count can tell that apart from
    /// threading one value down.
    ///
    /// Per-INSTANCE, not a global counter, deliberately: `DoneTests` is a
    /// host-app bundle, so the app's own `EventStore` is alive in the same
    /// process and a global would also count its views' reads.
    var onPrefilledDraftComputed: ((CalendarEventOccurrenceContext) -> Void)?

    /// Fires once per `CalendarEventDetailView.pagerContent` evaluation —
    /// one call per detail BODY PASS. Two consumers now (S5): the render
    /// test, which pairs it with draft counts so `drafts <= passes` is an
    /// invariant instead of a constant (the first version asserted
    /// `drafts <= 8` against measurements of 2 hoisted and 13 un-hoisted,
    /// and un-hoisting a single section produced 6, which walked straight
    /// through — a bound tied to SwiftUI's pass count is a revert
    /// detector; the pairing is a regression detector); and the Fix Watch
    /// resident, whose `activate()` assigns BOTH per-instance seams
    /// unconditionally and is the app process's single writer of them —
    /// see the note at that assignment in ResidentObservationCenter.swift.
    ///
    /// Per-INSTANCE for the same reason as `onPrefilledDraftComputed`.
    var onDetailBodyPass: ((CalendarEventOccurrenceContext) -> Void)?

    /// The one place image files are actually unlinked, behind a seam so a
    /// test can record WHEN it happens relative to `onSlotCommitted`.
    /// Deleting a file is the only step in a delete that cannot be undone by
    /// re-running it, which is why it is the last one.
    var removeAssetFiles: ([AgenticIntakeImageRef]) -> Void = { refs in
        AgenticIntakeAssetStore().removeAssets(for: refs)
    }

    /// The app's one request for a WidgetKit timeline refresh, behind a seam
    /// so a test can COUNT reload requests instead of trusting the write path
    /// by inspection — each request spends WidgetKit refresh budget (gh#219),
    /// so "fires no reload" is an assertable property, not a comment.
    /// Narrowest possible injection point: production behavior is exactly the
    /// direct call this replaces. Per-instance like the other seams here,
    /// because `DoneTests` is a host-app bundle and the app's own store lives
    /// in the same process.
    var reloadWidgetTimelines: () -> Void = { WidgetCenter.shared.reloadAllTimelines() }

    /// Whether this store owns the shared asset directory and may sweep it.
    /// False for every test location: `DoneTests` runs inside the host app's
    /// container, so a sweep from a test would delete the dogfood user's
    /// photos — the exact hazard `EventStorageLocation` exists to prevent.
    private let sweepsOrphanedAssetsOnLaunch: Bool

    /// The civil frame `healLegacyAllDayStraddlesOnce` judges stored ranges
    /// in. Production default is the device's current calendar — the frame
    /// the straddled rows were almost certainly minted in (a user who
    /// changed zones since simply isn't healed at rest, conservatively;
    /// the snap-side rule still heals on re-save). Injectable so tests can
    /// pin a DST fixture zone instead of inheriting the host's.
    private let straddleHealCalendar: Calendar

    /// `storage` has NO default value on purpose. `DoneTests` is a host-app
    /// bundle, so a forgotten location would silently mean "the real store" —
    /// and a test run would read and write the dogfood user's calendar. A
    /// missing argument has to be a compile error.
    init(defaults: UserDefaults = .standard,
         storage location: EventStorageLocation,
         seedsSampleDataIfEmpty: Bool = true,
         straddleHealCalendar: Calendar = .current) {
        self.defaults = defaults
        self.seedsSampleDataIfEmpty = seedsSampleDataIfEmpty
        self.straddleHealCalendar = straddleHealCalendar
        self.sweepsOrphanedAssetsOnLaunch = location.ownsSharedAssetDirectory
        self.storage = DurableEventStorage(
            location: location,
            legacyDefaults: location.migratesLegacyDefaults ? defaults : nil
        )
        // Before `load()`, which arms the first debounced widget sync: the
        // hash guard must already know what the App Group holds by the time
        // that sync compares against it (gh#219 — see the seed's doc).
        seedWidgetSnapshotHashFromAppGroup()
        load()
        scheduleStartupOrphanAssetSweep()
        // Flush the debounced snapshot on every "the app may stop running"
        // edge, not just `didEnterBackground`.  `willResignActive` fires FIRST,
        // and there are interruptions where background never follows at all —
        // a call banner, Control Center, the notification shade — so it is the
        // earliest point at which the pending payload is worth spending.
        // `willTerminate` is kept as best-effort only: the system does NOT call
        // it when it reclaims an already-suspended app, so nothing may depend
        // on it.  All three land on the same idempotent flush; the payload hash
        // makes a redundant one a no-op.
        widgetSnapshotBackgroundCancellable = Publishers.MergeMany(
            NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification),
            NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification),
            NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)
        )
        .sink { [weak self] note in
            // Before the widget flush, but NOT for payload freshness: an
            // earlier comment here claimed the widget payload would go
            // stale, and it cannot — `SharedEventSnapshot` has no
            // `colorDepth` field (`git grep -n colorDepth -- Shared/`
            // returns nothing), so a mirror commit changes no byte the
            // widget ever sees.
            //
            // The real reason is the task this ordering disarms. The
            // colour-depth flush commits through `saveCalendarEvents`, and
            // that ARMS `scheduleWidgetSnapshotSync` — a fresh 250 ms
            // `Task.sleep`. Running the mirror FIRST means the
            // `flushWidgetSnapshotSync()` on the next line cancels that
            // task and syncs synchronously. Running it second would leave a
            // just-armed sleeping task behind at a suspend the system is
            // free never to resume. See
            // `flushCalendarEventColorDepthMirror`.
            self?.flushCalendarEventColorDepthMirror()
            self?.flushWidgetSnapshotSync()
            // The only place a full flush-to-media happens — background, not
            // the two lighter edges. Off the save path deliberately: the
            // observed failure is process death, which `write(2)` already
            // survives, and this app is under an open frame-drop
            // investigation.
            if note.name == UIApplication.didEnterBackgroundNotification {
                self?.storage.syncDirectoryToStableStorage()
            }
        }
    }

    func load() {
        replayPendingRestoreIfNeeded()

        events = adopt(.events, as: Event.self)
        rawCalendarEvents = adopt(.calendarEvents, as: Event.self)
        // Dedup on load so a blob written by an older app version (which could
        // persist duplicate-identity rows from a cloud overwrite) is healed
        // rather than carried forward. See issue #26 / `dedupedByIdentity`.
        calendarEventFeedbackRecords = dedupedByIdentity(
            adopt(.calendarEventFeedbackRecords, as: CalendarEventFeedbackRecord.self),
            id: { $0.id }, updatedAt: { $0.updatedAt }
        )
        calendarEventLogRecords = dedupedByIdentity(
            adopt(.calendarEventLogRecords, as: CalendarEventLogRecord.self),
            id: { $0.id }, updatedAt: { $0.updatedAt }
        )
        todoLists = adopt(.todoLists, as: TodoList.self)
        people = adopt(.people, as: Person.self)
        friendGroups = adopt(.friendGroups, as: FriendGroup.self)
        reminders = adopt(.reminders, as: Reminder.self)
        pruneStaleReminders()

        dominoLastPushEffective = resolveDominoLastPush()

        // Placement: after the Domino stamp resolution, before anything
        // derives from the calendar array. The ordering is defense-in-depth
        // for the stamp, not the sole guard: `dominoStampToCommit` already
        // falls back to the on-disk envelope stamp when the in-memory one
        // is nil, so a save from here could not mint a nil stamp even if
        // this ran earlier. Belt (this ordering) and suspenders (the funnel
        // fallback) — neither may be removed on the strength of the other
        // alone.
        healLegacyAllDayStraddlesOnce()

        // Three gates, all required. `.isEmpty` alone used to be the whole
        // condition, and under UserDefaults "empty" only meant absent-or-
        // corrupt. Now it can also mean "the file could not be read this
        // once" — and seeding calls `addCalendarEvent`, which SAVES. One
        // transient read failure would have overwritten 2690 events with six
        // demo rows.
        if seedsSampleDataIfEmpty && rawCalendarEvents.isEmpty && isSeedable(.calendarEvents) {
            seedSampleCalendarEvents()
        }
        migrateOrphanEvents()
        // The other half of the durability trail: compare this against the last
        // `save calendar:` line of the previous run. A lower count here than
        // there means the final write never survived the process exit.
        recordPersistence(
            "load: calendar=\(rawCalendarEvents.count) todo=\(events.count) logs=\(calendarEventLogRecords.count) feedback=\(calendarEventFeedbackRecords.count)"
            + " provenance=\(slotProvenance[.calendarEvents]?.rawValue ?? "none")"
            + " seq=\(slotSeq[.calendarEvents] ?? 0)"
            + (storageFaults.isEmpty ? "" : " FAULTS=\(storageFaults.keys.map(\.rawValue).sorted().joined(separator: ","))")
        )
        // LAST, deliberately. It mutates nothing (see the doc comment for why
        // the destructive arm is parked), but it must judge the settled arrays:
        // the restore replay has run, the decode normalization is applied, the
        // record slots are deduped, and the durability trail line above is
        // already written so its counts sit above the sweep's own lines rather
        // than in the middle of them.
        sweepZombieRecurringSeries()
        scheduleWidgetSnapshotSync()
    }

    // MARK: - Orphaned image files

    /// Every image file path the durable rows still point at.
    ///
    /// Both producers, exhaustively: events attach images through
    /// `agenticIntake` (the todo array and the calendar array alike), and log
    /// records attach them to timeline notes. `feedbackRecords` holds
    /// `CalendarEventLogEntry`, which has no image field — it is a parameter
    /// anyway so that a slot gaining one lands HERE, in the function whose job
    /// is to know all of them, instead of silently making the sweep treat
    /// those photos as abandoned.
    static func referencedAssetRelativePaths(
        events: [Event],
        calendarEvents: [Event],
        logRecords: [CalendarEventLogRecord],
        feedbackRecords: [CalendarEventFeedbackRecord]
    ) -> Set<String> {
        var paths = Set<String>()
        for event in events + calendarEvents {
            for image in event.agenticIntake?.images ?? [] {
                paths.insert(image.relativePath)
            }
        }
        for record in logRecords {
            for note in record.timelineItems.compactMap(\.noteValue) {
                for image in note.images {
                    paths.insert(image.relativePath)
                }
            }
        }
        return paths
    }

    /// Why this launch must NOT sweep the asset directory, or `nil` if the
    /// reference set it would hand the collector is provably complete.
    ///
    /// The counterpart to committing rows before unlinking files (issue #145).
    /// Ordering guarantees the app never destroys a photo an event still
    /// needs; the sweep guarantees the leftovers do not accumulate forever —
    /// and this is the whole of what keeps the sweep itself from becoming the
    /// data loss it was built to clean up after. Every refusal is a case where
    /// rows are missing from a healthy-LOOKING store, which makes their photos
    /// read as abandoned:
    ///
    /// 1. Any storage fault this launch — a slot that could not be read
    ///    contributes no paths, and its events' photos would look orphaned.
    /// 2. Any slot served from something other than its own committed primary.
    ///    A backup promotion is the sharp case: `DurableEventStorage` recovers
    ///    a corrupt or missing primary from the `.bak` hardlink, which is the
    ///    PREVIOUS generation, and it does that WITHOUT raising a fault — the
    ///    recovery worked, nothing is frozen, the banner stays down. Every row
    ///    written in the lost generation is simply absent, so gate 1 is blind
    ///    to it and gate 3 (the store is not empty) passes on the survivors.
    ///    The event itself is still recoverable from the quarantined primary;
    ///    its local-only photo would not be. `.legacyMigrated` is refused by
    ///    the same rule — that content is a migration-time snapshot, and one
    ///    skipped sweep on the migrating launch costs nothing.
    /// 3. A store with nothing in it at all. A genuinely empty install has no
    ///    files either, so skipping costs nothing; a store that came up empty
    ///    for any other reason must not take the assets with it.
    ///
    /// Every slot is checked, not just the four that hold image references, so
    /// that a slot which GAINS an image field is covered on the day it does —
    /// same reasoning as `referencedAssetRelativePaths` taking a parameter it
    /// does not read yet. Refusing too often only delays reclaiming disk; the
    /// sweep runs again on the next healthy launch.
    ///
    /// Exposed (rather than inlined into the guard) because the sweep itself
    /// never runs under XCTest — `ownsSharedAssetDirectory` is false at every
    /// test location, deliberately — so this decision is the only part of it a
    /// test can reach, and it is the part that can destroy a photo.
    var startupOrphanAssetSweepRefusal: String? {
        if !storageFaults.isEmpty {
            return "storage faults this launch: \(frozenSlotNames)"
        }
        let degraded = slotProvenance
            .filter { $0.value != .primary }
            .map { "\($0.key.rawValue)=\($0.value.rawValue)" }
            .sorted()
        if !degraded.isEmpty {
            return "slot did not come from its committed primary: \(degraded.joined(separator: ","))"
        }
        if rawCalendarEvents.isEmpty && events.isEmpty && calendarEventLogRecords.isEmpty {
            return "no rows loaded"
        }
        return nil
    }

    /// Sweep image files a killed delete left behind, once per launch, off the
    /// critical path. Refusals live in `startupOrphanAssetSweepRefusal`.
    private func scheduleStartupOrphanAssetSweep() {
        guard sweepsOrphanedAssetsOnLaunch else { return }
        if let refusal = startupOrphanAssetSweepRefusal {
            DiagnosticTrail.record("AssetGC", "skipped: \(refusal)")
            return
        }
        let referenced = Self.referencedAssetRelativePaths(
            events: events,
            calendarEvents: rawCalendarEvents,
            logRecords: calendarEventLogRecords,
            feedbackRecords: calendarEventFeedbackRecords
        )
        // Detached and at background priority: it is a directory walk on the
        // launch path, and nothing waits on its result.
        Task.detached(priority: .background) {
            let outcome = AgenticIntakeAssetGarbageCollector()
                .sweep(referencedRelativePaths: referenced)
            guard outcome.scannedFiles > 0 else { return }
            DiagnosticTrail.record("AssetGC", outcome.summary)
            for path in outcome.deletedRelativePaths.prefix(50) {
                DiagnosticTrail.record("AssetGC", "deleted \(path)")
            }
        }
    }

    /// Where each slot's content came from this launch, and which generation
    /// it was. Forensic only — but it is what lets a device trail answer
    /// "was this a stale read, a recovery, or a fresh migration?" without
    /// guessing.
    private(set) var slotProvenance: [StorageSlot: StorageProvenance] = [:]
    private(set) var slotSeq: [StorageSlot: UInt64] = [:]
    private var seedableSlots: Set<StorageSlot> = []

    /// Turn one slot's read outcome into rows, and record everything the rest
    /// of the store needs to know about how it went.
    private func adopt<Row: Codable>(_ slot: StorageSlot, as type: Row.Type) -> [Row] {
        let read = storage.read(slot, as: Row.self)

        // The ONE place a fault becomes store-level state. Deliberately keyed
        // off `storage.faults` rather than off the `.unreadable` case: those
        // two are not the same set. `read` can raise a fault and still hand
        // back rows — the directory-unavailable branch serves the frozen
        // legacy snapshot so the user sees *something*, and that snapshot is
        // a migration-time copy that may be months old. Reading the case
        // instead of the registry left the store believing that slot was
        // healthy: no banner, and `persist` free to write the stale array
        // back over the good file the moment the directory returned.
        if let fault = storage.faults[slot] {
            storageFaults[slot] = fault
            refreshPersistenceDegraded()
        }

        switch read {
        case .fresh:
            seedableSlots.insert(slot)
            return []
        case .loaded(let envelope, let provenance):
            slotProvenance[slot] = provenance
            slotSeq[slot] = envelope.header.seq
            // An intentionally-wiped slot is still seedable, which keeps
            // today's behaviour: after "erase all local data" the next launch
            // repopulates the demo events.
            if envelope.header.wiped && envelope.rows.isEmpty { seedableSlots.insert(slot) }
            if slot == .calendarEvents { loadedDominoStamp = envelope.header.dominoLastPush }
            if envelope.header.wiped { storage.purgeAuxiliaryCopies(for: slot) }
            return envelope.rows
        case .unreadable:
            // Already registered above — `read` never returns `.unreadable`
            // without raising.
            return []
        }
    }

    private var loadedDominoStamp: Date?

    private func isSeedable(_ slot: StorageSlot) -> Bool { seedableSlots.contains(slot) }

    /// True when `slot`'s in-memory value is not a faithful copy of the user's
    /// data — the read failed and left it empty, or it was served from the
    /// frozen legacy snapshot.
    ///
    /// THE predicate for "this array must not leave memory". It started life
    /// meaning only "do not write this file", which was the least important
    /// of the three exits: a frozen slot is empty precisely when the file is
    /// unreadable, i.e. exactly when the cloud copy and the local DR snapshot
    /// are the last two copies in existence. Both are overwritten from these
    /// same in-memory arrays within seconds — `BackupSnapshotService` on the
    /// next backgrounding, `SupabaseSyncService.diffSync` by DELETEing every
    /// id it no longer sees. So `BackupSnapshotService` and
    /// `SupabaseSyncService` ask this too. Do not re-derive an equivalent
    /// test at a call site; add the call site here.
    func isSlotFrozen(_ slot: StorageSlot) -> Bool { storageFaults[slot] != nil }

    /// Any slot at all. Used by exporters that write one document covering
    /// several slots, where a single frozen slot poisons the whole payload.
    var hasFrozenSlot: Bool { !storageFaults.isEmpty }

    /// For messages: which ones.
    var frozenSlotNames: String {
        storageFaults.keys.map(\.rawValue).sorted().joined(separator: ",")
    }

    /// Collapse records that are Swift-equal by occurrence `id` down to one,
    /// keeping the most recently updated. Cloud data can carry duplicate-
    /// identity rows (issue #26: occurrence-key encoding drift wrote multiple
    /// Supabase rows per logical record), and the local store must never hold
    /// more than one — `upsert*Record` matches by `==`, and downstream code
    /// like `RestoreCoordinator.diffByID` feeds these into
    /// `Dictionary(uniqueKeysWithValues:)`, which traps on a duplicate key.
    /// Applied wherever cloud rows enter the store wholesale (load of an older
    /// already-polluted blob, and the `.cloudOverwritesLocal` restore branch).
    private func dedupedByIdentity<T>(
        _ records: [T],
        id: (T) -> CalendarOccurrenceKey,
        updatedAt: (T) -> Date
    ) -> [T] {
        var byKey: [CalendarOccurrenceKey: T] = [:]
        var order: [CalendarOccurrenceKey] = []
        for record in records {
            let key = id(record)
            if let existing = byKey[key] {
                if updatedAt(record) >= updatedAt(existing) {
                    byKey[key] = record  // keep newest; first-seen order preserved
                }
            } else {
                byKey[key] = record
                order.append(key)
            }
        }
        return order.map { byKey[$0]! }
    }

    // Quarantining moved into `DurableEventStorage`, which renames the bad
    // file aside inside `EventStore/quarantine/` instead of copying bytes to
    // `Documents/`. Application Support is in device backup just the same, so
    // forensic recovery is unchanged — and unlike the old version, the
    // original is no longer left in place for the next save to overwrite.

    private func seedSampleCalendarEvents() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        func time(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(byAdding: .day, value: day, to: today)!
                .addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
        }

        let samples: [Event] = [
            Event(title: "Morning Focus", note: "Deep work session", location: "", timeRanges: [
                Event.TimeRange(start: time(0, 9), end: time(0, 11, 30))
            ], type: "Work"),
            Event(title: "Team Standup", note: "", location: "Zoom", timeRanges: [
                Event.TimeRange(start: time(0, 11, 30), end: time(0, 12))
            ], type: "Work"),
            Event(title: "Lunch Run", note: "5k around the park", location: "Park", timeRanges: [
                Event.TimeRange(start: time(0, 12, 30), end: time(0, 13, 30))
            ], type: "Exercise"),
            Event(title: "Design Review", note: "Review new feature mockups", location: "", timeRanges: [
                Event.TimeRange(start: time(0, 14), end: time(0, 15, 30))
            ], type: "Work"),
            Event(title: "Reading", note: "Chapters 5-7", location: "", timeRanges: [
                Event.TimeRange(start: time(0, 20), end: time(0, 21, 30))
            ], type: "Study"),
            Event(title: "Piano Practice", note: "", location: "Home", timeRanges: [
                Event.TimeRange(start: time(1, 8), end: time(1, 9))
            ], type: "Hobby"),
            Event(title: "Project Sprint", note: "Feature implementation", location: "", timeRanges: [
                Event.TimeRange(start: time(1, 10), end: time(1, 16))
            ], type: "Work"),
            Event(title: "Grocery Shopping", note: "", location: "Whole Foods", timeRanges: [
                Event.TimeRange(start: time(1, 17), end: time(1, 18))
            ], type: "Errand"),
            Event(title: "Yoga", note: "Vinyasa flow", location: "Studio", timeRanges: [
                Event.TimeRange(start: time(-1, 7), end: time(-1, 8))
            ], type: "Exercise"),
            Event(title: "Coffee Chat", note: "Catch up with Alex", location: "Café", timeRanges: [
                Event.TimeRange(start: time(-1, 10, 30), end: time(-1, 11, 30))
            ], type: "Social"),
        ]

        for event in samples {
            addCalendarEvent(event)
        }
    }

    /// gh#207 (R2): one-shot load-side normalization of rows the pre-gh#188
    /// all-day snap left straddled — `[startOfDay, next-day 00:59:59]` on a
    /// spring-forward day. The snap-side rule heals a row the user re-saves;
    /// this pass reaches the rows nobody ever touches again. Judgment is the
    /// SAME shared signature (`Event.legacyAllDayStraddleHealedEnd`) — one
    /// source, so the two remedies can never disagree about what a straddle
    /// is. Non-all-day rows and non-matching ranges ride through untouched,
    /// and a healed row can't match again, so re-running is a no-op even
    /// without the version gate.
    ///
    /// Gate: versioned one-shot (`legacyAllDayStraddleHealVersionKey`).
    /// The flag marks the pass done for this install; ingress AFTER it —
    /// a Supabase restore replays raw rows with no normalization — can
    /// re-introduce straddles that then wait for a re-save (snap-side rule)
    /// or a version bump. The flag is only advanced when this launch's
    /// calendar slot actually read healthily and any heal actually reached
    /// disk; a faulted read or refused write leaves it unset so the next
    /// launch retries.
    private func healLegacyAllDayStraddlesOnce() {
        guard defaults.integer(forKey: Self.legacyAllDayStraddleHealVersionKey)
                < Self.legacyAllDayStraddleHealVersion else { return }
        guard storageFaults[.calendarEvents] == nil else { return }

        var healedRows = 0
        for i in rawCalendarEvents.indices where rawCalendarEvents[i].isAllDay {
            var ranges = rawCalendarEvents[i].timeRanges
            var changed = false
            for j in ranges.indices {
                guard let healedEnd = Event.legacyAllDayStraddleHealedEnd(
                    start: ranges[j].start,
                    end: ranges[j].end,
                    calendar: straddleHealCalendar
                ) else { continue }
                ranges[j].end = healedEnd
                changed = true
            }
            if changed {
                rawCalendarEvents[i].timeRanges = ranges
                healedRows += 1
            }
        }

        if healedRows > 0 {
            guard saveCalendarEvents() else { return }
            DiagnosticTrail.record(
                "StraddleHeal",
                "healed \(healedRows) all-day row(s) to previous-civil-day end (v\(Self.legacyAllDayStraddleHealVersion))"
            )
        }
        defaults.set(Self.legacyAllDayStraddleHealVersion,
                     forKey: Self.legacyAllDayStraddleHealVersionKey)
    }

    private func migrateOrphanEvents() {
        let orphans = events.filter { $0.listID == nil }
        guard !orphans.isEmpty else { return }

        // Create a default list if none exists yet
        if todoLists.isEmpty {
            let defaultList = TodoList(title: "Default", colorName: "blue")
            todoLists.append(defaultList)
            saveTodoLists()
        }

        let targetListID = todoLists[0].id
        for i in events.indices where events[i].listID == nil {
            events[i].listID = targetListID
        }
        save()
    }

    /// One write path for all eight slots.
    ///
    /// Two rules it enforces that the old code did not:
    ///
    /// 1. A frozen slot is never written. Its in-memory array is empty or
    ///    stale because the read failed; writing it would replace a file we
    ///    could not read with one we know is wrong.
    /// 2. A failed write leaves the previous file EXACTLY as it was. The old
    ///    code did `defaults.removeObject(forKey:)` in the encode-failure
    ///    path — one encoding error destroyed the entire array. Nothing here
    ///    deletes anything on failure; `rename` guarantees the target is
    ///    untouched unless the whole new file made it to disk.
    @discardableResult
    private func persist<Row: Codable>(_ rows: [Row], to slot: StorageSlot,
                                       wiped: Bool = false,
                                       intent: WriteIntent = .normal,
                                       verbose: Bool = false) -> Bool {
        guard !isSlotFrozen(slot) else {
            recordPersistenceError("save \(slot.rawValue) REFUSED: slot is frozen (\(String(describing: storageFaults[slot])))")
            return false
        }
        do {
            let receipt = try storage.commit(rows, to: slot,
                                             dominoLastPush: dominoStampToCommit(for: slot, wiped: wiped),
                                             wiped: wiped, intent: intent)
            if verbose && !receipt.skipped {
                recordPersistence(
                    "save \(slot.rawValue): seq=\(receipt.seq) count=\(receipt.rowCount)"
                    + " bytes=\(receipt.bytes) onDisk=\(receipt.onDiskBytes)"
                    + " encodeMs=\(receipt.encodeMs) writeMs=\(receipt.writeMs) syncMs=\(receipt.syncMs)"
                )
            }
            // A skipped commit performed no I/O at all, so it is no evidence
            // that whatever failed the earlier write (no space, unwritable
            // container) has cleared. Only a real write clears the warning.
            if !receipt.skipped {
                writeFailedSlots.remove(slot)
                refreshPersistenceDegraded()
                onSlotCommitted?(slot)
            }
            return true
        } catch {
            recordPersistenceError(
                "save \(slot.rawValue) FAILED, previous file intact: \(String(describing: error))"
            )
            writeFailedSlots.insert(slot)
            refreshPersistenceDegraded()
            // An ENCODE failure is a code bug, not an environment problem, and
            // it used to be swallowed AND take the whole array with it. I/O
            // failures (no space, read-only container) are real conditions the
            // user can hit, so those only degrade.
            if error is EncodingError {
                assertionFailure("EventStore.persist(\(slot.rawValue)) encode failed: \(error)")
            }
            return false
        }
    }

    /// The Domino last-push stamp that a `.calendarEvents` commit must carry.
    ///
    /// Computed HERE, by the one write path, rather than handed in by each
    /// call site. Hand-copying it at the call sites is how it got lost: the
    /// restore replay runs inside `load()`, *before*
    /// `dominoLastPushEffective` has been resolved, so it had nothing to pass
    /// and committed `nil` — wiping the only authoritative copy of a stamp
    /// the heartbeat file may legitimately lag behind (a real push writes the
    /// envelope and NOT the heartbeat). The next tick then re-applied the
    /// whole elapsed delta to todos that had already been shifted, which is
    /// the silent permanent date corruption `SlotEnvelopeHeader.dominoLastPush`
    /// exists to prevent. Any future calendar write would have had the same
    /// hole.
    ///
    /// `max` of the in-memory value and what is already on disk, so a write can
    /// only ever move the stamp forward — erring old under-pushes (visible,
    /// self-correcting), erring new double-pushes (silent, permanent).
    /// A wipe is the one intentional reset, and clears it.
    private func dominoStampToCommit(for slot: StorageSlot, wiped: Bool) -> Date? {
        guard slot == .calendarEvents, !wiped else { return nil }
        guard let onDisk = storage.persistedDominoStamp() else { return dominoLastPushEffective }
        guard let effective = dominoLastPushEffective else { return onDisk }
        return max(effective, onDisk)
    }

    func save() {
        persist(events, to: .events)
    }

    /// Returns whether the commit reached disk. Callers that follow a save
    /// with an irreversible side effect (unlinking image files) must check it:
    /// a refused/failed calendar commit means the event is still durable, and
    /// its photos must stay on disk with it.
    @discardableResult
    private func saveCalendarEvents() -> Bool {
        let committed = persist(rawCalendarEvents, to: .calendarEvents, verbose: true)
        scheduleWidgetSnapshotSync()
        return committed
    }

    /// Coalesce bursty save→widget-sync calls; one sync per ~250ms quiet window.
    ///
    /// The 250ms is a *staleness* window, not a durability hole: a process death
    /// inside it loses only the widget projection, never user data, and the next
    /// `load()` re-schedules a sync — so the blob self-heals on the next launch.
    /// The lifecycle flushes in `init` close the ordinary exit paths.
    private func scheduleWidgetSnapshotSync() {
        widgetSnapshotDebounceTask?.cancel()
        widgetSnapshotDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.syncWidgetSnapshots()
            self.widgetSnapshotDebounceTask = nil
        }
    }

    func flushWidgetSnapshotSync() {
        widgetSnapshotDebounceTask?.cancel()
        widgetSnapshotDebounceTask = nil
        syncWidgetSnapshots()
    }

    /// How long the effort→`colorDepth` mirror waits for more effort changes
    /// before committing. Same 250 ms as `scheduleWidgetSnapshotSync`, and
    /// deliberately so — see `scheduleCalendarEventColorDepthMirror` for why
    /// this window is a different kind of risk from that one and why it is
    /// still safe.
    static let colorDepthMirrorCoalesceWindow: Duration = .milliseconds(250)

    /// Queue the event's `colorDepth` mirror of a log record's effort, to be
    /// committed once the user stops changing it (gh#201 fix 3).
    ///
    /// This used to run inside `upsertLogRecord`, on the tap's own turn:
    /// mutate `rawCalendarEvents` (an `@Published` array, so every day column
    /// re-applies) and then re-encode and re-commit the WHOLE calendar-events
    /// slot. On device that mirror alone accounted for ~30 ms of an ~82 ms
    /// synchronous commit per effort tap, one full `saveCalendarEvents`, and
    /// every day-layer apply.
    ///
    /// Why deferring this is not a durability hole, spelled out because the
    /// answer is NOT the same as the widget debounce's:
    ///
    /// * What the user typed is already durable. The effort itself lives in
    ///   the log record, which `upsertLogRecord` commits synchronously via
    ///   `saveCalendarEventLogRecords()` on the same turn. `colorDepth` is a
    ///   PROJECTION of that value, kept on the event so the canvas tint can
    ///   be drawn without a record lookup. Losing the projection loses no
    ///   user input.
    /// * The ordinary exit paths flush it. The same three lifecycle edges the
    ///   widget flush hangs off (`willResignActive`, `didEnterBackground`,
    ///   `willTerminate`) flush this first — and `willResignActive` fires
    ///   before every backgrounding, app-switcher kill and interruption, so
    ///   an app that stops running through any of those routes has already
    ///   committed.
    /// * What is left is a crash (or an out-of-nowhere jetsam of a FOREGROUND
    ///   app) inside the window: the event's stored `colorDepth` keeps its
    ///   previous value while the log record shows the new effort. An
    ///   earlier version of this bullet called that "a wrong bar WIDTH on
    ///   one block", which understates it twice.
    ///
    ///   First, the previous value is 0 for the FIRST effort ever recorded
    ///   on an event (`Event.colorDepth(forEffort: nil) == 0`), and all four
    ///   render sites gate on `if event.colorDepth > 0`
    ///   (`git grep -n 'colorDepth > 0'`: `CalendarEventDetailView`,
    ///   `CalendarDayLayerView`, `EventBlock`, `MiniDayTimelineLayerView`).
    ///   So the lost projection is not a wrong bar, it is NO BAR — visually
    ///   identical to "no effort recorded" while the log record says
    ///   otherwise.
    ///
    ///   Second, `colorDepth` is not only the bar. It also feeds
    ///   `Event.colorOpacityMultiplier`, which `CalendarLayout.eventColor`
    ///   applies as the block's fill opacity on a 0.4–1.0 scale under a
    ///   setting that defaults to true — and depth 0 there falls back to the
    ///   unlogged default 0.5 (opacity 0.7) rather than the effort's own
    ///   value, so the block's TINT is wrong too.
    ///
    ///   Two more things about the window's shape, both worth stating
    ///   because "250 ms" reads narrower than it is. The debounce task is
    ///   cancelled and re-armed by every change that gets queued below, so a
    ///   burst of edits is exposed for the whole burst PLUS 250 ms, not
    ///   250 ms. And ONE shared task serves every event, so an event's
    ///   pending write is pushed out by any later queued change on any other
    ///   event.
    ///
    ///   Nothing here re-derives the projection at load, so it is not
    ///   self-healing (it is corrected the next time that occurrence's
    ///   effort is edited); that asymmetry is why the window stays at the
    ///   same short 250 ms the widget uses instead of being widened for more
    ///   coalescing.
    ///
    /// Coalescing and last-value-wins: the pending value is compared against
    /// the PENDING one when there is one, not against the in-memory event.
    /// Comparing against the event would let a change back to the stored
    /// value early-out and leave an intermediate value queued — the queued
    /// value would then land, and the last change the user made would lose.
    func scheduleCalendarEventColorDepthMirror(eventID: UUID, effort: Int?) {
        guard let index = calendarEventIndex(id: eventID) else { return }
        let targetColorDepth = Event.colorDepth(forEffort: effort)
        let currentColorDepth = pendingColorDepthMirror[eventID] ?? rawCalendarEvents[index].colorDepth
        guard abs(currentColorDepth - targetColorDepth) > 0.0001 else { return }
        pendingColorDepthMirror[eventID] = targetColorDepth
        colorDepthMirrorDebounceTask?.cancel()
        colorDepthMirrorDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: EventStore.colorDepthMirrorCoalesceWindow)
            guard !Task.isCancelled, let self else { return }
            self.flushCalendarEventColorDepthMirror()
        }
    }

    /// Apply every queued `colorDepth` mirror and commit once. Idempotent and
    /// a no-op when nothing is queued, so the three lifecycle edges can all
    /// call it unconditionally.
    ///
    /// The per-event re-check against the CURRENT in-memory value is what
    /// keeps the eventual stored value identical to what the synchronous
    /// mirror produced: a queued value equal to what the event already holds
    /// commits nothing, exactly as the old `abs(... ) > 0.0001` guard
    /// declined to write. The write itself is a bare field assignment on
    /// `rawCalendarEvents`, not `mutateCalendarEvent` — same as the old code,
    /// and deliberately: this must not drag interrupt-relation refresh or any
    /// other write-path side effect along with it.
    func flushCalendarEventColorDepthMirror() {
        colorDepthMirrorDebounceTask?.cancel()
        colorDepthMirrorDebounceTask = nil
        guard !pendingColorDepthMirror.isEmpty else { return }
        let pending = pendingColorDepthMirror
        pendingColorDepthMirror = [:]
        var didChange = false
        for (eventID, colorDepth) in pending {
            // Resolved at FLUSH time, not at schedule time: the event may
            // have been deleted, or another path may have moved its
            // colorDepth, in the window.
            guard let index = calendarEventIndex(id: eventID) else { continue }
            guard abs(rawCalendarEvents[index].colorDepth - colorDepth) > 0.0001 else { continue }
            rawCalendarEvents[index].colorDepth = colorDepth
            didChange = true
        }
        guard didChange else { return }
        _ = saveCalendarEvents(refreshInterrupts: false)
    }

    /// The one definition of "what counts as the same widget payload":
    /// settings that change how the widget renders (time format, language),
    /// the time zone the snapshots were computed in, plus the whole-value
    /// snapshot list (`SharedEventSnapshot` is `Hashable`, so a field added
    /// to the payload can't be silently left out of the change detection).
    /// Single-sourced because TWO sites must agree on it exactly — the write
    /// guard in `syncWidgetSnapshots` and the launch seed in
    /// `seedWidgetSnapshotHashFromAppGroup` — and a drift between them would
    /// either re-fire the cold-launch reload (waste) or suppress a real
    /// change (staleness). `Hasher` is per-process seeded, which is fine:
    /// the value is only ever compared within one process.
    ///
    /// The time zone is in the hash (gh#219 QA F1) because snapshot dates
    /// are absolute instants: a zone change can leave the payload bytes
    /// identical while every rendered hour label is wrong, and the old
    /// 5-minute pull this branch removed was the only thing that papered
    /// over that. With the zone hashed (and stamped into the App Group for
    /// the launch seed to read back), the first sync after app-open is a
    /// GUARANTEED heal. Accepted residue, ruled on the QA loop: a zone
    /// change while the app stays dead leaves the widget on old-zone times
    /// until the old zone's midnight rollover entry (<= 24h) — the widget
    /// process cannot notice on its own without spending the refresh budget
    /// this fix exists to protect. A DST transition inside one zone needs
    /// nothing: the identifier is unchanged, tzdata knows the shift in
    /// advance, and every delivered entry date is an absolute instant.
    private static func widgetPayloadHash(
        timeFormat: String, language: String, timeZone: String, snapshots: [SharedEventSnapshot]
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(timeFormat)
        hasher.combine(language)
        hasher.combine(timeZone)
        hasher.combine(snapshots)
        return hasher.finalize()
    }

    /// gh#219 app-side fix: `lastWrittenSnapshotHash` is process-local, so
    /// before this seed EVERY cold launch re-wrote a byte-identical App Group
    /// payload and spent one `reloadAllTimelines` on nothing — pure refresh-
    /// budget burn. Seeding by READING BACK what the group currently holds,
    /// rather than persisting the hash beside the payload, is the gh#142
    /// rule: no stored marker that can desync from the blob it describes. If
    /// anything about the read-back is off — no payload, missing settings
    /// keys (a pre-settings-era blob), a missing time-zone stamp (a
    /// pre-QA-F1 blob), a failed decode (corrupt blob) — the seed simply
    /// doesn't happen and the next sync rewrites the payload, which is the
    /// self-healing direction.
    ///
    /// The STORED zone, never `TimeZone.current`, goes into the seed hash:
    /// if the device changed zones while the app was dead, the stored
    /// identifier is the stale one, and hashing it is exactly what makes the
    /// first sync see a mismatch and heal (gh#219 QA F1).
    private func seedWidgetSnapshotHashFromAppGroup() {
        guard let defaults = SharedWidgetData.sharedDefaults,
              let data = defaults.data(forKey: SharedWidgetData.snapshotKey),
              let snapshots = try? JSONDecoder().decode([SharedEventSnapshot].self, from: data),
              let timeFormat = defaults.string(forKey: SharedWidgetData.timeFormatKey),
              let language = defaults.string(forKey: SharedWidgetData.languageKey),
              let timeZone = defaults.string(forKey: SharedWidgetData.timeZoneKey)
        else { return }
        lastWrittenSnapshotHash = Self.widgetPayloadHash(
            timeFormat: timeFormat, language: language, timeZone: timeZone, snapshots: snapshots
        )
    }

    private func syncWidgetSnapshots() {
        // `Calendar.current`, NOT `CalendarOccurrenceKey.referenceCalendar`:
        // the widget mirrors what the CANVAS shows, and every canvas day
        // boundary (`CalendarLayout.occurrencesForDate`, and the widget's own
        // `todayEvents()`) is computed in the device's current time zone. The
        // frozen reference time zone exists to keep *record identity hashes*
        // stable across travel, which is a different job — using it here would
        // make the widget disagree with the canvas after a tz change, not agree.
        let calendar = Calendar.current
        let window = WidgetSnapshotBuilder.window(now: Date(), calendar: calendar)
        // canvasRenderableCalendarEvents (not raw): absorbed todos live inside
        // their parent's detail view and are hidden on the canvas, so they must
        // be hidden on the widget too. The builder re-applies the same
        // predicate (`Event.isCanvasRenderable`) — deliberate belt-and-braces
        // of the canvasRenderable audit, over one shared rule so the two halves
        // cannot drift apart.
        let sourceEvents = canvasRenderableCalendarEvents
        let snapshots = WidgetSnapshotBuilder.snapshots(
            events: sourceEvents,
            windowStart: window.start,
            windowEnd: window.end,
            calendar: calendar,
            colorHex: { EventTypeTemplateStore.colorHex(for: $0) }
        )

        let timeFormatRaw = AppTimeFormat.current.rawValue
        let languageRaw = AppLanguage.current.rawValue
        // The zone the snapshots were just computed in — `calendar` above is
        // `Calendar.current`, so this is the same zone the window and every
        // day boundary used.
        let timeZoneRaw = calendar.timeZone.identifier

        let snapshotHash = Self.widgetPayloadHash(
            timeFormat: timeFormatRaw, language: languageRaw, timeZone: timeZoneRaw, snapshots: snapshots
        )
        // Skip JSON encode + App Group write + WidgetCenter reload IPC when payload is unchanged.
        if snapshotHash == lastWrittenSnapshotHash { return }

        let written = SharedWidgetData.write(
            events: snapshots,
            timeFormat: timeFormatRaw,
            language: languageRaw,
            timeZone: timeZoneRaw
        )
        // Only remember the payload once it actually landed — caching the hash
        // after a failed write would make every future identical state a no-op.
        guard written else {
            // `appGroup=false` is the gh#142 failure: the target lost its
            // `com.apple.security.application-groups` entitlement, so every
            // write was landing in the app's own preferences and the widget
            // read an empty container. Loud on purpose — it used to be silent.
            persistenceLogger.error(
                "widget snapshot write FAILED (count=\(snapshots.count, privacy: .public) appGroup=\(SharedWidgetData.isMemberOfAppGroup, privacy: .public))"
            )
            return
        }
        reloadWidgetTimelines()
        lastWrittenSnapshotHash = snapshotHash
        // Same durability-trail idiom as the calendar save above. The one
        // invariant this line can actually decide is `unique == occurrences`
        // (the duplicate-id half of gh#142); anything else is context.
        // `input` is the post-filter event count and `sources` the number of
        // events that reached the payload — `sources < input` is the NORMAL
        // reading (every event outside the 7-day window is missing from it),
        // so it proves nothing on its own; it is here to size the gap when a
        // user reports a specific event missing.
        persistenceLogger.log(
            "widget snapshot: input=\(sourceEvents.count, privacy: .public) occurrences=\(snapshots.count, privacy: .public) unique=\(Set(snapshots.map(\.id)).count, privacy: .public) sources=\(Set(snapshots.map(\.resolvedEventID)).count, privacy: .public)"
        )
    }

    @discardableResult
    func saveCalendarEventFeedbackRecords() -> Bool {
        persist(calendarEventFeedbackRecords, to: .calendarEventFeedbackRecords)
    }

    @discardableResult
    func saveCalendarEventLogRecords() -> Bool {
        persist(calendarEventLogRecords, to: .calendarEventLogRecords)
    }

    /// Erase every local array.
    ///
    /// Commits an EMPTY ENVELOPE per slot rather than deleting the files. That
    /// choice is the whole point: deleting them would leave "no file", and "no
    /// file" is exactly the state that re-runs legacy migration on the next
    /// launch. `removeObject` goes to cfprefsd, whose durability is the bug
    /// being fixed here, so a kill after the deletes could resurrect the legacy
    /// key and hand the user back the data they just erased. With a file
    /// present, legacy is never consulted, so resurrection is unreachable.
    ///
    /// Each slot's clear is independently atomic, so a kill part-way through
    /// leaves some slots cleared and the rest not — the user presses the button
    /// again. No redo marker needed.
    ///
    /// A restore's redo marker IS a path back for erased data, and it is a
    /// full copy of five arrays sitting in `pending/` — so the wipe drops
    /// those too. (The seq guard in `replayPendingRestoreIfNeeded` already
    /// makes a surviving marker a no-op over slots the wipe rewrote; this
    /// closes the case where one of those wipe writes ALSO failed, and gets
    /// the plaintext off the device, which is what the user asked for.)
    func clearAllLocalData() {
        events = []
        rawCalendarEvents = []
        calendarEventFeedbackRecords = []
        calendarEventLogRecords = []
        todoLists = []
        people = []
        friendGroups = []
        reminders = []

        // A frozen slot must still be erasable — the user asked for the data
        // to be gone, and a slot we could not READ is one we can still empty.
        storageFaults.removeAll()
        writeFailedSlots.removeAll()
        storage.clearFaults()
        refreshPersistenceDegraded()

        for slot in StorageSlot.allCases {
            switch slot {
            case .events: persist([Event](), to: slot, wiped: true, intent: .destructive)
            case .calendarEvents: persist([Event](), to: slot, wiped: true, intent: .destructive)
            case .calendarEventFeedbackRecords:
                persist([CalendarEventFeedbackRecord](), to: slot, wiped: true, intent: .destructive)
            case .calendarEventLogRecords:
                persist([CalendarEventLogRecord](), to: slot, wiped: true, intent: .destructive)
            case .todoLists: persist([TodoList](), to: slot, wiped: true, intent: .destructive)
            case .people: persist([Person](), to: slot, wiped: true, intent: .destructive)
            case .friendGroups: persist([FriendGroup](), to: slot, wiped: true, intent: .destructive)
            case .reminders: persist([Reminder](), to: slot, wiped: true, intent: .destructive)
            }
            // `.bak`, quarantine and shrink snapshots hold pre-wipe plaintext.
            storage.purgeAuxiliaryCopies(for: slot)
            seedableSlots.insert(slot)
        }
        storage.clearAllPendingWork(kind: Self.restorePendingKind)
        storage.removeDominoHeartbeat()
        dominoLastPushEffective = nil
        // Hygiene, not correctness: the empty envelopes above are what make
        // the wipe stick, whatever cfprefsd does with these.
        storage.removeLegacyKeys()
        defaults.removeObject(forKey: Self.legacyDominoLastPushKey)

        lastWrittenSnapshotHash = nil
        // This is the only path that empties `rawCalendarEvents` without going
        // through `saveCalendarEvents()`, so nothing else here schedules a
        // widget sync. Without this flush the App Group keeps the last blob —
        // event titles and all — after the user asks for every local trace to
        // be erased, and it stays on the Home Screen until some later edit
        // happens to trigger a rewrite. Flushed rather than scheduled: the
        // caller may be about to sign the user out or terminate, and a 250ms
        // debounce is not guaranteed to survive that.
        flushWidgetSnapshotSync()
        // The trail carries event IDs and per-array counts. A user asking for
        // every local trace to be erased means this one too — and the same
        // reasoning already applies to the avatar file and composer drafts,
        // which the caller clears alongside this. Cleared LAST so the flush
        // above cannot write a line into an already-emptied trail.
        DiagnosticTrail.clear()
    }

    @discardableResult
    private func refreshInterruptRelationStates(in events: inout [Event]) -> Bool {
        var changed = false
        for index in events.indices {
            guard var relation = events[index].interruptRelation else { continue }
            let resolvedState = resolveInterruptRelationState(
                for: events[index],
                relation: relation,
                in: events
            )
            if relation.state != resolvedState {
                relation.state = resolvedState
                events[index].interruptRelation = relation
                changed = true
            }
        }
        return changed
    }

    private func resolveInterruptRelationState(
        for event: Event,
        relation: EventInterruptRelation,
        in events: [Event]
    ) -> EventInterruptRelationState {
        guard let childRange = event.primaryTimeRange else {
            return relation.state
        }
        guard let parentRange = resolveInterruptParentRange(for: relation, in: events) else {
            return .orphaned
        }
        return parentRange.end > childRange.start && parentRange.start < childRange.end
            ? .embedded
            : .detached
    }

    private func resolveInterruptParentRange(
        for relation: EventInterruptRelation,
        in events: [Event]
    ) -> Event.TimeRange? {
        let calendar = Calendar.current
        let targetDay = calendar.startOfDay(for: relation.occurrenceDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: targetDay) ?? targetDay
        let anchorEventID = relation.parentEventID
        let baseSeriesEventID = relation.baseSeriesEventID ?? relation.parentEventID

        if let exact = events.first(where: { $0.id == anchorEventID }) {
            if exact.isRecurringSeries {
                if let range = CalendarLayout.recurrenceOccurrence(for: exact, on: targetDay, calendar: calendar) {
                    return range
                }
            } else if let range = exact.primaryTimeRange,
                      range.end > targetDay,
                      range.start < dayEnd {
                return range
            }
        }

        if let exception = events.first(where: { candidate in
            candidate.recurrenceParentId == baseSeriesEventID
                && candidate.recurrenceInstanceMatches(day: targetDay, calendar: calendar)
        }) {
            // Render-frame range: the canvas places this instance on its
            // nominal day (`renderTimeRanges`), so the interrupt moat must
            // measure against the same placement or the child detaches from
            // a parent that visibly contains it after a tz change.
            return exception.renderPrimaryTimeRange(calendar: calendar)
        }

        return nil
    }

    @discardableResult
    func saveCalendarEvents(refreshInterrupts: Bool) -> Bool {
        if refreshInterrupts {
            _ = refreshInterruptRelationStates(in: &rawCalendarEvents)
        }
        return saveCalendarEvents()
    }

    // MARK: - Lookup Helpers

    func findEvent(id: UUID) -> Event? {
        events.first(where: { $0.id == id })
    }

    @discardableResult
    func mutateEvent(id: UUID, _ transform: (inout Event) -> Void) -> Bool {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return false }
        transform(&events[index])
        return true
    }

    // MARK: - By-ID Lookup Indices
    //
    // `first(where:)` over these three arrays was the shape at the top of the
    // gh#213 Time Profiler trace: `EventStore.findCalendarEvent(id:)` 4251 ms
    // main-thread inclusive over 150 s of real use, with
    // `initializeWithCopy for Event` among the top self-time symbols because
    // `for element in array` copies each 212-stored-property `Event` out of
    // the buffer on the way to the predicate. These maps make the lookup one
    // hash and exactly one element copy.
    //
    // READ-side optimal, WRITE-side slightly worse — not a free win, and the
    // word "pure optimization" would be wrong. Measured (Debug, n = 2000):
    // 1000 reads with no interleaved write are 286x faster; 500 write+read
    // alternations are 2.6x SLOWER, and 3.3x slower with the target parked at
    // slot 0 where the linear scan found it immediately. `updateCalendarEvent`
    // pays two cold rebuilds per call: one inside `mutateCalendarEvent`, whose
    // own write then invalidates it, and one for the re-find after the save —
    // and in between, `saveCalendarEvents(refreshInterrupts:)` passes
    // `&rawCalendarEvents` `inout`, which fires `didSet` on copy-out even when
    // the refresh changed nothing. No production path alternates at that rate
    // today, so this is a caveat and not a defect; a future per-tick write
    // loop over these arrays would want a different shape.
    //
    // `nil` means NOT BUILT. It never means "the array is empty" — an empty
    // array has an empty (non-nil) map. Only the `didSet` above writes `nil`.
    //
    // A stale map is worse than a wrong answer. `findCalendarEvent(id:)` and
    // `mutateCalendarEvent(id:)` SUBSCRIPT with the index they get back, so a
    // map that outlived a shrinking mutation — the delete path — is an
    // index-out-of-range trap, not a silent `nil`. Half the failure mode is
    // "returns the wrong row with no error anywhere"; the other half is a
    // crash. Both are reasons the invalidation is structural.
    //
    // SLICE 2 IS STILL OPEN: an index behind a helper does nothing for call
    // sites that never call the helper. Size it with BOTH closure spellings —
    //   git grep -nE \
    //     'rawCalendarEvents\.(first|firstIndex|last|lastIndex)(\(where: )? *\{ *\$0\.id ==' \
    //     -- 'Done/*.swift'
    // The `(\(where: )?` is the part the first count lacked, and without it
    // `findSeriesEvent`'s trailing-closure `first { $0.id == parentId }` was
    // invisible: 29 matching lines at e0f8ec3, not the 27 that were reported.
    // Of those 29, one is the doc comment on `calendarEventIndex(id:)` below.
    // `findSeriesEvent` and seven per-render / per-tick sites (the absorb
    // merge bubble, and the six deadline `Binding` reads in
    // `CalendarEventDetailView` + `TodoStackView`) went through the helper in
    // the follow-up round, leaving 21 matching lines — 20 real scan sites.

    /// Incremented on every (re)build of one of the three maps. Perf-only
    /// observability, and the only way to tell "built an empty map" apart
    /// from "distrusted an empty map and rebuilt it" — the exact trap
    /// `testEmptyArrayIsABuiltIndexNotAnUnbuiltOne` exists to catch, which a
    /// correctness-only assertion cannot see because a needless rebuild still
    /// returns the right answer.
    private(set) var lookupIndexBuildCount = 0

    /// `Event.id` → index into `rawCalendarEvents`.
    private var calendarEventIndexByID: [UUID: Int]?
    /// `CalendarEventLogRecord.id` → index into `calendarEventLogRecords`.
    private var logRecordIndexByKey: [CalendarOccurrenceKey: Int]?
    /// `CalendarEventFeedbackRecord.id` → index into `calendarEventFeedbackRecords`.
    private var feedbackRecordIndexByKey: [CalendarOccurrenceKey: Int]?

    /// First-wins `key → index` map over `array`.
    ///
    /// FIRST-wins, not last, because every call site this replaces was a
    /// `first(where:)` / `firstIndex(where:)`: with duplicate ids (a corrupt
    /// restore, a merge that double-inserted) the index has to resolve to the
    /// same element the linear scan would have returned, or the two lookup
    /// shapes disagree exactly when the data is already damaged.
    ///
    /// This file has TWO duplicate-resolution rules and they govern DIFFERENT
    /// arrays. First-wins (here) is the LOOKUP rule, and it is the only rule
    /// `rawCalendarEvents` has: nothing dedups that array, and
    /// `applyRestore(.cloudOverwritesLocal)` assigns it wholesale, so
    /// duplicate event ids are genuinely reachable. `dedupedByIdentity` is the
    /// INGRESS rule — newest-`updatedAt`-wins — and it runs at `load()` and at
    /// restore over the two occurrence-RECORD arrays only, never over
    /// `rawCalendarEvents`. Do not unify them: the lookup rule exists to match
    /// the scan it replaced, the ingress rule exists to stop
    /// `Dictionary(uniqueKeysWithValues:)` downstream from trapping.
    ///
    /// Iterates by index rather than `for element in array` as a stated
    /// PREFERENCE, not a guarantee: whether `key(array[i])` borrows or copies
    /// depends on the optimizer specializing this generic across a thick
    /// closure, which nothing in the source pins down. If it ever has to be
    /// enforceable, take a `KeyPath` instead of a closure.
    private static func lookupIndexMap<Element, Key: Hashable>(
        for array: [Element],
        key: (Element) -> Key
    ) -> [Key: Int] {
        var map = [Key: Int](minimumCapacity: array.count)
        for i in array.indices {
            let k = key(array[i])
            if map[k] == nil { map[k] = i }
        }
        return map
    }

    /// Index of `id` in `rawCalendarEvents`, or `nil` when absent.
    /// Same answer as `rawCalendarEvents.firstIndex(where: { $0.id == id })`.
    ///
    /// DO NOT STORE THE RESULT ACROSS A MUTATION. This hands back an `Int`,
    /// and an `Int` stays syntactically valid after the row it named moved or
    /// vanished — subscripting with a stale one is a wrong row or a trap.
    /// `findCalendarEvent(id:)` hands back a VALUE and has no such hazard;
    /// prefer it unless the caller genuinely needs to write through the slot.
    /// This repo has already paid once for an accessor whose scope let callers
    /// reach past the intended API — the `canvasRenderableCalendarEvents`
    /// audit, 11 sites.
    func calendarEventIndex(id: UUID) -> Int? {
        if let built = calendarEventIndexByID { return built[id] }
        let built = EventStore.lookupIndexMap(for: rawCalendarEvents, key: \.id)
        lookupIndexBuildCount += 1
        calendarEventIndexByID = built
        return built[id]
    }

    /// Index of `key` in `calendarEventLogRecords`, or `nil` when absent.
    /// Do not store the result across a mutation — see `calendarEventIndex(id:)`.
    ///
    /// Keying by HASH widened the blast radius of `CalendarOccurrenceKey`.
    /// Before gh#213 these lookups scanned with `==` alone, so an edit to
    /// `CalendarOccurrenceKey.==` that forgot the matching `hash(into:)` cost
    /// a missed load-time dedup. Now it costs "my note didn't save" on every
    /// log read AND write. `CalendarOccurrenceKeyTests` is the file that has
    /// to grow a case when either one changes.
    func logRecordIndex(id key: CalendarOccurrenceKey) -> Int? {
        if let built = logRecordIndexByKey { return built[key] }
        let built = EventStore.lookupIndexMap(for: calendarEventLogRecords, key: \.id)
        lookupIndexBuildCount += 1
        logRecordIndexByKey = built
        return built[key]
    }

    /// Index of `key` in `calendarEventFeedbackRecords`, or `nil` when absent.
    /// Do not store the result across a mutation — see `calendarEventIndex(id:)`.
    /// Same `==`/`hash(into:)` coupling as `logRecordIndex(id:)`.
    func feedbackRecordIndex(id key: CalendarOccurrenceKey) -> Int? {
        if let built = feedbackRecordIndexByKey { return built[key] }
        let built = EventStore.lookupIndexMap(for: calendarEventFeedbackRecords, key: \.id)
        lookupIndexBuildCount += 1
        feedbackRecordIndexByKey = built
        return built[key]
    }

    /// The by-id read every calendar feature funnels through. Behind
    /// `calendarEventIndex(id:)` since gh#213 — same answer as the
    /// `first(where:)` it replaced, one element copy instead of up to `n`.
    func findCalendarEvent(id: UUID) -> Event? {
        guard let index = calendarEventIndex(id: id) else { return nil }
        return rawCalendarEvents[index]
    }

    @discardableResult
    func mutateCalendarEvent(id: UUID, _ transform: (inout Event) -> Void) -> Bool {
        guard let index = calendarEventIndex(id: id) else { return false }
        let previous = rawCalendarEvents[index]
        transform(&rawCalendarEvents[index])
        // Every in-place calendar write funnels through here (drag drop, edit
        // sheet, detail edits, timer stop — `updateCalendarEvent` included),
        // and each of them commits CURRENT-frame instants. A detached
        // instance whose mirror still sits in another frame must have the
        // mirror rebased in the SAME write, or `renderTimeRanges` re-projects
        // the fresh ranges a day off (gh#127's KNOWN RESIDUAL, closed).
        // Ingress paths (restore/sync merge) replace whole arrays and never
        // route through this seam, so foreign-frame rows stay untouched.
        rawCalendarEvents[index] = Event.rebasedExceptionInstanceAfterRangeWrite(
            rawCalendarEvents[index],
            previous: previous
        )
        return true
    }

    // MARK: - TodoList CRUD

    private func saveTodoLists() {
        persist(todoLists, to: .todoLists)
    }

    func addList(_ list: TodoList) {
        todoLists.append(list)
        saveTodoLists()
    }

    func updateList(_ list: TodoList) {
        if let index = todoLists.firstIndex(where: { $0.id == list.id }) {
            todoLists[index] = list
            saveTodoLists()
        }
    }

    func deleteList(_ list: TodoList) {
        todoLists.removeAll { $0.id == list.id }
        saveTodoLists()
    }

    // MARK: - Reminder CRUD

    private func saveReminders() {
        persist(reminders, to: .reminders)
    }

    /// Reminders to render in the pull-down panel today: every incomplete one
    /// (they carry over day to day until done), plus ones completed *today*
    /// (shown struck-through). Incomplete first, then oldest-created first.
    var visibleReminders: [Reminder] {
        reminders
            .filter { reminder in
                if !reminder.isCompleted { return true }
                guard let completedAt = reminder.completedAt else { return false }
                return Calendar.current.isDateInToday(completedAt)
            }
            .sorted { lhs, rhs in
                if lhs.isCompleted != rhs.isCompleted { return !lhs.isCompleted }
                return lhs.createdAt < rhs.createdAt
            }
    }

    func addReminder(_ reminder: Reminder) {
        reminders.append(reminder)
        saveReminders()
    }

    /// Create a reminder from a title, trimming whitespace and ignoring empties.
    @discardableResult
    func addReminder(titled rawTitle: String) -> Reminder? {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let reminder = Reminder(title: title)
        addReminder(reminder)
        return reminder
    }

    func updateReminder(_ reminder: Reminder) {
        if let index = reminders.firstIndex(where: { $0.id == reminder.id }) {
            reminders[index] = reminder
            saveReminders()
        }
    }

    func deleteReminder(_ reminder: Reminder) {
        reminders.removeAll { $0.id == reminder.id }
        saveReminders()
    }

    /// Flip a reminder's completion. Completing stamps `completedAt` (drives the
    /// same-day-only visibility); un-completing clears it so it carries over.
    func toggleReminderCompletion(_ reminder: Reminder) {
        guard let index = reminders.firstIndex(where: { $0.id == reminder.id }) else { return }
        reminders[index].isCompleted.toggle()
        reminders[index].completedAt = reminders[index].isCompleted ? Date() : nil
        saveReminders()
    }

    /// Drop reminders completed before today so they vanish the next day (and
    /// the store doesn't grow without bound). Incomplete reminders are kept and
    /// thus roll forward. Called on load.
    private func pruneStaleReminders() {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let before = reminders.count
        reminders.removeAll { reminder in
            guard reminder.isCompleted, let completedAt = reminder.completedAt else { return false }
            return completedAt < startOfToday
        }
        if reminders.count != before {
            saveReminders()
        }
    }

    // MARK: - People & Friend Group CRUD

    private func savePeople() {
        persist(people, to: .people)
    }

    private func saveFriendGroups() {
        persist(friendGroups, to: .friendGroups)
    }

    /// People that should appear in pickers/management lists — excludes
    /// archived (soft-deleted) people.
    var activePeople: [Person] {
        people.filter { !$0.isArchived }
    }

    func person(id: UUID) -> Person? {
        people.first(where: { $0.id == id })
    }

    /// Resolve a list of person ids to `Person` records, preserving order and
    /// silently skipping ids that no longer exist. Used to render an event's
    /// bound people — archived people still resolve so history stays intact.
    func people(for ids: [UUID]) -> [Person] {
        ids.compactMap { id in people.first(where: { $0.id == id }) }
    }

    func addPerson(_ person: Person) {
        people.append(person)
        savePeople()
    }

    /// Create a person by name (deduplicating on a case-insensitive trimmed
    /// match against active people) and return it. Reuses an existing active
    /// person when the name already exists so the picker doesn't spawn
    /// duplicates.
    @discardableResult
    func addPerson(named rawName: String, colorName: String? = nil) -> Person? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let existing = activePeople.first(where: {
            $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }) {
            return existing
        }
        let person = Person(name: name, colorName: colorName)
        addPerson(person)
        return person
    }

    func updatePerson(_ person: Person) {
        if let index = people.firstIndex(where: { $0.id == person.id }) {
            people[index] = person
            savePeople()
        }
    }

    /// Soft-delete: mark the person archived so events that reference them
    /// still resolve a name, but they disappear from selectable lists.
    func archivePerson(_ person: Person) {
        if let index = people.firstIndex(where: { $0.id == person.id }) {
            people[index].isArchived = true
            savePeople()
        }
        // Drop the archived person from group memberships so groups only
        // surface selectable people.
        var didChangeGroups = false
        for index in friendGroups.indices where friendGroups[index].memberIDs.contains(person.id) {
            friendGroups[index].memberIDs.removeAll { $0 == person.id }
            didChangeGroups = true
        }
        if didChangeGroups { saveFriendGroups() }
    }

    func addFriendGroup(_ group: FriendGroup) {
        friendGroups.append(group)
        saveFriendGroups()
    }

    func updateFriendGroup(_ group: FriendGroup) {
        if let index = friendGroups.firstIndex(where: { $0.id == group.id }) {
            friendGroups[index] = group
            saveFriendGroups()
        }
    }

    func deleteFriendGroup(_ group: FriendGroup) {
        friendGroups.removeAll { $0.id == group.id }
        saveFriendGroups()
    }

    /// The group a person currently belongs to, or `nil` for "Default"
    /// (ungrouped). A person is a member of at most one group — see
    /// `setGroup(_:forPerson:)`.
    func groupID(forPerson personID: UUID) -> UUID? {
        friendGroups.first(where: { $0.memberIDs.contains(personID) })?.id
    }

    /// Move a person into exactly one group (or `nil` = Default/ungrouped),
    /// removing them from any other group first so single-membership holds.
    func setGroup(_ groupID: UUID?, forPerson personID: UUID) {
        var changed = false
        for index in friendGroups.indices {
            let shouldContain = friendGroups[index].id == groupID
            let doesContain = friendGroups[index].memberIDs.contains(personID)
            if shouldContain, !doesContain {
                friendGroups[index].memberIDs.append(personID)
                changed = true
            } else if !shouldContain, doesContain {
                friendGroups[index].memberIDs.removeAll { $0 == personID }
                changed = true
            }
        }
        if changed { saveFriendGroups() }
    }

    /// Active people not in any group — the "Default" bucket.
    var ungroupedPeople: [Person] {
        let grouped = Set(friendGroups.flatMap { $0.memberIDs })
        return activePeople.filter { !grouped.contains($0.id) }
    }

    func events(for list: TodoList) -> [Event] {
        events.filter { $0.listID == list.id && $0.status == .active }
    }

    // MARK: - Calendar CRUD

    func addCalendarEvent(_ event: Event) {
        recordPersistence("addCalendarEvent id=\(event.id.uuidString)")
        rawCalendarEvents.append(event)
        saveCalendarEvents(refreshInterrupts: true)
        notifyCalendarEventRecorded(event)
    }

    func updateCalendarEvent(_ event: Event) {
        guard applyCalendarEventInMemory(event) else { return }
        saveCalendarEvents(refreshInterrupts: true)
        // Notify with the row as COMMITTED, not the caller's copy — the
        // mutate seam may have rebased a detached instance's mirror onto the
        // current frame (see `Event.rebasedExceptionInstanceAfterRangeWrite`),
        // and subscribers must see what the disk saw.
        //
        // This re-find stays here rather than being handed back out of
        // `applyCalendarEventInMemory`, even though that would save a lookup:
        // the save above may rewrite this very row through
        // `refreshInterruptRelationStates(in:)`, so the row the in-memory
        // apply could return is NOT the row that reached disk. Since gh#213
        // this costs one hash and one copy anyway.
        notifyCalendarEventRecorded(findCalendarEvent(id: event.id) ?? event)
    }

    /// The in-memory half of `updateCalendarEvent`, without the save and
    /// without the notifications. For operations that mutate SEVERAL calendar
    /// rows and must land them in ONE commit — a "this and following" split
    /// writes a new series and caps the old one, and a kill between two
    /// commits would leave both series alive on the same days.
    @discardableResult
    private func applyCalendarEventInMemory(_ event: Event) -> Bool {
        guard mutateCalendarEvent(id: event.id, { $0 = event }) else {
            assertionFailure("EventStore.updateCalendarEvent missing id: \(event.id.uuidString)")
            NSLog("EventStore.updateCalendarEvent missing id: %@", event.id.uuidString)
            return false
        }
        return true
    }

    /// The observable half of add/update, fired AFTER the commit that made the
    /// row durable. Split out so a multi-row operation can commit once and
    /// still emit exactly the notifications its per-row helpers used to.
    private func notifyCalendarEventRecorded(_ event: Event) {
        onCalendarEventRecordCompleted?(event)
        calendarEventRecorded.send(event)
    }

    /// Image refs owned by the events in `doomedIDs` that NO surviving event
    /// still references. `.single` exceptions and `.following` split-siblings
    /// inherit the parent's image refs BY VALUE (the same `<id>/…` files), so
    /// deleting a doomed event must not erase a file a survivor still shows.
    /// Returns exactly the now-orphaned refs, safe to remove from disk.
    static func orphanedImageRefs(
        deleting doomedIDs: Set<UUID>,
        from events: [Event]
    ) -> [AgenticIntakeImageRef] {
        let survivingPaths = Set(
            events
                .filter { !doomedIDs.contains($0.id) }
                .flatMap { $0.agenticIntake?.images.map(\.relativePath) ?? [] }
        )
        return events
            .filter { doomedIDs.contains($0.id) }
            .flatMap { $0.agenticIntake?.images ?? [] }
            .filter { !survivingPaths.contains($0.relativePath) }
    }

    /// STAGE the image files owned by `doomedIDs` that no surviving event
    /// references. Reads the live array, so it MUST be called BEFORE the doomed
    /// events are removed from `rawCalendarEvents` — but it deletes nothing.
    ///
    /// Staging and deleting are two steps on purpose (issue #145 A). Unlinking
    /// a file is the one step in a delete that no retry can undo, and it used
    /// to run FIRST: a kill between it and the calendar commit left the event
    /// durable and its photo gone forever. Now the refs are held until every
    /// required slot commit has returned success, and `commitStagedAssetDeletion`
    /// does the unlink last. The failure direction that remains — an orphan
    /// file after a kill — is swept on the next launch.
    private func stageOrphanedAssets(deleting doomedIDs: Set<UUID>) -> [AgenticIntakeImageRef] {
        EventStore.orphanedImageRefs(deleting: doomedIDs, from: rawCalendarEvents)
    }

    /// The last step of a delete. Runs only when every slot this operation had
    /// to write reported a durable commit; otherwise the files stay, because
    /// the rows that reference them are still on disk.
    private func commitStagedAssetDeletion(
        _ staged: [AgenticIntakeImageRef],
        allCommitsSucceeded: Bool,
        context: String
    ) {
        guard !staged.isEmpty else { return }
        guard allCommitsSucceeded else {
            recordPersistenceError(
                "\(context): KEPT \(staged.count) image file(s) — a required slot commit failed"
            )
            return
        }
        removeAssetFiles(staged)
        recordPersistence("\(context): removed \(staged.count) orphaned image file(s) after commit")
    }

    /// Release any todos absorbed into a to-be-deleted event so they don't keep
    /// a dead `absorbedIntoEventID` — which would filter them out of the canvas
    /// (`canvasRenderableCalendarEvents`) and strand them with no parent to reach
    /// them from. Returns them to the canvas. MUST run before the doomed events
    /// are removed from `rawCalendarEvents`.
    private func releaseAbsorbedTodos(intoDeletedIDs doomedIDs: Set<UUID>) {
        for index in rawCalendarEvents.indices {
            if let absorbedInto = rawCalendarEvents[index].absorbedIntoEventID,
               doomedIDs.contains(absorbedInto) {
                rawCalendarEvents[index].absorbedIntoEventID = nil
            }
        }
    }

    /// One user operation, committed in one order: calendar first, records
    /// second, files last.
    ///
    /// The order is the whole point (issue #145). Every prefix of it is a
    /// state the user can recover from by repeating the delete — an event
    /// that is gone but still has records, or records that are gone but whose
    /// files linger. The orders it replaces were not: they destroyed photos
    /// and pruned logs while the event they belonged to was still durable.
    ///
    /// Each step is also GATED on the one before it, not just sequenced after
    /// it. A refused/failed calendar commit is not a kill window — it is a
    /// deterministic outcome (frozen slot, no space, unwritable container) in
    /// which the event is definitely still on disk, so nothing that hangs off
    /// it may be destroyed.
    func deleteCalendarEvent(_ event: Event) {
        recordPersistence("deleteCalendarEvent id=\(event.id.uuidString)")
        // Stage only image files no OTHER event still references — a
        // materialized exception / `.following` split-sibling shares the
        // parent's inherited refs, so a blind delete would erase a photo the
        // survivor still shows. Read before the row leaves the array.
        let stagedAssets = stageOrphanedAssets(deleting: [event.id])

        // 1. Every calendar-slot mutation, in memory, no saves.
        orphanInterruptChildrenInMemory(forParentDeletion: event)
        releaseAbsorbedTodos(intoDeletedIDs: [event.id])
        rawCalendarEvents.removeAll { $0.id == event.id }

        // 2. The authoritative state commits first.
        let calendarCommitted = saveCalendarEvents(refreshInterrupts: true)

        // 3. Then the records that hang off it — and ONLY if it actually left.
        //    A kill here leaves records whose event is gone: invisible, and
        //    swept by the next delete.
        //
        //    A REFUSED commit is the other case, and it is not a kill window:
        //    the event is still on disk and comes back on the next launch, so
        //    pruning its log and feedback rows anyway would durably destroy a
        //    SURVIVING event's history — the one direction #145 forbids, and
        //    reachable deterministically (frozen slot, disk full, ENOTEMPTY)
        //    rather than through a race. Skipping is strictly better in every
        //    failure mode: the relaunch is consistent instead of half-erased,
        //    and the user just deletes again.
        var recordsCommitted = true
        if calendarCommitted {
            if event.isInterrupt {
                recordsCommitted = pruneInterruptTimelineItems(for: event.id) && recordsCommitted
            }
            recordsCommitted = pruneFeedbackForDeletedCalendarEvent(event) && recordsCommitted
            recordsCommitted = pruneLogRecordsForDeletedCalendarEvent(event) && recordsCommitted
        } else {
            recordPersistenceError(
                "deleteCalendarEvent id=\(event.id.uuidString): KEPT the log/feedback records"
                + " — the calendar commit failed, so the event survives on disk"
            )
        }

        // 4. Only now, the irreversible step.
        commitStagedAssetDeletion(
            stagedAssets,
            allCommitsSucceeded: calendarCommitted && recordsCommitted,
            context: "deleteCalendarEvent"
        )
    }

    // MARK: - Recurrence

    func findSeriesEvent(for event: Event) -> Event? {
        if event.isRecurringSeries { return event }
        guard let parentId = event.recurrenceParentId else { return nil }
        return findCalendarEvent(id: parentId)
    }

    func applyRecurringEdit(
        seriesEvent: Event,
        occurrenceDate: Date,
        scope requestedScope: Event.RecurrenceEditScope,
        edit: (inout Event) -> Void
    ) {
        // Domain defense: a `.following` from the series' first occurrence is
        // `.all` (see `resolvedRecurrenceEditScope`) — collapse it BEFORE the
        // split branch caps the old series into a zombie and mints a duplicate.
        let scope = Event.resolvedRecurrenceEditScope(
            requested: requestedScope,
            series: seriesEvent,
            occurrenceDate: occurrenceDate
        )
        let result = Event.applyEdit(
            series: seriesEvent,
            occurrenceDate: occurrenceDate,
            scope: scope,
            edit: edit
        )
        if scope == .following, var newSeries = result.newSeries {
            // "This and following" splits the series: cap the old one and start a
            // NEW series (new id) at the split. Everything the OLD series owned
            // for days ≥ split must move to the new series, or it detaches:
            //  - exception DATES (customized + skipped) so the new series doesn't
            //    render a default occurrence on those days,
            //  - materialized exception INSTANCES (recurrenceParentId),
            //  - occurrence RECORDS (logs/feedback keyed on the old series id),
            //  - INTERRUPT relations.
            //
            // ONE calendar commit for the whole split (issue #145 B). This
            // used to be four: add the new series (commit), reindex logs
            // (commit), reindex feedback (commit), cap the old series
            // (commit). A kill after the first left BOTH series alive over
            // the same days — a state the user never asked for and cannot
            // reach any other way. Now every calendar row the split touches
            // is mutated in memory and lands in a single `rename(2)`; the
            // record slots follow it, so their worst case is records pointing
            // at a series that already exists.
            let calendar = Calendar.current
            let splitDay = calendar.startOfDay(for: occurrenceDate)
            // Carry classifies by nominal day KEY, not by reinterpreting the
            // stored legacy dates through the current calendar — a stored
            // midnight minted in another time zone reads as the previous day
            // here and the boundary exception would stay behind on the capped
            // series while its day moves to the new one (gh#127 item 1). The
            // paired legacy dates ride along untouched as the rollback mirror.
            let splitKey = Event.recurrenceDayKey(for: splitDay, calendar: calendar)
            let carried = seriesEvent.recurrenceExceptions(onOrAfterDayKey: splitKey)
            newSeries.recurrenceExceptionDates.append(contentsOf: carried.dates)
            newSeries.recurrenceExceptionDayKeys.append(contentsOf: carried.dayKeys)
            recordPersistence(
                "applyRecurringEdit .following split old=\(seriesEvent.id.uuidString)"
                + " new=\(newSeries.id.uuidString)"
            )
            rawCalendarEvents.append(newSeries)
            // Re-parent exception instances ≥ split so delete-new-series sweeps
            // them (and delete-old-series doesn't) — the day belongs to the new
            // series now. Classified by the instance's frozen day KEY, the same
            // frame as the exception-key carry above — reinterpreting the
            // mirror midnight through the current calendar reads one day off
            // after a tz change, so the boundary day's KEY would move to the
            // new series while its materialized INSTANCE stayed parented to
            // the old one: `.all`-delete of the new series then leaves that
            // instance alive as a zombie, and delete-old sweeps a day the new
            // series owns (gh#127 item 1 follow-up).
            for index in rawCalendarEvents.indices {
                guard rawCalendarEvents[index].recurrenceParentId == seriesEvent.id,
                      let instanceKey = Event.resolvedRecurrenceInstanceDayKey(
                          dayKey: rawCalendarEvents[index].recurrenceInstanceDayKey,
                          legacyDate: rawCalendarEvents[index].recurrenceInstanceDate
                      ),
                      instanceKey >= splitKey else { continue }
                rawCalendarEvents[index].recurrenceParentId = newSeries.id
            }
            reanchorInterrupts(from: seriesEvent.id, to: newSeries.id, onOrAfter: splitDay)
            let cappedSeries = result.updatedSeries.flatMap {
                applyCalendarEventInMemory($0) ? $0 : nil
            }
            // The one save persists the new series, the capped old series, the
            // re-parented exceptions and the re-anchored interrupts together,
            // and refreshes interrupt states against the now-present new series.
            guard saveCalendarEvents(refreshInterrupts: true) else {
                // The split never reached disk, so `newSeries.id` names a
                // series that does not exist for the next launch. Re-anchoring
                // the logged history onto it would COMMIT those rows (separate
                // slots, which are writable) to a dead id: the notes become
                // unreachable from any series that exists, while the old
                // series they belonged to comes back uncapped. Leaving them
                // where they are keeps the relaunch self-consistent.
                //
                // The notifications are held back for the same reason — they
                // announce a row as durable.
                recordPersistenceError(
                    "applyRecurringEdit .following: KEPT the occurrence records on"
                    + " old=\(seriesEvent.id.uuidString) — the calendar commit failed,"
                    + " new=\(newSeries.id.uuidString) never reached disk"
                )
                return
            }
            // Fired after the commit, in the order the per-row helpers used to
            // fire them (new series, then the capped one), so subscribers see
            // the same sequence against durable state.
            notifyCalendarEventRecorded(newSeries)
            if let cappedSeries {
                notifyCalendarEventRecorded(cappedSeries)
            }
            // Threshold from the current-tz MIDNIGHT of the split day (not the
            // raw occurrence instant): record↔day attachment is keyed by
            // `CalendarOccurrenceKey.make` on the canvas' startOfDay dates, so
            // a mid-day instant whose ref-tz projection crosses ref-midnight
            // would land the threshold one day off the frame lookups use.
            reindexOccurrenceRecords(
                from: seriesEvent.id,
                to: newSeries.id,
                onOrAfterDayKey: CalendarOccurrenceKey.dayKey(from: splitDay)
            )
            return
        }
        if let updated = result.updatedSeries {
            updateCalendarEvent(updated)
        }
        if let newSeries = result.newSeries {
            addCalendarEvent(newSeries)
        }
        if let exception = result.exceptionInstance {
            addCalendarEvent(exception)
        }
    }

    /// Move occurrence records (logs + feedback) whose frozen-reference day key
    /// is on/after `splitDayKey` from `oldID` to `newID` — the "this and
    /// following" split's counterpart to the delete-following record prune, so a
    /// day's logged history follows the series that now serves it instead of
    /// dangling on the capped old series.
    ///
    /// Compares each record's stable `CalendarOccurrenceKey.dayKey` (frozen under
    /// the reference time zone) against the split's key, NOT
    /// `Calendar.current.startOfDay(record.occurrenceDate)`: the record's
    /// wall-clock `occurrenceDate` is a reference-tz midnight, so reinterpreting
    /// it in the device's current tz drifts by a day after the user travels and
    /// a boundary-day record is then wrongly included/excluded (gh#127-item5).
    ///
    /// Frame choice (deliberate): records move by the rendered day they SERVE
    /// at split time, not by the nominal day they were minted for under some
    /// earlier device tz. Lookups resolve a rendered day to a record via
    /// `CalendarOccurrenceKey.make` on the current-tz startOfDay — i.e. a
    /// frozen `dayKey` names whichever rendered day currently projects onto
    /// it. The split's visible halves (series cap, exception re-parenting,
    /// interrupt re-anchoring) partition rendered days at
    /// `Calendar.current.startOfDay(occurrenceDate)`, so moving records by the
    /// same projection (`dayKey(from: splitDay)`) keeps every post-split
    /// lookup a hit: days < split find their records on the old series, days
    /// ≥ split on the new one. Classifying by creation-time nominal day
    /// instead would detach a boundary record from the series that renders
    /// its day — the lookup that still finds it would go dark. The residual
    /// truth that a traveled user's records serve a shifted day at all is the
    /// gh#127-item1 day-identity migration, deferred.
    private func reindexOccurrenceRecords(from oldID: UUID, to newID: UUID, onOrAfterDayKey splitDayKey: Int) {
        var logsChanged = false
        for index in calendarEventLogRecords.indices
        where calendarEventLogRecords[index].baseSeriesEventID == oldID
            && calendarEventLogRecords[index].id.dayKey >= splitDayKey {
            calendarEventLogRecords[index].reanchor(toSeriesID: newID)
            logsChanged = true
        }
        if logsChanged { saveCalendarEventLogRecords() }

        var feedbackChanged = false
        for index in calendarEventFeedbackRecords.indices
        where calendarEventFeedbackRecords[index].baseSeriesEventID == oldID
            && calendarEventFeedbackRecords[index].id.dayKey >= splitDayKey {
            calendarEventFeedbackRecords[index].reanchor(toSeriesID: newID)
            feedbackChanged = true
        }
        if feedbackChanged { saveCalendarEventFeedbackRecords() }
    }

    /// Re-anchor interrupt relations for days on/after `splitDay` onto the new
    /// series (the split's counterpart to `orphanInterruptChildren`). Mutates
    /// events in `rawCalendarEvents`; the caller persists them with the split's
    /// final save (which also refreshes interrupt states).
    private func reanchorInterrupts(from oldID: UUID, to newID: UUID, onOrAfter splitDay: Date) {
        let calendar = Calendar.current
        for index in rawCalendarEvents.indices {
            guard var relation = rawCalendarEvents[index].interruptRelation,
                  relation.parentEventID == oldID,
                  calendar.startOfDay(for: relation.occurrenceDate) >= splitDay else { continue }
            relation.parentEventID = newID
            relation.baseSeriesEventID = newID
            rawCalendarEvents[index].interruptRelation = relation
        }
    }

    func deleteRecurringCalendarEvent(
        seriesEvent: Event,
        occurrenceDate: Date,
        scope requestedScope: Event.RecurrenceEditScope
    ) {
        // Domain defense: a `.following` delete from the series' first occurrence
        // is `.all` (see `resolvedRecurrenceEditScope`) — collapse it so the whole
        // series is removed instead of zombie-capped to `seriesStart − 1`.
        let scope = Event.resolvedRecurrenceEditScope(
            requested: requestedScope,
            series: seriesEvent,
            occurrenceDate: occurrenceDate
        )
        recordPersistence(
            "deleteRecurringCalendarEvent series=\(seriesEvent.id.uuidString) scope=\(String(describing: scope))"
            + (scope == requestedScope ? "" : " coercedFrom=\(String(describing: requestedScope))")
        )
        let calendar = Calendar.current
        let occurrenceDay = calendar.startOfDay(for: occurrenceDate)

        // Same three phases as `deleteCalendarEvent`: calendar in memory →
        // calendar commit → records → files. Records used to be pruned before
        // the calendar commit, so a kill in between took a series' logged
        // history while the series itself survived.
        orphanInterruptChildrenInMemory(
            forDeletedRecurringSeries: seriesEvent,
            occurrenceDate: occurrenceDay,
            scope: scope
        )

        var stagedAssets: [AgenticIntakeImageRef] = []
        var recordedEvent: Event?

        switch scope {
        case .all:
            // Series + every exception instance. Stage their now-orphaned image
            // files (ref-counted: a `.following` split-sibling that shares
            // inherited refs keeps its files). Fixes the old series-delete leak
            // without erasing a survivor's shared photo.
            let doomedIDs = Set(
                rawCalendarEvents
                    .filter { $0.id == seriesEvent.id || $0.recurrenceParentId == seriesEvent.id }
                    .map(\.id)
            )
            stagedAssets = stageOrphanedAssets(deleting: doomedIDs)
            releaseAbsorbedTodos(intoDeletedIDs: doomedIDs)
            rawCalendarEvents.removeAll { doomedIDs.contains($0.id) }

        case .single:
            var updated = seriesEvent
            // Day key + legacy date in step (gh#127 item 1).
            updated.appendRecurrenceException(onDay: occurrenceDay, calendar: calendar)
            // Notified only if the row was actually there to update, matching
            // what `updateCalendarEvent` did when it owned this call.
            if applyCalendarEventInMemory(updated) { recordedEvent = updated }

        case .following:
            let endCutoff = calendar.date(byAdding: .day, value: -1, to: occurrenceDay)
            // Sweep materialized exceptions on/after the cutoff. Without this a
            // previously single-edited day ≥ cutoff is a standalone event not
            // bounded by the series end date, so it keeps rendering after
            // "delete this and following" (the .all case removes exceptions;
            // this branch used to only cap the series).
            // Swept by frozen instance day KEY (the same frame the split's
            // exception carry classifies in) — reinterpreting the mirror
            // midnight via `calendar.startOfDay` drifts a day after travel
            // and the sweep then misses/over-sweeps the boundary day
            // (gh#127 item 1 follow-up).
            let sweepKey = Event.recurrenceDayKey(for: occurrenceDay, calendar: calendar)
            let sweptIDs = Set(
                rawCalendarEvents.filter { candidate in
                    candidate.recurrenceParentId == seriesEvent.id
                        && (Event.resolvedRecurrenceInstanceDayKey(
                            dayKey: candidate.recurrenceInstanceDayKey,
                            legacyDate: candidate.recurrenceInstanceDate
                        ).map { $0 >= sweepKey } ?? false)
                }.map(\.id)
            )
            stagedAssets = stageOrphanedAssets(deleting: sweptIDs)
            releaseAbsorbedTodos(intoDeletedIDs: sweptIDs)
            rawCalendarEvents.removeAll { sweptIDs.contains($0.id) }
            var updated = seriesEvent
            updated.repeatEndType = .onDate
            updated.repeatEndDate = endCutoff
            if applyCalendarEventInMemory(updated) { recordedEvent = updated }
        }

        let calendarCommitted = saveCalendarEvents(refreshInterrupts: true)

        // Same gate as `deleteCalendarEvent`: the occurrence records — and the
        // "this row is durable now" notification — only follow a calendar
        // commit that actually landed. A refused commit leaves the series
        // whole on disk, and a `.single`/`.following`/`.all` prune would then
        // erase the logged history of an event the next launch still shows.
        var recordsCommitted = true
        if calendarCommitted {
            if let recordedEvent {
                notifyCalendarEventRecorded(recordedEvent)
            }
            recordsCommitted = pruneFeedbackForDeletedRecurringSeries(
                seriesEvent: seriesEvent,
                occurrenceDate: occurrenceDay,
                scope: scope
            )
            recordsCommitted = pruneLogRecordsForDeletedRecurringSeries(
                seriesEvent: seriesEvent,
                occurrenceDate: occurrenceDay,
                scope: scope
            ) && recordsCommitted
        } else {
            recordPersistenceError(
                "deleteRecurringCalendarEvent series=\(seriesEvent.id.uuidString)"
                + " scope=\(String(describing: scope)): KEPT the log/feedback records"
                + " — the calendar commit failed, so the series survives on disk"
            )
        }

        commitStagedAssetDeletion(
            stagedAssets,
            allCommitsSucceeded: calendarCommitted && recordsCommitted,
            context: "deleteRecurringCalendarEvent \(String(describing: scope))"
        )
    }

    // MARK: - Zombie series sweep (gh#150)

    /// Why this launch must NOT judge anything the zombie scan finds, or `nil`
    /// when the store it reads is provably the user's committed state.
    ///
    /// Same shape and the same reasoning as `startupOrphanAssetSweepRefusal`:
    /// every arm is a case where the store looks healthy but is INCOMPLETE, and
    /// an incomplete store is exactly where a signature match stops being
    /// evidence. A zombie's satellites (logs, feedback, exception instances,
    /// photos) are what make it undeletable — if the slot holding them failed
    /// to read, came from the previous generation via the `.bak` hardlink, or
    /// is about to be overwritten by a replay, the sweep would see a
    /// satellite-free row that is not satellite-free. That used to destroy
    /// history; it now writes `deletable` about a row that is nothing of the
    /// kind, into a file the user exports and hands to someone. A trail line is
    /// cheap, but a wrong one is evidence pointing the wrong way, and this
    /// report exists to BE evidence.
    ///
    /// 1. Any storage fault this launch. A frozen slot contributes no rows, so
    ///    every ownership arm below it silently answers "owns nothing".
    /// 2. Any slot served from something other than its own committed primary —
    ///    the backup-promotion case, which raises no fault and shows no banner.
    /// 3. A pending restore marker. `replayPendingRestoreIfNeeded` runs first
    ///    and clears what it applies, so a marker still standing here means a
    ///    restore is unfinished; the rows it is about to write are not on disk
    ///    yet, and half of them may be a zombie's satellites.
    ///
    /// Deliberately NOT an arm: "no rows loaded". An empty store yields no
    /// candidates, so the sweep is already a no-op there.
    ///
    /// Exposed (rather than inlined into the guard) for the same reason its
    /// sibling is: a test can reach a property where it cannot reach a frozen
    /// slot or a promoted backup.
    var zombieSweepRefusal: String? {
        if hasFrozenSlot {
            return "storage faults this launch: \(frozenSlotNames)"
        }
        let degraded = slotProvenance
            .filter { $0.value != .primary }
            .map { "\($0.key.rawValue)=\($0.value.rawValue)" }
            .sorted()
        if !degraded.isEmpty {
            return "slot did not come from its committed primary: \(degraded.joined(separator: ","))"
        }
        if !storage.pendingWork(kind: Self.restorePendingKind).isEmpty {
            return "a restore marker is still pending"
        }
        return nil
    }

    /// Why this particular signature match must be reported KEPT, or `nil` when
    /// deleting it would destroy nothing but the row itself.
    ///
    /// Nothing acts on the `nil` any more — `sweepZombieRecurringSeries` states
    /// why the destructive arm is parked — so this now decides which of two
    /// trail lines a candidate earns. The arms below are unchanged: they are
    /// the bar the evidence has to clear before a delete could ever come back.
    ///
    /// The issue's requirement that the migration VERIFY per series rather than
    /// assume. The original gh#124 split reindexed the old series' records onto
    /// the new one, so the expected answer is "nothing is attached" — but a
    /// split that was killed midway, a pre-split log, or a tz-drifted day key
    /// all leave the counter-example, and each of those is history that a
    /// delete would take permanently.
    ///
    /// Blockers, in order:
    /// - **Not provably a mint** (`Event.zombieMintShapeRefusal`). The signature
    ///   alone is a CANDIDATE filter that a time-zone change can manufacture out
    ///   of a perfectly legitimate row, so what licences a `deletable` verdict
    ///   is that predicate's frame-invariant half: the end→seed separation window, plus
    ///   the proof that no zone in the tz database reads this row as an
    ///   ends-on-start-day rule. Everything else here is about what the row
    ///   OWNS; this arm is about whether it is the bug's output at all.
    /// - **Exception instances.** A materialized `.single` edit parented to the
    ///   zombie is a row the user typed into.
    /// - **Log / feedback records.** Matched on `baseSeriesEventID` OR
    ///   `eventID`, a deliberate SUPERSET of what
    ///   `recordsSurviving(afterDeletingSeries:)` would prune (`baseSeriesEventID`
    ///   only): a record the prune would leave dangling still counts as history
    ///   attached to this id, and we would rather keep a dormant row than
    ///   strand a log.
    /// - **No partner series** (`Event.zombieMintPartner`). The mint never
    ///   produced a lone zombie: `applyEdit(.following)` caps the old series AND
    ///   appends a replacement that is a BY-VALUE copy of it, seeded at the very
    ///   instant the capped row is seeded at. A row with no such partner is far
    ///   more likely the thing the shape tests cannot tell a mint from — a
    ///   user-picked end date, or an `.all` edit that moved the seed past its own
    ///   end — so it is kept and reported. The partner match is deliberately much
    ///   more than "same title and rule": that trio is shared by two
    ///   independently authored daily rows, and is vacuous for the untitled rows
    ///   this app persists on purpose.
    /// - **Unique intake photos.** An image file no surviving row references —
    ///   the one loss with no cloud or legacy fallback. Refs SHARED with the
    ///   split-off sibling (which inherited them by value) are not a blocker:
    ///   `orphanedImageRefs` already ref-counts them and stages nothing.
    ///
    /// Explicitly NOT blockers, because the sanctioned `.all` delete the parked
    /// arm would have called already hands each of them back non-destructively:
    /// - interrupt children → marked `.orphaned`, still on the canvas;
    /// - absorbed todos → `absorbedIntoEventID` cleared, returned to the canvas;
    /// - inbound partner links (`linkedCalendarEventId` / `linkedTodoEventId`
    ///   pointing at the zombie) → a dangling link resolves to nil, which is
    ///   what every other delete in the app leaves behind.
    ///
    /// Ordered cheapest and most decisive first, and the arms that scan arrays
    /// after the one that scans none: the pure shape refusal (no array at all)
    /// → the ownership scans, single-field equality over arrays that are empty
    /// for almost every candidate → the partner search, a short-circuiting field
    /// comparison per calendar row → `orphanedImageRefs`, which builds a set of
    /// every survivor's refs. The order also keeps each kept row's trail line naming
    /// the most specific reason it has: a row that owns logged history says so
    /// rather than reporting the partner it also lacks.
    func zombieSweepBlocker(for zombie: Event) -> String? {
        if let refusal = Event.zombieMintShapeRefusal(zombie) {
            return refusal
        }
        if rawCalendarEvents.contains(where: { $0.recurrenceParentId == zombie.id }) {
            return "owns exception instance(s)"
        }
        if calendarEventLogRecords.contains(where: {
            $0.baseSeriesEventID == zombie.id || $0.eventID == zombie.id
        }) {
            return "owns log record(s)"
        }
        if calendarEventFeedbackRecords.contains(where: {
            $0.baseSeriesEventID == zombie.id || $0.eventID == zombie.id
        }) {
            return "owns feedback record(s)"
        }
        if Event.zombieMintPartner(of: zombie, among: rawCalendarEvents) == nil {
            return "no partner series — nothing here is a healthy series carrying this row's"
                + " title, rule, kind, type, all-day flag, colour and duration, seeded at its"
                + " own seed instant, so the mint's other half never existed"
        }
        if !EventStore.orphanedImageRefs(deleting: [zombie.id], from: rawCalendarEvents).isEmpty {
            return "owns intake image file(s) no survivor references"
        }
        return nil
    }

    /// Report — and deliberately do NOT remove — the gh#124 zombie series that
    /// pre-fix builds minted, once per launch, as the LAST step of `load()`.
    ///
    /// **Why this reports instead of deleting.** Four rounds of predicate work
    /// (`df8f8bf` → `2fe145e` → `3d1aff0` → `76d111a`) each closed one direction
    /// and opened the other, and the last round proved the reason: a mint pair
    /// and a hand-made duplicate are the SAME BYTES. `applyEdit(.following)`
    /// copies the series by value, so every field a predicate could compare is
    /// one the user could equally have typed twice — and the app persists
    /// untitled captures by design, which hollows out even the title. Telling
    /// the two apart needs provenance no existing row carries. Tightening to an
    /// exact seed instant did not escape it either: it broke the real mint
    /// (`dateByCombining` drops the sub-second fraction the capped row keeps),
    /// so the sweep started missing the very rows it exists for while STILL
    /// deleting an identical hand-made duplicate.
    ///
    /// So the destructive half is parked, not the diagnostic half. A hard
    /// `rest.delete` propagating a false positive to every device is
    /// unrecoverable; a trail line is free. What flips this back on is evidence,
    /// not a better predicate: run this on real devices, read the `deletable`
    /// lines, and if the classification proves exact on data that actually
    /// exists, the delete arm goes back in behind whatever that evidence
    /// justifies — an explicit user-confirmed cleanup in Settings being the
    /// obvious shape, since the user is the provenance the rows lack.
    ///
    /// `c19aa55` stopped new zombies; `e0b62bd` kept the existing ones dormant
    /// and their signature unlaundered so this could find them. What is left is
    /// a row that renders nothing yet still shows up in the Settings recurring
    /// list — user-visible debris from a bug the user already suffered once.
    ///
    /// **Idempotent by signature, with no ran-once flag.** The flag would be
    /// the fragile half: a cloud restore or a device backup can re-introduce a
    /// zombie long after the flag was set, and a flag also means a new
    /// UserDefaults key to migrate and roll back. Re-scanning costs one filter
    /// over the calendar array per launch, and a store with no candidates
    /// writes nothing and logs nothing.
    ///
    /// **Reports every signature match, and classifies it.** The signature is a
    /// day-level comparison in the CURRENT zone, and a move west of where a row
    /// was written manufactures one out of a perfectly legitimate
    /// ends-on-start-day series. So a match earns a trail line — that row is
    /// also rendering nothing on this device right now, which is worth knowing.
    /// `zombieSweepBlocker` then splits the matches two ways: a `kept` line
    /// names the reason a row could never have been auto-deleted (it owns
    /// records, exception instances or unshared image files, or no partner
    /// stands beside it), and a `deletable` line names a row that passes every
    /// test the delete arm would have applied — mint-shaped by
    /// `Event.zombieMintShapeRefusal`, owning nothing irreversible, and standing
    /// beside the replacement series a mint would have left
    /// (`Event.zombieMintPartner`), whose id the line records.
    ///
    /// Those `deletable` lines are the evidence this exists to gather. Read
    /// against a real store they answer the only question a predicate cannot:
    /// whether the rows it would have destroyed are in fact debris.
    ///
    /// Runs synchronously on the main actor at the end of `load()`: the store's
    /// arrays are settled (restore replayed, decode normalization applied,
    /// records deduped) and nothing has observed them yet. Any future
    /// reordering of `load()` must keep this last.
    private func sweepZombieRecurringSeries() {
        let candidates = rawCalendarEvents.filter {
            Event.zombieRecurrenceSignatureDayGap($0) != nil
        }
        // Quiet when there is nothing to do — checked BEFORE the refusal, so a
        // healthy store with no zombies (the overwhelming majority of launches,
        // and every launch after the first cleaned one) writes no trail at all.
        guard !candidates.isEmpty else { return }

        if let refusal = zombieSweepRefusal {
            DiagnosticTrail.record(
                "ZombieSweep",
                "skipped \(candidates.count) candidate(s): \(refusal)"
            )
            return
        }

        var deletable = 0
        var kept = 0
        for zombie in candidates {
            let gap = Event.zombieRecurrenceSignatureDayGap(zombie) ?? -1
            if let blocker = zombieSweepBlocker(for: zombie) {
                kept += 1
                DiagnosticTrail.record(
                    "ZombieSweep",
                    "kept id=\(zombie.id.uuidString) gap=\(gap)d: \(blocker)"
                )
                continue
            }
            // Ids and the gap only, never the title. The trail is a file the
            // user EXPORTS and hands to someone (`DiagnosticTrail.exportFile`),
            // and every other line in it names rows by id for exactly that
            // reason. The partner is re-found rather than threaded out of the
            // blocker: a nil blocker means one exists, and naming it is what
            // would make a removal auditable after the fact — the row it was
            // paired with is the whole evidence.
            let partner = Event.zombieMintPartner(of: zombie, among: rawCalendarEvents)
            deletable += 1
            DiagnosticTrail.record(
                "ZombieSweep",
                "deletable id=\(zombie.id.uuidString) gap=\(gap)d"
                + " partner=\(partner?.id.uuidString ?? "none")"
            )
        }
        DiagnosticTrail.record(
            "ZombieSweep",
            "done report-only candidates=\(candidates.count) deletable=\(deletable) kept=\(kept)"
        )
    }

    func add(_ event: Event) {
        events.append(event)
        save()
    }

    func addWithAutoPlacement(_ event: Event) {
        add(event)
    }

    func update(_ event: Event) {
        if mutateEvent(id: event.id, { $0 = event }) {
            save()
        }
    }

    func delete(_ event: Event) {
        // Stop timer if this todo has an active timer. Route through the
        // canonical helper so the recorded start instant and the
        // record-completed side effects match stopTimer/markComplete.
        if let linkedId = event.linkedCalendarEventId,
           findCalendarEvent(id: linkedId)?.timerStartedAt != nil {
            stopTimerOnCalendarEvent(linkedId)
        }
        events.removeAll { $0.id == event.id }
        save()
    }

    var activeEvents: [Event] {
        events.filter { $0.status == .active }
    }

    var completedEvents: [Event] {
        events
            .filter { $0.status == .completed }
            .sorted { ($0.completeAt ?? .distantPast) > ($1.completeAt ?? .distantPast) }
    }

    var completedCount: Int {
        events.filter { $0.status == .completed }.count
    }

    var archivedEvents: [Event] {
        events.filter { $0.status == .archived }
    }

    func markArchived(_ event: Event) {
        if let linkedId = event.linkedCalendarEventId {
            stopTimerOnCalendarEvent(linkedId)
        }
        guard mutateEvent(id: event.id, { $0.status = .archived }) else { return }
        save()
    }

    func restoreFromArchive(_ event: Event) {
        guard mutateEvent(id: event.id, { $0.status = .active }) else { return }
        save()
    }

    func markComplete(_ event: Event) {
        if let linkedId = event.linkedCalendarEventId {
            stopTimerOnCalendarEvent(linkedId)
        }
        guard mutateEvent(id: event.id, {
            $0.status = .completed
            $0.isDone = true
            $0.completeAt = Date()
        }) else { return }
        save()
    }

    func completeWanna(_ event: Event, now: Date = Date()) {
        // Mark the wanna as completed
        markComplete(event)

        // Stamp on the active calendar event's timeline (if any).
        // Render-frame occurrenceDate, not the raw stored start: for a
        // traveled detached instance `CalendarOccurrenceKey.make` reduces
        // this date to the occurrence-record dayKey via the frozen
        // reference-calendar day-start, and readers mint their lookup
        // keys through that same reduction — seeded from the projected
        // start the canvas draws (gh#187 route seeds) or from a day-start
        // of the occurrence date they hold. Stamping the drawn occurrence
        // START keys the record on the drawn day under that reduction (the
        // START specifically: a drawn slot straddling midnight would key
        // the NEXT day if stamped from its end); a raw-seeded write keys
        // it a frame away, where those lookups don't land.
        //
        // The START must be the SELECTED occurrence's start (gh#209): for a
        // recurring series matched on a later day the selection carries the
        // expanded day-N range, and `CalendarOccurrenceKey.make` anchors a
        // series key on the caller-supplied date — stamping the template's
        // own first-day start instead would key every later-day completion
        // onto the series' first occurrence, where no reader for day N looks.
        if let active = currentlyActiveCalendarOccurrence(at: now) {
            let occurrence = CalendarEventOccurrenceContext(
                eventID: active.event.id,
                occurrenceDate: active.occurrenceRange?.start ?? now,
                occurrenceID: nil,
                isAllDay: active.event.isAllDay,
                source: .timelineTap
            )
            upsertLogRecord(for: occurrence) { record in
                record.timelineItems.append(
                    .wannaCompletion(
                        EventLogWannaCompletion(
                            wannaEventID: event.id,
                            title: event.title,
                            createdAt: now
                        )
                    )
                )
            }
        }
    }

    // MARK: - Wanna ↔ Calendar

    func pushWannaToCalendar(_ wannaEvent: Event) {
        let now = Date()
        let end = Calendar.current.date(byAdding: .hour, value: 1, to: now) ?? now
        let calendarEventId = UUID()

        let calEvent = Event(
            id: calendarEventId,
            title: wannaEvent.title,
            note: wannaEvent.note,
            timeRanges: [Event.TimeRange(start: now, end: end)],
            type: wannaEvent.type,
            linkedTodoEventId: wannaEvent.id
        )
        rawCalendarEvents.append(calEvent)
        saveCalendarEvents()

        if mutateEvent(id: wannaEvent.id, { $0.linkedCalendarEventId = calendarEventId }) {
            save()
        }
    }

    func recallWannaFromCalendar(_ wannaEvent: Event) {
        guard let linkedId = wannaEvent.linkedCalendarEventId else { return }

        // Stop timer if running
        stopTimerOnCalendarEvent(linkedId)

        // Remove the calendar event
        rawCalendarEvents.removeAll { $0.id == linkedId }
        saveCalendarEvents()

        // Unlink the wanna
        if mutateEvent(id: wannaEvent.id, { $0.linkedCalendarEventId = nil }) {
            save()
        }
    }

    func currentlyActiveCalendarEvent(at date: Date = Date()) -> Event? {
        currentlyActiveCalendarOccurrence(at: date)?.event
    }

    /// The active event PLUS the drawn occurrence range the selection was
    /// made on — the range `completeWanna` anchors its occurrence-key stamp
    /// to. Returning the event alone is not enough (gh#209): for a recurring
    /// series matched on a later day, the event's own stored ranges are only
    /// its first occurrence, so the stamp anchor must be the EXPANDED range.
    ///
    /// Selection order (frozen by
    /// `testCurrentlyActiveCalendarEventBoundaryIsClosedAndArrayOrdered`):
    /// timer event first, then a single pass over `rawCalendarEvents` in
    /// array order, first containing event wins; containment is CLOSED at
    /// both ends.
    ///
    /// Per-event containment is against the DRAWN frame, never raw storage:
    ///
    /// * A recurring series TEMPLATE is tested against its expanded
    ///   occurrence on every anchor day whose occurrence could contain
    ///   `date` — the duration-adaptive span `seriesOccurrenceProbeDays`
    ///   derives, walked most-recent-anchor FIRST. Nothing caps a recurring
    ///   primary range at a day (composer picker, `apply(to:)`, LLM intake
    ///   are all unbounded), so a fixed short probe set silently drops
    ///   instants deep inside a long occurrence; the span is exhaustive by
    ///   arithmetic instead. When a longer-than-a-day primary makes two
    ///   anchors' occurrences BOTH contain the instant, the most recent
    ///   anchor deterministically wins. This replaces raw
    ///   template-range containment, which matched only the series' first
    ///   day — and matched it even when that day's occurrence was cancelled
    ///   or detached; `recurrenceOccurrence` suppresses exception day-keys,
    ///   so a cancelled day selects nothing and a detached day is matched by
    ///   the instance event alone (never the template as well). A series
    ///   template's non-primary stored ranges never render
    ///   (`recurrenceOccurrence` is primary-only, gh#190), so they no longer
    ///   participate in containment either.
    /// * Everything else keeps render-frame containment (gh#208): the canvas
    ///   places a traveled detached instance at its projected slot, so raw
    ///   containment both misses the block the user is looking at now AND
    ///   wrongly selects an instance whose mint-frame slot happens to
    ///   straddle the current instant while its drawn block sits a day away.
    ///   Identity for anything that never traveled. The carried range is the
    ///   projected PRIMARY range — the anchor `completeWanna` has always
    ///   stamped for these events — not the specific containing range, so a
    ///   multi-range event's stamp does not move under this reshape.
    func currentlyActiveCalendarOccurrence(
        at date: Date = Date()
    ) -> (event: Event, occurrenceRange: Event.TimeRange?)? {
        // First check timer-based active event. Timer events are minted by
        // `startTimer` as fresh non-recurring events, so the primary range is
        // the right stamp anchor here by construction.
        if let timerEvent = activeTimerCalendarEvent {
            return (timerEvent, timerEvent.renderPrimaryTimeRange(calendar: .current))
        }
        let calendar = Calendar.current
        for event in rawCalendarEvents {
            if event.isRecurringSeries {
                for day in seriesOccurrenceProbeDays(containing: date, duration: event.duration, calendar: calendar) {
                    if let range = CalendarLayout.recurrenceOccurrence(for: event, on: day, calendar: calendar),
                       range.start <= date, date <= range.end {
                        return (event, range)
                    }
                }
            } else if event.renderTimeRanges(calendar: calendar).contains(where: { range in
                range.start <= date && date <= range.end
            }) {
                return (event, event.renderPrimaryTimeRange(calendar: calendar))
            }
        }
        return nil
    }

    /// Civil anchor days whose expanded occurrence could contain `date`,
    /// most recent first: every day D with
    /// `startOfDay(date - duration) <= D <= startOfDay(date)`.
    ///
    /// Exhaustive by arithmetic, not by assumption: an occurrence anchored
    /// on D starts inside D's civil day (`recurrenceOccurrence` combines
    /// D's midnight with the template's time-of-day), so
    /// `date ∈ [start, start + duration]` forces both bounds —
    /// `date >= start >= D's midnight` gives `D <= startOfDay(date)`, and
    /// `start >= date - duration` with `start` before D's next midnight
    /// gives `D >= startOfDay(date - duration)`. No anchor outside the span
    /// can contain the instant, for ANY primary duration — nothing in the
    /// app caps a recurring primary range at a day. An ALL-DAY occurrence's
    /// end is derived civilly (gh#212), so on a fall-back day it can exceed
    /// `start + duration` — by at most the accumulated DST slip inside the
    /// span, hours where the bound above has a full civil day of slack
    /// (`date - duration` lands past D's midnight by exactly that slip, so
    /// `startOfDay(date - duration)` stays at or before D); the walk still
    /// probes D.
    ///
    /// Guards, stated as invariants: a non-finite or non-positive duration
    /// collapses the span to the current day alone, and the walk is
    /// hard-capped at a month of anchors so a corrupt decoded duration
    /// cannot stall the main thread — every drawable block sits far inside
    /// both bounds.
    private func seriesOccurrenceProbeDays(
        containing date: Date,
        duration: TimeInterval,
        calendar: Calendar
    ) -> [Date] {
        let currentDay = calendar.startOfDay(for: date)
        guard duration.isFinite, duration > 0 else { return [currentDay] }
        let earliestAnchor = calendar.startOfDay(for: date.addingTimeInterval(-duration))
        var days: [Date] = []
        var day = currentDay
        while day >= earliestAnchor, days.count < 31 {
            days.append(day)
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day),
                  previous < day else { break }
            day = previous
        }
        return days
    }

    func markActive(_ event: Event) {
        guard mutateEvent(id: event.id, {
            $0.status = .active
            $0.isDone = false
            $0.completeAt = nil
        }) else { return }
        save()
    }

    @discardableResult
    func smartSplitEvent(_ event: Event, subtasks: [(title: String, portion: Double)]) -> SmartSplitUndoInfo? {
        guard subtasks.count >= 2 else { return nil }

        let originalCopy = event
        delete(event)

        var newIDs: [UUID] = []
        for st in subtasks {
            let childID = UUID()
            let child = Event(
                id: childID,
                title: st.title,
                note: event.note,
                deadline: event.deadline,
                priority: event.priority,
                tags: event.tags,
                type: event.type,
                colorDepth: event.colorDepth,
                listID: event.listID
            )
            add(child)
            newIDs.append(childID)
        }

        return SmartSplitUndoInfo(originalEvent: originalCopy, newEventIDs: newIDs)
    }

    func undoSmartSplit(_ info: SmartSplitUndoInfo) {
        for id in info.newEventIDs {
            if let child = findEvent(id: id) {
                delete(child)
            }
        }
        add(info.originalEvent)
    }

    @discardableResult
    func mergeEvents(source: Event, into target: Event) -> MergeUndoInfo {
        var merged = target

        // title: "A / B"
        merged.title = "\(target.title) / \(source.title)"

        // tags: union (deduplicated, preserving order)
        merged.tags = (target.tags + source.tags).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }

        // timeRanges: combine and sort by start
        let allRanges = target.effectiveTimeRanges + source.effectiveTimeRanges
        merged.timeRanges = allRanges.sorted { $0.start < $1.start }

        // note: concatenate non-empty with newline
        if !target.note.isEmpty && !source.note.isEmpty {
            merged.note = "\(target.note)\n\(source.note)"
        } else if !source.note.isEmpty {
            merged.note = source.note
        }

        // priority: take the larger value
        merged.priority = max(target.priority, source.priority)

        // deadline: take the later one
        switch (target.deadline, source.deadline) {
        case let (a?, b?):
            merged.deadline = max(a, b)
        case let (nil, b?):
            merged.deadline = b
        default:
            break
        }

        update(merged)
        delete(source)

        return MergeUndoInfo(sourceEvent: source, targetEvent: target, mergedEventID: merged.id)
    }

    func undoMerge(_ info: MergeUndoInfo) {
        // Restore original target event
        update(info.targetEvent)
        // Re-add original source event
        add(info.sourceEvent)
    }

    // MARK: - Timer

    var activeTimerCalendarEvent: Event? {
        rawCalendarEvents.first { $0.timerStartedAt != nil }
    }

    func isTimerRunning(for todoEvent: Event) -> Bool {
        guard let linkedId = todoEvent.linkedCalendarEventId else { return false }
        return findCalendarEvent(id: linkedId)?.timerStartedAt != nil
    }

    func startTimer(for todoEvent: Event) {
        // Stop any existing active timer first
        stopActiveTimer()

        let now = Date()
        let calendarEventId = UUID()

        // Create calendar event linked to this todo
        let calEvent = Event(
            id: calendarEventId,
            title: todoEvent.title,
            timeRanges: [Event.TimeRange(start: now, end: now)],
            type: todoEvent.type,
            timerStartedAt: now,
            linkedTodoEventId: todoEvent.id
        )
        rawCalendarEvents.append(calEvent)
        saveCalendarEvents()

        // Link todo to calendar event
        if mutateEvent(id: todoEvent.id, { $0.linkedCalendarEventId = calendarEventId }) {
            save()
        }
    }

    func stopTimer(for todoEvent: Event) {
        guard let linkedId = todoEvent.linkedCalendarEventId else { return }
        stopTimerOnCalendarEvent(linkedId)
    }

    func stopActiveTimer() {
        guard let activeEvent = activeTimerCalendarEvent else { return }
        stopTimerOnCalendarEvent(activeEvent.id)
    }

    var onCalendarEventRecordCompleted: ((Event) -> Void)?

    private func stopTimerOnCalendarEvent(_ calendarEventId: UUID) {
        let now = Date()
        guard mutateCalendarEvent(id: calendarEventId, { cal in
            // The nil-fallback only matters when `timerStartedAt` was never
            // set (e.g. `recallWannaFromCalendar` stopping a timer that
            // never ran) — `cal.primaryTimeRange` there is the RAW stored
            // instant, a frame behind the canvas's projection on a
            // traveled detached instance, and this write runs inside
            // `mutateCalendarEvent`'s rebase seam, which only rebases a
            // range that reproduces `previous.timeRanges` bit-for-bit
            // (gh#186). `renderPrimaryTimeRange` is that same projection.
            let startTime = cal.timerStartedAt ?? cal.renderPrimaryTimeRange(calendar: .current)?.start ?? now
            cal.timerStartedAt = nil
            // Deliberate REPLACE, not the tail-preserving pattern
            // `CalendarEventFormData.apply(to:)` uses (gh#189): a timer
            // stop doesn't edit one field of a multi-block event, it IS
            // the record of what happened this session -- `startTimer`
            // always creates this row fresh with exactly one range
            // (`timeRanges: [TimeRange(start: now, end: now)]`, never
            // recurring, never touched by the multi-range composer, which
            // isn't wired to calendar events at all), and nothing on any
            // live path appends ranges to it before this runs. Preserving
            // a "tail" here would mean silently gluing stray old range
            // data onto what the user experiences as a single elapsed
            // interval -- the wrong shape for what this write means.
            cal.timeRanges = [Event.TimeRange(start: startTime, end: now)]
        }) else { return }
        saveCalendarEvents()
        if let updated = findCalendarEvent(id: calendarEventId) {
            onCalendarEventRecordCompleted?(updated)
            calendarEventRecorded.send(updated)
        }
    }

    func reorderEvents(inList listID: UUID?, newOrder: [UUID]) {
        let filteredIndices = events.indices.filter {
            events[$0].listID == listID && events[$0].status == .active
        }
        guard newOrder.count == filteredIndices.count else { return }
        var reordered: [Event] = []
        reordered.reserveCapacity(newOrder.count)
        for id in newOrder {
            guard let event = findEvent(id: id) else { return }
            reordered.append(event)
        }
        for (i, globalIndex) in filteredIndices.enumerated() {
            events[globalIndex] = reordered[i]
        }
        save()
    }

    func replaceAll(_ newEvents: [Event]) {
        events = newEvents
        save()
    }

    @discardableResult
    func createInterrupt(
        parentEvent: Event,
        occurrenceDate: Date,
        title: String,
        timeRange: Event.TimeRange
    ) -> Event? {
        createInterrupt(
            parentEvent: parentEvent,
            occurrenceDate: occurrenceDate,
            title: title,
            type: nil,
            timeRange: timeRange
        )
    }

    @discardableResult
    func createInterrupt(
        parentEvent: Event,
        occurrenceDate: Date,
        title: String,
        type: String? = nil,
        timeRange: Event.TimeRange
    ) -> Event? {
        guard timeRange.end > timeRange.start else { return nil }
        // Clamp to the parent occurrence's actual range so the child always
        // overlaps with its parent. Live interrupts can outlast the parent
        // if the user holds the live session past parent end; a follow-up
        // edit that nudges the input out of range would also slip past the
        // composer's clamp. Without overlap, the timeline renders the child
        // as a standalone block, visually disconnected from its parent.
        let resolvedTimeRange: Event.TimeRange = {
            guard let parentRange = calendarOccurrenceDisplayRange(
                event: parentEvent,
                occurrenceDate: occurrenceDate
            ) else { return timeRange }
            let start = max(timeRange.start, parentRange.start)
            let end = min(timeRange.end, parentRange.end)
            return Event.TimeRange(start: start, end: end)
        }()
        guard resolvedTimeRange.end > resolvedTimeRange.start else { return nil }
        let occurrenceKey = CalendarOccurrenceKey.make(
            for: parentEvent,
            occurrenceDate: occurrenceDate
        )
        let relation = EventInterruptRelation(
            parentEventID: occurrenceKey.eventID,
            baseSeriesEventID: occurrenceKey.baseSeriesEventID,
            occurrenceDate: occurrenceKey.occurrenceDate,
            state: .embedded,
            createdAt: resolvedTimeRange.start
        )
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedType = type?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let interruptEvent = Event(
            title: trimmedTitle.isEmpty ? "Interrupt" : trimmedTitle,
            note: "",
            location: "",
            timeRanges: [resolvedTimeRange],
            type: trimmedType.isEmpty ? parentEvent.type : trimmedType,
            displayKind: .interrupt,
            interruptRelation: relation
        )
        addCalendarEvent(interruptEvent)

        let occurrence = CalendarEventOccurrenceContext(
            eventID: occurrenceKey.eventID,
            occurrenceDate: occurrenceKey.occurrenceDate,
            occurrenceID: nil,
            isAllDay: false,
            source: .timelineLongPress
        )
        upsertLogRecord(for: occurrence) { record in
            record.timelineItems.append(
                .interruptRef(
                    EventLogInterruptReference(
                        childEventID: interruptEvent.id,
                        createdAt: resolvedTimeRange.start
                    )
                )
            )
            record.timelineItems.sort { $0.createdAt > $1.createdAt }
        }
        return interruptEvent
    }

    @discardableResult
    func attachInterrupt(
        to childEventID: UUID,
        parentEvent: Event,
        occurrenceDate: Date,
        createdAt: Date? = nil,
        seedTypeTitle: String? = nil
    ) -> Bool {
        guard let child = findCalendarEvent(id: childEventID) else { return false }

        let occurrenceKey = CalendarOccurrenceKey.make(
            for: parentEvent,
            occurrenceDate: occurrenceDate
        )
        let timestamp = createdAt ?? child.primaryTimeRange?.start ?? Date()
        let relation = EventInterruptRelation(
            parentEventID: occurrenceKey.eventID,
            baseSeriesEventID: occurrenceKey.baseSeriesEventID,
            occurrenceDate: occurrenceKey.occurrenceDate,
            state: .embedded,
            createdAt: timestamp
        )
        let trimmedSeedType = seedTypeTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard mutateCalendarEvent(id: childEventID, { event in
            event.displayKind = .interrupt
            event.interruptRelation = relation
            if event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                event.title = "Interrupt"
            }
            if !trimmedSeedType.isEmpty {
                event.type = trimmedSeedType
            }
        }) else {
            return false
        }
        saveCalendarEvents(refreshInterrupts: true)

        let occurrence = CalendarEventOccurrenceContext(
            eventID: occurrenceKey.eventID,
            occurrenceDate: occurrenceKey.occurrenceDate,
            occurrenceID: nil,
            isAllDay: false,
            source: .timelineLongPress
        )
        upsertLogRecord(for: occurrence) { record in
            if !record.timelineItems.contains(where: { $0.interruptReferenceValue?.childEventID == childEventID }) {
                record.timelineItems.append(
                    .interruptRef(
                        EventLogInterruptReference(
                            childEventID: childEventID,
                            createdAt: timestamp
                        )
                    )
                )
            }
            record.timelineItems.sort { $0.createdAt > $1.createdAt }
        }
        return true
    }

    func refreshInterruptRelationState(for eventID: UUID) {
        guard let index = calendarEventIndex(id: eventID),
              let relation = rawCalendarEvents[index].interruptRelation else {
            return
        }
        let resolvedState = resolveInterruptRelationState(
            for: rawCalendarEvents[index],
            relation: relation,
            in: rawCalendarEvents
        )
        guard relation.state != resolvedState else { return }
        rawCalendarEvents[index].interruptRelation?.state = resolvedState
        saveCalendarEvents()
    }

    /// Returns whether the log slot is durable afterwards — `true` when there
    /// was nothing to prune, `true` when the prune committed, `false` when the
    /// commit failed. Callers chain it into the "may I delete the files now?"
    /// decision.
    @discardableResult
    func pruneInterruptTimelineItems(for childEventID: UUID) -> Bool {
        var didChange = false
        for index in calendarEventLogRecords.indices {
            let originalCount = calendarEventLogRecords[index].timelineItems.count
            calendarEventLogRecords[index].timelineItems.removeAll { item in
                item.interruptReferenceValue?.childEventID == childEventID
            }
            if calendarEventLogRecords[index].timelineItems.count != originalCount {
                calendarEventLogRecords[index].updatedAt = Date()
                didChange = true
            }
        }
        guard didChange else { return true }
        return saveCalendarEventLogRecords()
    }

    /// Mark this event's interrupt children orphaned, IN MEMORY. Returns
    /// whether anything changed.
    ///
    /// It does not save on purpose: its only callers are the delete paths, and
    /// they have to fold this into the single calendar commit that also
    /// removes the parent. Saving here would make a delete two calendar
    /// commits again, with a kill window in between where the children are
    /// orphaned but the parent they were orphaned from still exists.
    @discardableResult
    private func orphanInterruptChildrenInMemory(forParentDeletion event: Event) -> Bool {
        let calendar = Calendar.current
        let anchorEventID = event.isExceptionInstance
            ? (event.recurrenceParentId ?? event.id)
            : event.id
        // The day this delete owns, for a detached instance, is its NOMINAL
        // day key projected into the current frame — the same conversion the
        // record prune of this very flow makes (`recordsSurviving(afterDeleting:)`,
        // 05a3565). `startOfDay(mirror)` reinterprets a creation-frame
        // midnight through the current calendar and reads one day off after
        // travel: the classifier then marks the SERIES' surviving
        // neighbor-day children and misses the instance's own. (The final
        // persisted states are re-derived by `refreshInterruptRelationStates`
        // inside the same commit, but this classifier must not depend on
        // that coincidence to be right.) The child side still compares
        // `relation.occurrenceDate` in the current frame —
        // `EventInterruptRelation` carries no day-key field, so children
        // minted in ANOTHER frame remain the relation-side follow-up.
        let targetDay: Date = {
            if event.isExceptionInstance,
               let key = Event.resolvedRecurrenceInstanceDayKey(
                   dayKey: event.recurrenceInstanceDayKey,
                   legacyDate: event.recurrenceInstanceDate
               ),
               let nominalDay = CalendarOccurrenceKey.dayStart(forDayKey: key, in: calendar) {
                return nominalDay
            }
            return calendar.startOfDay(
                for: event.recurrenceInstanceDate
                    ?? event.primaryTimeRange?.start
                    ?? Date.distantPast
            )
        }()

        var changed = false
        for index in rawCalendarEvents.indices {
            guard var relation = rawCalendarEvents[index].interruptRelation else { continue }
            let matchesAnchor = relation.parentEventID == anchorEventID
            let matchesDay = !event.isExceptionInstance
                || calendar.isDate(relation.occurrenceDate, inSameDayAs: targetDay)
            guard matchesAnchor && matchesDay else { continue }
            if relation.state != .orphaned {
                relation.state = .orphaned
                rawCalendarEvents[index].interruptRelation = relation
                changed = true
            }
        }
        return changed
    }

    /// The recurring counterpart, also no-save; see
    /// `orphanInterruptChildrenInMemory(forParentDeletion:)`.
    @discardableResult
    private func orphanInterruptChildrenInMemory(
        forDeletedRecurringSeries seriesEvent: Event,
        occurrenceDate: Date,
        scope: Event.RecurrenceEditScope
    ) -> Bool {
        let calendar = Calendar.current
        let targetDay = calendar.startOfDay(for: occurrenceDate)
        var changed = false

        for index in rawCalendarEvents.indices {
            guard var relation = rawCalendarEvents[index].interruptRelation else { continue }
            guard relation.parentEventID == seriesEvent.id else { continue }

            let shouldOrphan: Bool
            switch scope {
            case .all:
                shouldOrphan = true
            case .single:
                shouldOrphan = calendar.isDate(relation.occurrenceDate, inSameDayAs: targetDay)
            case .following:
                shouldOrphan = relation.occurrenceDate >= targetDay
            }

            guard shouldOrphan else { continue }
            if relation.state != .orphaned {
                relation.state = .orphaned
                rawCalendarEvents[index].interruptRelation = relation
                changed = true
            }
        }

        return changed
    }

    // MARK: - Restore

    /// Apply a cloud restore snapshot to the local store. Persists each affected
    /// array exactly once after the merge. Callers should not interleave other
    /// mutations on this actor between the in-memory updates and the saves below.
    ///
    /// For `strategy == .merge` the `resolution` decides ID collisions
    /// uniformly across all tables. `perRowDecisions` overrides that on a
    /// per-row basis (per-row review path). For `.cloudOverwritesLocal` both
    /// `resolution` and `perRowDecisions` are ignored — the cloud snapshot
    /// fully replaces local state.
    func applyRestore(
        _ snapshot: RestoreSnapshot,
        strategy: RestoreStrategy,
        resolution: ConflictResolution,
        perRowDecisions: PerRowDecisions? = nil
    ) -> RestoreApplySummary {
        var summary = RestoreApplySummary()

        switch strategy {
        case .cloudOverwritesLocal:
            summary.replacedTotalCount = events.count + rawCalendarEvents.count
                + calendarEventLogRecords.count + calendarEventFeedbackRecords.count
                + todoLists.count
            events = snapshot.todoEvents
            rawCalendarEvents = snapshot.calendarEvents
            // Don't trust cloud rows wholesale — collapse any duplicate-identity
            // log/feedback rows before they enter the store (issue #26).
            calendarEventLogRecords = dedupedByIdentity(
                snapshot.logs, id: { $0.id }, updatedAt: { $0.updatedAt }
            )
            calendarEventFeedbackRecords = dedupedByIdentity(
                snapshot.feedback, id: { $0.id }, updatedAt: { $0.updatedAt }
            )
            todoLists = snapshot.todoLists

        case .merge:
            summary.addedTodoEvents = mergeByID(
                local: &events, cloud: snapshot.todoEvents,
                id: \.id, resolution: resolution,
                perRowDecisions: perRowDecisions?.todoEvents
            )
            summary.addedCalendarEvents = mergeByID(
                local: &rawCalendarEvents, cloud: snapshot.calendarEvents,
                id: \.id, resolution: resolution,
                perRowDecisions: perRowDecisions?.calendarEvents
            )
            summary.addedLogs = mergeByID(
                local: &calendarEventLogRecords, cloud: snapshot.logs,
                id: \.id, resolution: resolution,
                perRowDecisions: perRowDecisions?.logs
            )
            summary.addedFeedback = mergeByID(
                local: &calendarEventFeedbackRecords, cloud: snapshot.feedback,
                id: \.id, resolution: resolution,
                perRowDecisions: perRowDecisions?.feedback
            )
            summary.addedLists = mergeByID(
                local: &todoLists, cloud: snapshot.todoLists,
                id: \.id, resolution: resolution,
                perRowDecisions: perRowDecisions?.todoLists
            )
        }

        // A restore is semantically ONE transaction across five arrays. Under
        // UserDefaults they landed in one cfprefsd domain and a kill left a
        // clean no-op; across five files a kill in the middle leaves a
        // PERSISTENT half restore — and the next `BackupSnapshotService` pass
        // would write that half state back to the cloud, amplifying it. So the
        // merged final state is recorded first and replayed on the next launch:
        // repairable, not merely detectable, and idempotent because it writes
        // an end state rather than a delta.
        //
        // A restore is user-initiated and rare, so the extra ~1.7 MB write is
        // affordable in a way it would not be on the drag path.
        let marker = beginRestoreMarker()

        // The user just confirmed which data is authoritative, so this is the
        // only place a frozen slot may be unfrozen — and it happens INSIDE the
        // write, never by a caller remembering to ask for it. Automatic paths
        // must never unfreeze: a frozen slot presents as empty, and unfreezing
        // it automatically would let an ordinary save write that emptiness
        // down over the file we could not read.
        storageFaults.removeAll()
        writeFailedSlots.removeAll()
        storage.clearFaults()
        refreshPersistenceDegraded()

        // `persist` reports failure by RETURNING false, not by throwing — a
        // full disk or an unwritable container fails the calendar (the biggest
        // of the five, by far the likeliest) while the other four land, and
        // that half restore is on disk permanently. Dropping the marker there
        // would throw away the one thing that makes it repairable rather than
        // merely detectable, and the next `BackupSnapshotService` pass would
        // push the half state to the cloud. Same shape as the replay below.
        //
        // Keeping the marker is only safe because it EXPIRES per slot: see
        // `RestoreRedoPayload.baseSeqs`. The moment a slot is written again —
        // the retry of this restore, an ordinary save once the disk has room,
        // "erase all local data" — the marker no longer speaks for that slot.
        var wrote = true
        wrote = persist(events, to: .events, intent: .destructive) && wrote
        wrote = persist(rawCalendarEvents, to: .calendarEvents,
                        intent: .destructive, verbose: true) && wrote
        wrote = persist(calendarEventLogRecords, to: .calendarEventLogRecords, intent: .destructive) && wrote
        wrote = persist(calendarEventFeedbackRecords, to: .calendarEventFeedbackRecords, intent: .destructive) && wrote
        wrote = persist(todoLists, to: .todoLists, intent: .destructive) && wrote
        scheduleWidgetSnapshotSync()

        if let marker {
            if wrote {
                storage.clearPendingWork(marker)
            } else {
                recordPersistenceError(
                    "restore only partly written; marker KEPT so the next launch finishes it"
                )
            }
        }

        lastWrittenSnapshotHash = nil

        return summary
    }

    /// The five arrays a restore rewrites, captured as one durable payload —
    /// plus the generation each of those slots was at when the payload was
    /// written.
    ///
    /// `baseSeqs` is what bounds the marker's lifetime. A marker survives a
    /// failed write, and a marker on disk is an instruction to overwrite five
    /// slots on the next launch, so "when does it stop being true?" is not a
    /// detail — without an answer, a marker left by a full disk is a delayed
    /// bomb that reverts however many weeks of editing happened between then
    /// and the next launch. Every real write advances the slot's `seq`, so
    /// `seq == baseSeq` is exactly the statement "nothing has been written to
    /// this slot since I recorded my intent", which is precisely when
    /// replaying is a repair rather than a rollback.
    private struct RestoreRedoPayload: Codable {
        var events: [Event]
        var calendarEvents: [Event]
        var logs: [CalendarEventLogRecord]
        var feedback: [CalendarEventFeedbackRecord]
        var todoLists: [TodoList]
        /// Keyed by `StorageSlot.rawValue`. Non-optional on purpose: a payload
        /// without it cannot be replayed safely, and `Codable` failing to
        /// decode routes it to the "unreadable marker, discard" path, which is
        /// the outcome we want.
        var baseSeqs: [String: UInt64]
    }

    private static let restorePendingKind = "restore"

    /// The slots a restore rewrites, in the order it writes them.
    private static let restoreSlots: [StorageSlot] = [
        .events, .calendarEvents, .calendarEventLogRecords,
        .calendarEventFeedbackRecords, .todoLists,
    ]

    private func beginRestoreMarker() -> URL? {
        // Markers of this kind do not queue up — a newer one REPLACES every
        // older one. Each is a complete end state for the same five slots, and
        // its `baseSeqs` were captured after the previous attempt finished, so
        // they already record whatever that attempt managed to land. This
        // marker alone therefore repairs everything an older one could, which
        // makes an older one beside it not redundancy but a competing intent
        // — and two of them cannot coexist harmlessly, because replaying
        // either advances the very seqs the other's `== base` test reads. See
        // `replayPendingRestoreIfNeeded` for what that costs.
        //
        // The old ones go only AFTER the replacement is on disk. A kill in
        // that gap must leave one marker too many — which the replay is built
        // to survive — never none at all, which would lose the repair
        // outright. Same reason the `catch` below keeps them: a marker we
        // failed to write cannot supersede anything.
        let superseded = storage.pendingWork(kind: Self.restorePendingKind).map(\.url)
        do {
            let payload = RestoreRedoPayload(
                events: events, calendarEvents: rawCalendarEvents,
                logs: calendarEventLogRecords, feedback: calendarEventFeedbackRecords,
                todoLists: todoLists,
                baseSeqs: Dictionary(uniqueKeysWithValues: Self.restoreSlots.map {
                    ($0.rawValue, storage.committedSeq($0))
                })
            )
            let data = try JSONEncoder().encode(payload)
            let url = try storage.recordPendingWork(kind: Self.restorePendingKind, payload: data)
            recordPersistence("restore marker written bytes=\(data.count)"
                              + (superseded.isEmpty ? "" : " superseding=\(superseded.count)"))
            for stale in superseded { storage.clearPendingWork(stale) }
            return url
        } catch {
            // Without a marker the restore still runs; it just loses the
            // repair-on-next-launch property. Refusing the restore outright
            // would be worse.
            recordPersistenceError("restore marker could not be written: \(error)")
            return nil
        }
    }

    /// Finish a restore that was killed part-way. Runs before any slot is
    /// read, so the arrays this launch loads are already the restored ones.
    ///
    /// PER SLOT, not per marker. A restore that lost only the calendar must
    /// have only the calendar rewritten — the other four have moved on, and
    /// replaying them would undo everything the user did after the failure.
    ///
    /// NEWEST marker first, and exactly one is ever applied. `pendingWork`
    /// hands them back oldest-first, which is right for a queue of independent
    /// jobs and exactly wrong here: these are not independent, they are
    /// successive drafts of the same five-slot end state. Applying the older
    /// one first advances the seqs that the newer one's `== base` test reads,
    /// so the older draft expires the newer and the intent the user ABANDONED
    /// wins — with the five arrays then sourced from two different restores,
    /// under two possibly different strategies, silently, and pushed to the
    /// cloud by the next `BackupSnapshotService` pass. `beginRestoreMarker`
    /// normally leaves at most one marker; this is the second line, for a kill
    /// between "replacement written" and "old one deleted".
    private func replayPendingRestoreIfNeeded() {
        var applied = false
        for (url, data) in storage.pendingWork(kind: Self.restorePendingKind).reversed() {
            guard !applied else {
                // A newer marker already spoke for all five slots. It cannot
                // have left work for an older one: `seq` only ever grows, so a
                // slot the newer marker found moved on is one this older
                // marker found moved on too.
                recordPersistence("older restore marker superseded, discarding")
                storage.clearPendingWork(url)
                continue
            }
            guard let payload = try? JSONDecoder().decode(RestoreRedoPayload.self, from: data) else {
                // Deliberately does NOT set `applied`: a marker we cannot read
                // states no intent, so it must not suppress the older one it
                // was meant to replace. This is the torn write of a newer
                // marker, and the repair below it is still good.
                recordPersistenceError("restore marker unreadable, discarding")
                storage.clearPendingWork(url)
                continue
            }
            applied = true

            // A slot is stale relative to this marker as soon as ANYTHING has
            // been committed to it since the marker was written — a later
            // retry of the restore, an ordinary edit once the disk had room,
            // or "erase all local data". In all three the file is newer than
            // the payload, so the payload is history, not intent.
            func needsReplay(_ slot: StorageSlot) -> Bool {
                guard let base = payload.baseSeqs[slot.rawValue] else { return false }
                return storage.committedSeq(slot) == base
            }

            let stale = Self.restoreSlots.filter { !needsReplay($0) }
            guard stale.count < Self.restoreSlots.count else {
                recordPersistence("restore marker superseded on every slot, discarding")
                storage.clearPendingWork(url)
                continue
            }
            recordPersistence(
                "restore marker found, replaying calendar=\(payload.calendarEvents.count)"
                + (stale.isEmpty ? "" : " skipping=\(stale.map(\.rawValue).sorted().joined(separator: ","))")
            )

            var wrote = true
            func replay<Row: Codable>(_ rows: [Row], to slot: StorageSlot) {
                guard needsReplay(slot) else { return }
                wrote = persist(rows, to: slot, intent: .destructive) && wrote
            }
            replay(payload.events, to: .events)
            replay(payload.calendarEvents, to: .calendarEvents)
            replay(payload.logs, to: .calendarEventLogRecords)
            replay(payload.feedback, to: .calendarEventFeedbackRecords)
            replay(payload.todoLists, to: .todoLists)
            // Keep the marker if anything failed: the replay is idempotent and
            // now self-limiting, so trying again next launch can only help —
            // any slot that moved on in the meantime is skipped above.
            if wrote { storage.clearPendingWork(url) }
        }
    }

    /// Mutates `local` to be the merged result. Cloud rows whose ID is new are
    /// always appended (returned in `addedCount`). Collisions are resolved
    /// first via `perRowDecisions[id]` if present, then via `resolution`.
    /// `.keepLocal` leaves the local row alone, `.keepCloud` replaces it in
    /// place. Order of existing local rows is preserved.
    private func mergeByID<T, ID: Hashable>(
        local: inout [T],
        cloud: [T],
        id: KeyPath<T, ID>,
        resolution: ConflictResolution,
        perRowDecisions: [ID: ConflictResolution]? = nil
    ) -> Int {
        // `CalendarOccurrenceKey.==` for `.singleEvent` only compares the
        // eventID, so two log/feedback records pointing at the same single
        // event collide on this map. We don't want to crash on
        // `Dictionary(uniqueKeysWithValues:)` for that case — keep the first
        // occurrence's index; subsequent duplicates with the same key inherit
        // its merge decision and are left alone otherwise.
        let localIDIndex: [ID: Int] = Dictionary(
            local.enumerated().map { ($0.element[keyPath: id], $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        var added = 0
        for c in cloud {
            let cid = c[keyPath: id]
            if let idx = localIDIndex[cid] {
                let effective = perRowDecisions?[cid] ?? resolution
                if effective == .keepCloud {
                    local[idx] = c
                }
            } else {
                local.append(c)
                added += 1
            }
        }
        return added
    }
}
