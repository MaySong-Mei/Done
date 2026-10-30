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

/// The rows of a cloud snapshot whose id this device deleted without the
/// delete having reached the cloud yet, per table. A merge restore leaves
/// them out: what the user deleted here stays deleted, and the delete still
/// goes up (`SupabaseSyncService.pendingDeletes(in:…)` says where the set
/// comes from). A cloud-overwrites-local restore ignores it — there the
/// cloud's copy wins.
///
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

    static let none = RestorePendingDeletes()

    var totalCount: Int {
        todoEvents.count + calendarEvents.count + logs.count + feedback.count
            + todoLists.count + eventTypes.count + skills.count
    }
}
