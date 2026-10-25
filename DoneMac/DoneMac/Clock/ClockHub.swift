//
//  ClockHub.swift
//  DoneMac
//
//  The one clock (#219 concept 2's delivery half: `now` is an input that
//  ticks, not something consumers poll). Consumers register a granularity;
//  the hub fires them on bucket boundaries and suspends entirely while the
//  window is occluded. No consumer owns a Timer — the census of everything
//  time-driven in the app is `entries`.
//
//  Tests drive `pump(now:)` directly; production drives it from a single
//  DispatchSourceTimer scheduled to the nearest next boundary.
//

import Foundation

enum ClockGranularity: CaseIterable, Sendable, Hashable {
    case thirtySeconds
    case minute
    case day

    /// Bucket identity for a moment. Two dates in the same bucket never
    /// fire a tick between them.
    func bucketIndex(for date: Date, calendar: Calendar) -> Int {
        switch self {
        case .thirtySeconds:
            return Int(floor(date.timeIntervalSinceReferenceDate / 30))
        case .minute:
            return Int(floor(date.timeIntervalSinceReferenceDate / 60))
        case .day:
            let key = DayKey(date: date, calendar: calendar)
            return key.year * 10_000 + key.month * 100 + key.day
        }
    }

    /// First moment strictly after `date` that starts a new bucket.
    /// Day boundaries go through Calendar so DST days stay correct.
    func nextBoundary(after date: Date, calendar: Calendar) -> Date {
        switch self {
        case .thirtySeconds:
            let t = date.timeIntervalSinceReferenceDate
            return Date(timeIntervalSinceReferenceDate: (floor(t / 30) + 1) * 30)
        case .minute:
            let t = date.timeIntervalSinceReferenceDate
            return Date(timeIntervalSinceReferenceDate: (floor(t / 60) + 1) * 60)
        case .day:
            let startToday = calendar.startOfDay(for: date)
            return calendar.date(byAdding: .day, value: 1, to: startToday)
                ?? date.addingTimeInterval(86_400)
        }
    }
}

@MainActor
final class ClockHub {
    private struct Entry {
        let id: UUID
        let granularity: ClockGranularity
        let handler: (Date) -> Void
    }

    private var entries: [Entry] = []
    private var lastBucket: [ClockGranularity: Int] = [:]
    private(set) var isOccluded = false
    private var timer: DispatchSourceTimer?
    private var calendar: Calendar
    private let bill: MacWorkBill?
    /// Production: true → pump() reschedules a real timer. Tests leave it
    /// false and call pump(now:) by hand.
    private let drivesTimer: Bool

    init(calendar: Calendar, bill: MacWorkBill?, drivesTimer: Bool = false) {
        self.calendar = calendar
        self.bill = bill
        self.drivesTimer = drivesTimer
    }

    var registeredCount: Int { entries.count }

    /// The system time zone changed (a laptop crossing zones): day and
    /// minute buckets restart in the new frame, and the next boundary is
    /// re-armed from it.
    func adoptCalendar(_ calendar: Calendar, now: Date) {
        self.calendar = calendar
        lastBucket.removeAll()
        if drivesTimer, !isOccluded { rescheduleTimer(after: now) }
    }

    @discardableResult
    func register(_ granularity: ClockGranularity, handler: @escaping (Date) -> Void) -> UUID {
        let id = UUID()
        entries.append(Entry(id: id, granularity: granularity, handler: handler))
        if drivesTimer { rescheduleTimer(after: Date()) }
        return id
    }

    func unregister(_ id: UUID) {
        entries.removeAll { $0.id == id }
        // Drop the seed for granularities with no consumers left, so a later
        // re-register seeds fresh instead of firing a phantom tick for
        // boundaries crossed while nobody listened (review finding 9).
        let inUse = Set(entries.map(\.granularity))
        for granularity in ClockGranularity.allCases where !inUse.contains(granularity) {
            lastBucket.removeValue(forKey: granularity)
        }
        if drivesTimer { rescheduleTimer(after: Date()) }
    }

    /// Fire every registered handler whose bucket advanced since the last
    /// pump. Seeding: the first pump only records buckets — a consumer that
    /// just registered gets its state from a direct read, not a phantom tick.
    func pump(now: Date) {
        guard !isOccluded else {
            bill?.bump(.clockTicksWhileOccluded)
            return
        }
        let inUse = Set(entries.map(\.granularity))
        for granularity in ClockGranularity.allCases where inUse.contains(granularity) {
            let bucket = granularity.bucketIndex(for: now, calendar: calendar)
            let previous = lastBucket[granularity]
            lastBucket[granularity] = bucket
            guard let previous, previous != bucket else { continue }
            bill?.bump(tickCounter(for: granularity))
            for entry in entries where entry.granularity == granularity {
                entry.handler(now)
            }
        }
        if drivesTimer { rescheduleTimer(after: now) }
    }

    func setOccluded(_ occluded: Bool, now: Date) {
        guard occluded != isOccluded else { return }
        isOccluded = occluded
        if occluded {
            timer?.cancel()
            timer = nil
        } else {
            // Catch-up: one pump per granularity boundary crossed while
            // hidden collapses to one tick — consumers re-derive from now,
            // they do not replay history.
            pump(now: now)
            if drivesTimer { rescheduleTimer(after: now) }
        }
    }

    private func tickCounter(for granularity: ClockGranularity) -> MacWorkBill.Counter {
        switch granularity {
        case .thirtySeconds: return .clockTicksThirtySeconds
        case .minute: return .clockTicksMinute
        case .day: return .clockTicksDay
        }
    }

    private func rescheduleTimer(after now: Date) {
        timer?.cancel()
        timer = nil
        guard !isOccluded, !entries.isEmpty else { return }
        let inUse = Set(entries.map(\.granularity))
        guard let next = inUse
            .map({ $0.nextBoundary(after: now, calendar: calendar) })
            .min() else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + max(0.05, next.timeIntervalSince(now)))
        source.setEventHandler { [weak self, weak source] in
            // A fire already enqueued when setOccluded cancelled the timer
            // must not reach pump — that would bump the occlusion tripwire
            // on a benign race (review finding 10).
            guard let self, let source, self.timer === source else { return }
            self.pump(now: Date())
        }
        source.resume()
        timer = source
    }
}
