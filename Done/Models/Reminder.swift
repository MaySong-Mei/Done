//
//  Reminder.swift
//  Done
//
//  A lightweight, Apple-Reminders-style todo shown in the pull-down panel at
//  the top of the calendar. Distinct from `Event(kind: .todo)` — a reminder is
//  a standalone checklist item that can be turned into a scheduled `Event` via
//  "Add to Schedule". App-local; not part of cloud sync (mirrors People).
//
//  Carry-over rule: an incomplete reminder keeps showing every day until done.
//  A completed reminder only shows (with its done state) on the day it was
//  completed — `completedAt` drives both the same-day visibility and the
//  next-day prune. See `EventStore.visibleReminders` / `pruneStaleReminders`.
//

import Foundation

struct Reminder: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var note: String = ""
    var isCompleted: Bool = false
    var completedAt: Date? = nil
    var createdAt = Date()
}
