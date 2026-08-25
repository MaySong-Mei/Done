//
//  CalendarComposerDraft.swift
//  Done
//
//  Crash/kill-safe draft for the create-event composer.
//
//  The composer stages everything in view-local @State and commits only on
//  Done, so anything typed was simply lost if the session didn't reach it.
//  The draft is written:
//    - continuously, debounced, on every field change — a scene departure is
//      NOT the only kill window, and writing only there left everything typed
//      inside a live `.active` session unpersisted (a foreground crash or
//      jetsam lost all of it), and
//    - un-debounced on scene departure and on session end, since neither is
//      guaranteed to outlive the debounce window.
//  Writes are overwrite-idempotent, so phase flapping — Face ID, notification
//  pull-down — and a coalesced keystroke burst each cost exactly one write.
//
//  Content the user actually typed is destroyed only by an *explicit* end of
//  the session — Done or Cancel. An interactive swipe-down is deliberately NOT
//  explicit: on a `.medium` detent with a drag indicator it's a gesture users
//  make by accident, so it persists on the way out and stays rescuable from
//  the calendar-page banner. Process death skips the hook entirely, which is
//  exactly the case the draft exists for.
//
//  (The slot is also cleared on paths that destroy nothing the user would
//  miss: a session that owns the slot emptying its own form, the banner's
//  dismiss button, and expiry inside `loadFresh`.)
//
//  Every exit resolves through `calendarCreateDraftSlotAction` /
//  `calendarCreateDraftSessionEndAction` below — never through a hand-rolled
//  condition at the call site, or the ownership rules drift apart.
//
//  The *edit* draft below keeps the older, stricter policy (any dismissal
//  clears); the rationale for that asymmetry is at `EditCalendarEventView`'s
//  `onDraftSessionEnd` in CalendarEventSheets.swift.
//

import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Done",
    category: "ComposerDraft"
)

/// Conformance lets `calendarDraftDataPreservingUnchangedSavedAt` below read
/// and rewrite `savedAt` generically across all three draft payload types
/// instead of a hand-copied version of the same four lines per store.
private protocol CalendarDraftPayload: Codable {
    var savedAt: Date { get set }
}

/// Encodes `draft` for storage, preserving the slot's ALREADY-STORED
/// `savedAt` when `contentEqual` says the new draft is the same content as
/// what's on disk — a redundant re-save (composer reopened and immediately
/// closed with nothing typed; a scenePhase flap — Face ID, notification
/// pull-down — while the form sits untouched) must not restart the
/// `maxAge` clock for content nobody actually touched (gh#184). A REAL
/// content change still stamps the caller's fresh `savedAt`: that's what
/// lets an actively-edited draft's clock keep extending across a long
/// session, which is the point of `maxAge` measuring time-since-last-real-
/// write rather than time-since-first-write.
///
/// Every store's `save` funnels through this one function so the
/// invariant holds for every current and future caller, rather than
/// needing to be re-derived — and possibly missed — at each call site.
///
/// `contentEqual` is supplied by the caller instead of hard-coded to `==`
/// because the comparison that counts as "same content" differs per type:
/// `CalendarDetailComposerDraft` also excludes its progress fields (never
/// restored on load, so a slider-only move isn't a content change either).
/// Each store passes its own type's existing `fieldsEqual`/
/// `triggerFieldsEqual` rather than this function hand-listing fields
/// itself, so a field added to a payload later stays covered without this
/// function needing to change.
private func calendarDraftDataPreservingUnchangedSavedAt<Draft: CalendarDraftPayload>(
    _ draft: Draft,
    existingData: Data?,
    contentEqual: (Draft, Draft) -> Bool
) -> Data? {
    var draft = draft
    if let existingData,
       let existing = try? JSONDecoder().decode(Draft.self, from: existingData),
       contentEqual(existing, draft) {
        draft.savedAt = existing.savedAt
    }
    return try? JSONEncoder().encode(draft)
}

