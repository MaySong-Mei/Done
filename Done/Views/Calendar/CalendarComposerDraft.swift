//
//  CalendarComposerDraft.swift
//  Done
//
//  Crash/kill-safe draft for the create-event composer.
//
//  The composer stages everything in view-local @State and commits only on
//  Done. `onDisappear` does not fire when the app is backgrounded or the
//  process is killed, so anything typed was simply lost. The draft is the
//  smallest fix that respects both sides of that trade:
//    - it is written on every scenePhase departure (overwrite semantics, so
//      phase flapping — Face ID, notification pull-down — is harmless), and
//    - it is cleared on any *explicit* end of the composer session (Done,
//      Cancel, swipe-down all pass through onDisappear). Only a path where
//      onDisappear never ran — process death — leaves a draft behind, which
//      is exactly the case the draft exists for.
//

import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Done",
    category: "ComposerDraft"
)

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
    static func snapshot(of event: Event, savedAt: Date = Date()) -> CalendarComposerDraft {
        CalendarComposerDraft(
            title: event.title,
            kind: event.kind,
            deadline: event.deadline,
            typeTitle: event.type,
            isAllDay: event.isAllDay,
            startTime: event.timeRanges.first?.start ?? Date(),
            endTime: event.timeRanges.first?.end ?? Date().addingTimeInterval(3600),
            location: event.location,
            note: event.note,
            repeatUnit: event.repeatUnit,
            repeatInterval: event.repeatInterval,
            repeatEndType: event.repeatEndType,
            repeatEndDate: event.repeatEndDate,
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
}

enum CalendarEditDraftStore {
    static let storageKey = "calendarComposerEditDraft"
    static let maxAge: TimeInterval = CalendarComposerDraftStore.maxAge

    static func save(_ draft: CalendarEditDraft, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(draft) else { return }
        defaults.set(data, forKey: storageKey)
    }

    /// Returns the stashed edits for `eventID` if the slot holds them, they
    /// are fresh, and `current` still matches the draft's base snapshot.
    ///
    /// Clearing policy: undecodable/stale blobs and base-mismatch drafts are
    /// dead and cleared; a draft for a *different* event is left intact —
    /// opening event B must not destroy event A's pending rescue.
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
            logger.log("edit loadFresh: event \(eventID, privacy: .public) changed since the draft's base — discarding stale edits")
            clear(defaults: defaults)
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
}

enum CalendarDetailComposerDraftStore {
    static let storageKey = "calendarDetailComposerDraft"
    static let maxAge: TimeInterval = CalendarComposerDraftStore.maxAge

    static func save(_ draft: CalendarDetailComposerDraft, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(draft) else { return }
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
        guard let data = try? JSONEncoder().encode(draft) else { return }
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
