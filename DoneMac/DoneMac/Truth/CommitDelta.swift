//
//  CommitDelta.swift
//  DoneMac
//
//  The change signal on the truth (#219 concept 3, designed in from day
//  one). Every mutation of MacEventStore emits exactly one CommitDelta;
//  "did anything change" is answered by comparing StoreRevision values,
//  never by diffing arrays.
//

import Foundation

/// A civil day, the invalidation unit of the calendar projection layer.
struct DayKey: Hashable, Comparable, Codable, Sendable {
    var year: Int
    var month: Int
    var day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0)
    }

    func startOfDay(calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    static func < (lhs: DayKey, rhs: DayKey) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// Every civil day a time range touches, endpoints inclusive. The end
    /// day is included even when the range ends exactly at midnight —
    /// over-invalidating one day is safe, silently missing one is not.
    static func keys(spanning range: Event.TimeRange, calendar: Calendar) -> Set<DayKey> {
        guard range.end >= range.start else {
            return [DayKey(date: range.start, calendar: calendar)]
        }
        var keys = Set<DayKey>()
        var cursor = calendar.startOfDay(for: range.start)
        let last = calendar.startOfDay(for: range.end)
        // Bounded walk: a pathological range (decoded garbage) must not
        // spin forever; 400 days covers every legitimate span today.
        var steps = 0
        while cursor <= last && steps < 400 {
            keys.insert(DayKey(date: cursor, calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
            steps += 1
        }
        keys.insert(DayKey(date: range.end, calendar: calendar))
        return keys
    }

    static func keys(of event: Event, calendar: Calendar) -> Set<DayKey> {
        event.timeRanges.reduce(into: Set<DayKey>()) { acc, range in
            acc.formUnion(keys(spanning: range, calendar: calendar))
        }
    }
}

/// O(1) "has anything changed" — one monotonic generation per slot.
struct StoreRevision: Equatable, Sendable {
    private(set) var generations: [StorageSlot: UInt64] = [:]

    subscript(slot: StorageSlot) -> UInt64 {
        get { generations[slot] ?? 0 }
        set { generations[slot] = newValue }
    }

    mutating func bump(_ slot: StorageSlot) -> UInt64 {
        let next = self[slot] &+ 1
        self[slot] = next
        return next
    }
}

/// What one commit changed. `affectedDayKeys == nil` means "everything"
/// (bulk operations: restore, wipe) — the rare case, never the default.
struct CommitDelta: Sendable {
    let slot: StorageSlot
    let generation: UInt64
    let changedIDs: Set<UUID>
    let affectedDayKeys: Set<DayKey>?
}

/// What a recipient signed up for (#219 concept 1: observation has
/// enumerable recipients). `dayKeys == nil` means "all days in the slot".
struct StoreInterest: Sendable {
    var slots: Set<StorageSlot>
    var dayKeys: Set<DayKey>?

    init(slots: Set<StorageSlot>, dayKeys: Set<DayKey>? = nil) {
        self.slots = slots
        self.dayKeys = dayKeys
    }

    func matches(_ delta: CommitDelta) -> Bool {
        guard slots.contains(delta.slot) else { return false }
        guard let dayKeys else { return true }
        guard let affected = delta.affectedDayKeys else { return true }
        return !dayKeys.isDisjoint(with: affected)
    }
}