struct CalendarComposerDraft: Codable, Equatable {
    var title: String
    var kind: Event.Kind
    var deadline: Date?
    var typeTitle: String
    var isAllDay: Bool
    var startTime: Date
    var endTime: Date
    var location: String
    var note: String
    var repeatUnit: Event.RepeatUnit
    var repeatInterval: Int
    var repeatEndType: Event.RepeatEndType
    var repeatEndDate: Date?
    var repeatEndCount: Int
    var peopleIDs: [UUID]
    var savedAt: Date

    /// Whether the draft carries anything the user would miss. Type and time
    /// selections alone don't qualify — they always have defaults and are one
    /// tap to redo; resurrecting them as a "draft" would read as a bug.
    var isMeaningful: Bool {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if !peopleIDs.isEmpty { return true }
        if deadline != nil { return true }
        return false
    }

    /// Field-level equality ignoring `savedAt` — the identity question for
    /// drafts is "same content?", never "same write moment?".
    func fieldsEqual(_ other: CalendarComposerDraft) -> Bool {
        var a = self
        var b = other
        a.savedAt = .distantPast
        b.savedAt = .distantPast
        return a == b
    }

    /// The form-relevant field snapshot of an existing event, mirroring
    /// exactly how `EditCalendarEventView` seeds the form. Used as the edit
    /// draft's base fingerprint: if the event no longer matches the base the
    /// draft was taken against, the draft is stale and must be discarded.
    ///
    /// `startTime`/`endTime` read `renderPrimaryTimeRange(calendar:)`, not
    /// raw `timeRanges` — this is only ever called where `draftable` in
    /// `EditCalendarEventView` gates it (`!event.isRecurringSeries &&
    /// recurrenceScope == nil`), the same condition under which
    /// `EditCalendarEventView.occurrenceSeedRange` falls through to that same
    /// projection. Reading raw `timeRanges` here instead would fingerprint a
    /// traveled detached instance against a value the seeded form never
    /// shows, so `fieldsEqual` reads "changed" on a session nothing touched.
    static func snapshot(of event: Event, savedAt: Date = Date(), calendar: Calendar = .current) -> CalendarComposerDraft {
        let seedRange = event.renderPrimaryTimeRange(calendar: calendar)
        return CalendarComposerDraft(
            title: event.title,
            kind: event.kind,
            deadline: event.deadline,
            typeTitle: event.type,
            isAllDay: event.isAllDay,
            startTime: seedRange?.start ?? Date(),
            endTime: seedRange?.end ?? Date().addingTimeInterval(3600),
            location: event.location,
            note: event.note,
            repeatUnit: event.repeatUnit,
            repeatInterval: event.repeatInterval,
            repeatEndType: event.repeatEndType,
            // Same normalization the form applies on its side: an end date is
            // only meaningful under .onDate. Events can legitimately carry a
            // leftover date under another end type (set → flipped back), and
            // without this the fingerprint would read "changed" for a session
            // the user never touched.
            repeatEndDate: event.repeatEndType == .onDate ? event.repeatEndDate : nil,
            repeatEndCount: event.repeatEndCount ?? 10,
            peopleIDs: event.peopleIDs ?? [],
            savedAt: savedAt
        )
    }

    /// A draft only auto-fills a composer that opened *empty*. When the
    /// caller supplied content (reminder → event prefill, agentic intake),
    /// that intent is fresher than the draft and must win untouched.
    static func callerProvidedContent(
        initialTitle: String,
        initialNote: String,
        initialLocation: String,
        hasAgenticIntake: Bool
    ) -> Bool {
        if hasAgenticIntake { return true }
        if !initialTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if !initialNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if !initialLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return false
    }
}

