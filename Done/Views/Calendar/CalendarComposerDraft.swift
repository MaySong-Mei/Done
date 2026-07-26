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
