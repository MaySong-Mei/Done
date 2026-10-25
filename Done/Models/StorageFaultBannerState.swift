//
//  StorageFaultBannerState.swift
//  Done
//
//  Moved verbatim out of ContentView.swift: the Mac window raises the same
//  persistence-degraded banner from the same predicate.
//

import Foundation

/// What the persistence-degraded banner says, extracted from the view so it
/// can be TESTED.
///
/// The bug this exists to stop is not a wrong boolean, it is a store missing
/// from the list. `AgentConversationRepository.isDegraded` was written, was
/// correct, and had zero consumers — a freeze that protected the cloud copy
/// and said nothing to the user — and nothing could have caught that while the
/// predicate lived inside a `private struct: View` where no test can reach it.
/// One place, reachable, so "is this store in the list at all?" is a question
/// with an answer.
struct StorageFaultBannerState {
    /// Anything at all is not saving faithfully.
    let isDegraded: Bool

    /// "Could not be read" outranks "a save did not complete": the first is
    /// the one where data the user cannot see still exists on disk, and the
    /// advice (restart, then restore) is different.
    let isUnreadable: Bool

    init(store: EventStore,
         eventTypeStore: EventTypeTemplateStore,
         conversations: AgentConversationRepository,
         occurrenceKeyMetadata: OccurrenceKeyMetadataStore) {
        // The zone store's input is deliberately the SAME predicate the
        // exporters gate on (`suppressesSettingsUpload`), not `isFrozen`:
        // a readable file holding an identifier this OS does not know is not
        // frozen, yet it suppresses every settings upload and every local DR
        // snapshot exactly like the unreadable case — and a banner keyed off
        // a narrower predicate than the suppression would leave the user's
        // offline backup silently stale with nothing on screen.
        isDegraded = !store.storageFaults.isEmpty
            || store.persistenceDegraded
            || eventTypeStore.isCatalogDegraded
            || conversations.isDegraded
            || occurrenceKeyMetadata.suppressesSettingsUpload
        isUnreadable = !store.storageFaults.isEmpty
            || eventTypeStore.isCatalogFrozen
            || conversations.isFrozen
            || occurrenceKeyMetadata.suppressesSettingsUpload
    }
}