/// Kill-safe draft for an *edit* session on an existing event.
///
/// Unlike the create draft, resurrecting edits is only safe when the event
/// still looks exactly like it did when the session started — an event
/// changed by any other path (drag on the canvas, another edit, a restore)
/// makes the stashed edits stale, and silently applying them would corrupt
/// data the user believes is settled. `base` carries the field snapshot the
/// session started from; restore requires it to still match the live event.
/// Recurring scope edits are never drafted (scope-aware apply cannot be
/// meaningfully resumed against a mutated series).
struct CalendarEditDraft: Codable, Equatable {
    var eventID: UUID
    var base: CalendarComposerDraft
    var edited: CalendarComposerDraft
    var savedAt: Date

    /// Content equality ignoring every `savedAt` in the payload — this
    /// wrapper's own, and `base`/`edited`'s nested ones — for the store's
    /// save-time savedAt-preservation check. Delegates to
    /// `CalendarComposerDraft.fieldsEqual` one level down rather than
    /// re-freezing the nested `savedAt` fields by hand, so a field added
    /// there stays covered here automatically.
    func fieldsEqual(_ other: CalendarEditDraft) -> Bool {
        eventID == other.eventID && base.fieldsEqual(other.base) && edited.fieldsEqual(other.edited)
    }
}

extension CalendarComposerDraft: CalendarDraftPayload {}
extension CalendarEditDraft: CalendarDraftPayload {}
extension CalendarDetailComposerDraft: CalendarDraftPayload {}

enum CalendarEditDraftStore {
    static let storageKey = "calendarComposerEditDraft"
    static let maxAge: TimeInterval = CalendarComposerDraftStore.maxAge

    static func save(_ draft: CalendarEditDraft, defaults: UserDefaults = .standard) {
        guard let data = calendarDraftDataPreservingUnchangedSavedAt(
            draft,
            existingData: defaults.data(forKey: storageKey),
            contentEqual: { $0.fieldsEqual($1) }
        ) else { return }
        defaults.set(data, forKey: storageKey)
    }

    /// Returns the stashed edits for `eventID` if the slot holds them, they
    /// are fresh, and `current` still matches the draft's base snapshot.
    ///
    /// Clearing policy: only undecodable/stale blobs are cleared. A draft
    /// for a *different* event is left intact (opening event B must not
    /// destroy event A's pending rescue), and a base-mismatch draft is left
    /// too — see the guard below for why clearing there would be unsafe.
    static func loadFresh(
        eventID: UUID,
        current: CalendarComposerDraft,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> CalendarComposerDraft? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        guard let draft = try? JSONDecoder().decode(CalendarEditDraft.self, from: data) else {
            logger.error("edit loadFresh: undecodable blob — clearing")
            clear(defaults: defaults)
            return nil
        }
        let age = now.timeIntervalSince(draft.savedAt)
        guard age <= maxAge, age >= -60 else {
            logger.log("edit loadFresh: stale draft (ageSec=\(Int(age), privacy: .public)) — clearing")
            clear(defaults: defaults)
            return nil
        }
        guard draft.eventID == eventID else { return nil }
        guard draft.base.fieldsEqual(current) else {
            // Return nil WITHOUT clearing: this runs from view init, which
            // SwiftUI re-evaluates on every parent invalidation, and mid-
            // session an externally-moved event (domino push, sync) would
            // otherwise clear a rescue this very session just wrote. A
            // mismatched draft can never restore anyway; it dies by expiry
            // or the next session's write.
            logger.log("edit loadFresh: event \(eventID, privacy: .public) changed since the draft's base — stale edits not restored")
            return nil
        }
        return draft.edited
    }

    /// Session-scoped clear: only removes the slot when it belongs to
    /// `eventID`, so ending one event's edit session can't destroy a rescue
    /// pending for another.
    static func clear(eventID: UUID, defaults: UserDefaults = .standard) {
        guard let data = defaults.data(forKey: storageKey),
              let draft = try? JSONDecoder().decode(CalendarEditDraft.self, from: data),
              draft.eventID == eventID
        else { return }
        clear(defaults: defaults)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}

/// Kill-safe draft for the detail page's interrupt/parallel mini-composers.
/// Single slot, keyed by occurrence + mode; restored only when the *same*
/// composer reopens on the *same* occurrence. Editing an existing interrupt
/// is never drafted (same conflict rationale as event edit drafts).
struct CalendarDetailComposerDraft: Codable, Equatable {
    enum Mode: String, Codable {
        case interrupt
        case parallel
    }

