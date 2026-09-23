//
//  StorageSlot.swift
//  Done
//
//  The eight arrays that make up the user's irreplaceable local data.
//

import Foundation

/// One durable array. The raw value doubles as the legacy `UserDefaults` key
/// so migration needs no mapping table — the keys and the slots were always
/// the same names, and keeping them literally identical is what makes the
/// read-through migration funnel a two-line thing.
enum StorageSlot: String, CaseIterable {
    /// Todo events (the todo list, not the calendar).
    case events
    /// The calendar. 1.25 MB / 2690 rows on the dogfood device — the reason
    /// this whole layer exists.
    case calendarEvents
    case calendarEventFeedbackRecords
    case calendarEventLogRecords
    case todoLists
    case people
    case friendGroups
    case reminders

    /// Byte-for-byte the key this array lived under in `UserDefaults`.
    var legacyDefaultsKey: String { rawValue }
    var filename: String { rawValue + ".json" }
    var backupFilename: String { rawValue + ".bak" }
    /// The write-ahead delta log beside the slot file (gh#235). Only
    /// `.calendarEvents` writes one today, but the name is DERIVED for every
    /// slot on purpose: `DurableEventStorage.sweepUnknownEntries` builds its
    /// whitelist by walking `allCases` and asking each slot for its filenames,
    /// so a future slot that starts logging is whitelisted the moment it does
    /// — rather than having its deltas silently deleted on the next cold
    /// launch by a hand-written string constant that nobody updated.
    var deltaFilename: String { rawValue + ".log" }
}
