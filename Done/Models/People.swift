//
//  People.swift
//  Done
//
//  Local "people" and "friend group" entities that can be bound to events,
//  answering not just what happened and when, but with whom. People are
//  app-local (no system contact sync); friend groups are quick-select
//  templates that expand to their members at bind time, so editing a group
//  later never rewrites the people already stored on past events.
//

import Foundation

/// A single person that can be bound to an event. App-local — not synced from
/// system Contacts. Deletion is a soft-archive (`isArchived`) so historical
/// events that reference this person still resolve to a name; archived people
/// just drop out of the selectable lists.
struct Person: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var colorName: String?
    var isArchived: Bool = false
    var createdAt = Date()

    /// Chip color palette, mirroring `TodoList.availableColors` so people,
    /// groups, and lists read consistently across the app.
    static let availableColors = [
        "blue", "green", "orange", "purple", "red", "pink", "teal", "indigo", "yellow", "mint"
    ]
}

/// A named collection of people (e.g. "Family", "Coworkers") used as a
/// quick-select template in the event people picker. Selecting a group adds
/// its current members' ids to the event; the group itself is not stored on
/// the event, so later membership edits do not rewrite history.
struct FriendGroup: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var memberIDs: [UUID] = []
    var colorName: String?
    var createdAt = Date()
}