    var mode: Mode
    var occurrenceKey: String
    var title: String
    var typeTitle: String
    var note: String
    var didExplicitlySelectType: Bool
    var startProgress: Double
    var endProgress: Double
    var savedAt: Date

    /// Typed content only — a repositioned slider or default type alone is
    /// one gesture to redo and not worth resurrecting.
    var isMeaningful: Bool {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return false
    }

    /// Field-level equality for the continuous-write trigger, ignoring the
    /// two kinds of field that must never be able to move a trigger built
    /// from this comparison: `savedAt` (a write moment, not content — two
    /// drafts differing only in when they were captured are the same
    /// draft) and `startProgress`/`endProgress` (deliberately never
    /// restored — see `beginAddingInterruptFromDetail`/
    /// `beginAddingParallelFromDetail` in CalendarEventDetailView — so a
    /// trigger built from a value that moves with them would put a
    /// UserDefaults write on a slider-drag hot path for a value nobody
    /// reads back). The saved payload still carries both; only this
    /// comparison ignores them.
    ///
    /// Same technique as `fieldsEqual` above — freeze the excluded fields on
    /// two copies and defer to the synthesized `==` — rather than a
    /// hand-written list of the included ones, so a field added to this
    /// struct later automatically participates here too instead of silently
    /// going untracked by the trigger.
    ///
    /// `nonisolated`: this struct defaults to the module's main-actor
    /// isolation, but `CalendarDetailComposerDraftFingerprint` (which calls
    /// this from its own `nonisolated` `==`) needs it callable outside that
    /// isolation — see the note there.
    nonisolated func triggerFieldsEqual(_ other: CalendarDetailComposerDraft) -> Bool {
        var a = self
        var b = other
        a.savedAt = .distantPast
        b.savedAt = .distantPast
        a.startProgress = 0
        b.startProgress = 0
        a.endProgress = 0
        b.endProgress = 0
        return a == b
    }
}

enum CalendarDetailComposerDraftStore {
    static let storageKey = "calendarDetailComposerDraft"
    static let maxAge: TimeInterval = CalendarComposerDraftStore.maxAge

    static func save(_ draft: CalendarDetailComposerDraft, defaults: UserDefaults = .standard) {
        guard let data = calendarDraftDataPreservingUnchangedSavedAt(
            draft,
            existingData: defaults.data(forKey: storageKey),
            contentEqual: { $0.triggerFieldsEqual($1) }
        ) else { return }
        defaults.set(data, forKey: storageKey)
    }

    /// Undecodable/stale blobs are cleared; a draft for a different
    /// occurrence or mode is left intact and just not returned.
    static func loadFresh(
        mode: CalendarDetailComposerDraft.Mode,
        occurrenceKey: String,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> CalendarDetailComposerDraft? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        guard let draft = try? JSONDecoder().decode(CalendarDetailComposerDraft.self, from: data) else {
            clear(defaults: defaults)
            return nil
        }
        let age = now.timeIntervalSince(draft.savedAt)
        guard age <= maxAge, age >= -60 else {
            clear(defaults: defaults)
            return nil
        }
        guard draft.mode == mode, draft.occurrenceKey == occurrenceKey, draft.isMeaningful else {
            return nil
        }
        return draft
    }

