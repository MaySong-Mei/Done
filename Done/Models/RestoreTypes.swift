//
//  RestoreTypes.swift
//  Done
//
//  Restore-domain vocabulary consumed by the model stores' applyRestore
//  APIs (EventStore, EventTypeTemplateStore, SkillInsight, SyncedSettings).
//  Lives in Models so UIKit-free targets compile it without the
//  EventStore-coupled RestoreCoordinator.
//

import Foundation

/// How a restored cloud snapshot is reconciled with the device's current data.
/// `cloudOverwritesLocal` is destructive; `merge` is additive with user-chosen
/// resolution for ID collisions.
enum RestoreStrategy {
    /// Union of local + cloud. New cloud rows (no ID match locally) are always
    /// added. Rows with the same ID on both sides are "conflicts" — the user
    /// chooses how to resolve them via `ConflictResolution`.
    case merge

    /// Discard local data and replace with the cloud snapshot. Use only when the
    /// user explicitly wants to restore a fresh device from cloud backup.
    case cloudOverwritesLocal
}

/// How to resolve same-ID collisions during a merge. Can be applied uniformly
/// (batch path) or per-row (review-each path) via `PerRowDecisions`.
enum ConflictResolution: Equatable, Hashable {
    case keepLocal
    case keepCloud
}

/// The deletes this device made that have not reached the cloud yet, as a
/// merge restore needs them (`SupabaseSyncService.pendingDeletes(in:…)`
/// says where they come from). A merge leaves the snapshot's rows with
/// these ids out, so what the user deleted here stays deleted, and the
/// replay keeps their baseline entries, so the delete still goes up. A
/// cloud-overwrites-local restore ignores all of it — there the cloud's
/// copy wins.
///
/// The typed sets are the snapshot rows the merge leaves out, per table.
/// Event types are matched by id here although a merge matches them by
/// title: a type the user deleted stays deleted even when a local type now
/// carries the same title.
struct RestorePendingDeletes: Equatable {
    var todoEvents: Set<UUID> = []
    var calendarEvents: Set<UUID> = []
    var logs: Set<CalendarOccurrenceKey> = []
    var feedback: Set<CalendarOccurrenceKey> = []
    var todoLists: Set<UUID> = []
    var eventTypes: Set<UUID> = []
    var skills: Set<UUID> = []
    /// Every pending delete, whether the snapshot carried the row or not:
    /// the ids as the baseline keys them, by baseline table. The entries
    /// the replay keeps (`SupabaseSyncService.markRestoreCompleted`).
    var baselineIds: [String: Set<String>] = [:]

    static let none = RestorePendingDeletes()

    /// The snapshot rows the merge leaves out.
    var totalCount: Int {
        todoEvents.count + calendarEvents.count + logs.count + feedback.count
            + todoLists.count + eventTypes.count + skills.count
    }
}
