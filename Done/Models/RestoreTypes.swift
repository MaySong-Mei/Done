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