    /// Session-scoped clear — ending one composer session can't destroy a
    /// rescue stashed for a different occurrence.
    static func clear(
        mode: CalendarDetailComposerDraft.Mode,
        occurrenceKey: String,
        defaults: UserDefaults = .standard
    ) {
        guard let data = defaults.data(forKey: storageKey),
              let draft = try? JSONDecoder().decode(CalendarDetailComposerDraft.self, from: data),
              draft.mode == mode, draft.occurrenceKey == occurrenceKey
        else { return }
        clear(defaults: defaults)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}

enum CalendarComposerDraftStore {
    static let storageKey = "calendarComposerCreateDraft"

    /// Calendar drafts go stale fast — the times in them are near-term. A
    /// draft surfacing three weeks later would be reported as a bug, not
    /// thanked as a rescue.
    static let maxAge: TimeInterval = 48 * 60 * 60

    static func save(_ draft: CalendarComposerDraft, defaults: UserDefaults = .standard) {
        guard let data = calendarDraftDataPreservingUnchangedSavedAt(
            draft,
            existingData: defaults.data(forKey: storageKey),
            contentEqual: { $0.fieldsEqual($1) }
        ) else { return }
        defaults.set(data, forKey: storageKey)
    }

    /// Returns the stored draft if it is fresh and meaningful; clears and
    /// returns nil otherwise, so an expired blob can't resurface later.
    static func loadFresh(now: Date = Date(), defaults: UserDefaults = .standard) -> CalendarComposerDraft? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        guard let draft = try? JSONDecoder().decode(CalendarComposerDraft.self, from: data) else {
            logger.error("loadFresh: undecodable blob (\(data.count, privacy: .public) bytes) — clearing")
            clear(defaults: defaults)
            return nil
        }
        let age = now.timeIntervalSince(draft.savedAt)
        guard draft.isMeaningful, age <= maxAge, age >= -60 else {
            // age < -60: savedAt in the future means the wall clock moved.
            logger.log("loadFresh: rejecting draft (meaningful=\(draft.isMeaningful, privacy: .public) ageSec=\(Int(age), privacy: .public)) — clearing")
            clear(defaults: defaults)
            return nil
        }
        return draft
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}

/// Cadence shared by every composer's continuous draft write (the create
/// form and the detail page's interrupt/parallel composers) so the two
/// cannot silently retune apart from each other.
///
/// `nonisolated` for the same reason as `CalendarComposerDraftWriteDecision`
/// below, which reads these constants: pure value logic the tests call from
/// a nonisolated context.
nonisolated enum CalendarComposerDraftCadence {
    /// How long a keystroke burst is allowed to sit unpersisted before the
    /// trailing debounce writes it. Short enough that a crash costs at most
    /// a brief burst of typing; long enough that ordinary pauses between
    /// words don't each cost a write. Continuous typing past this window is
    /// `maxWait`'s job, not this one's.
    static var debounce: Duration { .milliseconds(400) }

    /// Ceiling on how long *continuous* typing may defer a write. A pure
    /// trailing debounce never fires while the user keeps typing, so a long
    /// uninterrupted paragraph would sit entirely unpersisted — exactly the
    /// loss this whole mechanism exists to prevent.
    static var maxWait: TimeInterval { 2.0 }
}

/// What a scheduled continuous write should do right now.
///
/// `nonisolated` alongside `CalendarComposerDraftSlotAction` below, for the
/// same reason: pure value logic the tests call from a nonisolated context.
nonisolated enum CalendarComposerDraftWriteDecision: Equatable {
    /// Write immediately — no debounce. Fires on the first change of a
    /// session (nothing to coalesce with yet) and once `maxWait` has elapsed
    /// since the last write (a continuous typing burst must still land).
    case writeThrough
    /// Start, or restart, the trailing debounce.
    case debounce
}

/// The continuous-write cadence decision, pure over the elapsed time since
/// the composer session's slot was last written.
///
/// `wasIdle` is "first change of a session," expressed as an observable
/// fact instead of session bookkeeping: a caller whose trigger fingerprint
/// has an idle sentinel (a composer with nothing open, or nothing worth
/// protecting yet) can pass whether the *previous* fingerprint was that
/// sentinel, and a session's first meaningful content is exactly the
/// transition out of it — true regardless of how recently some earlier,
/// already-ended session wrote `lastPersistAt`, so no explicit reset is
/// needed at session start. Callers with no such notion of idle (the
/// create-form draft is staged for exactly one session per view instance)
/// simply never pass `true` and fall through to the `lastPersistAt`
/// arithmetic, which already covers their "first change" case via `nil`.
///
/// Absent `wasIdle`, `lastPersistAt == nil` means this session has never
/// written the slot — that is also "first change of a session" and always
/// writes through.
nonisolated func calendarComposerDraftWriteDecision(
    lastPersistAt: Date?,
    now: Date = Date(),
    wasIdle: Bool = false
) -> CalendarComposerDraftWriteDecision {
    guard !wasIdle else { return .writeThrough }
    guard let lastPersistAt else { return .writeThrough }
    let elapsed = now.timeIntervalSince(lastPersistAt)
    return elapsed >= CalendarComposerDraftCadence.maxWait ? .writeThrough : .debounce
}

/// What a create-composer session should do to the single create-draft slot.
///
/// `nonisolated` here and on the two policy functions below: they are pure
/// value logic with no actor needs, and leaving them on the module's default
/// main-actor isolation makes the synthesized `Equatable` conformance isolated
/// too, which the tests can't use from a nonisolated context.
nonisolated enum CalendarComposerDraftSlotAction: Equatable {
    /// Write the snapshot — there's content the user would miss.
    case save
    /// Remove the slot — this session owns it and has nothing worth keeping.
    case clear
    /// Touch nothing — this session never owned the slot, and a rescue
    /// pending from an earlier session must survive it.
    case leaveAlone
}

/// The create slot's write policy for one snapshot. The continuous write, the
/// scene-departure flush and the swipe-down flush all resolve through here so
/// the three can't drift apart.
nonisolated func calendarCreateDraftSlotAction(
    snapshotIsMeaningful: Bool,
    resumesDraft: Bool,
    wroteDraftSlot: Bool
) -> CalendarComposerDraftSlotAction {
    if snapshotIsMeaningful { return .save }
    // An emptied form must not resurrect a draft this session owns — but an
    // untouched session's flap must not clear a rescue it never displayed.
    return (resumesDraft || wroteDraftSlot) ? .clear : .leaveAlone
}

/// The policy for the end of a create session (`onDisappear`).
///
/// `pendingSnapshotIsMeaningful` is nil when the session ended *explicitly*
/// (Done or Cancel) and non-nil when it ended *ambiguously* — an interactive
/// swipe-down — carrying whether the abandoned form held anything.
///
/// The asymmetry is the point: a swipe-down on a `.medium` detent is a gesture
/// users make by accident, not a decision to discard, so it persists on the
/// way out exactly like any other snapshot and stays rescuable from the
/// calendar-page banner. Only Done and Cancel may destroy typed content.
nonisolated func calendarCreateDraftSessionEndAction(
    pendingSnapshotIsMeaningful: Bool?,
    usesDraftSlot: Bool,
    resumesDraft: Bool,
    wroteDraftSlot: Bool
) -> CalendarComposerDraftSlotAction {
    if let pendingSnapshotIsMeaningful, usesDraftSlot {
        return calendarCreateDraftSlotAction(
            snapshotIsMeaningful: pendingSnapshotIsMeaningful,
            resumesDraft: resumesDraft,
            wroteDraftSlot: wroteDraftSlot
        )
    }
    // Explicit end: only a session that consumed the slot (banner resume) or
    // wrote it may clear it. `resumesDraft` is qualified by `usesDraftSlot`
    // because restoring is gated on BOTH — a resuming session that carries
    // caller prefill never actually displayed the slot's content, so clearing
    // it would destroy a rescue the user was never shown.
    return ((resumesDraft && usesDraftSlot) || wroteDraftSlot) ? .clear : .leaveAlone
}
